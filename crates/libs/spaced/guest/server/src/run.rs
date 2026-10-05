//! The spaced guest daemon's service body: process-mode dispatch, telemetry,
//! the Tokio runtime, the environment-derived socket overrides, and the
//! readiness and shutdown loop around [`SpacedGuestService`]. This is what the
//! `spaced-svc` binary's `main` used to hold; the binary now only parses flags
//! and calls [`run`].

use crate::{
    HostConnectorType, RunFilesystemWorkerError, RunGuestServerError, SpacedGuestService,
    SpacedGuestServiceConfig, filesystem_worker_requested, run_filesystem_worker_from_environment,
};
#[cfg(not(target_os = "linux"))]
use std::os::unix::net::UnixDatagram;
#[cfg(target_os = "linux")]
use std::os::{
    linux::net::SocketAddrExt,
    unix::net::{SocketAddr, UnixDatagram},
};
use tokio_util::sync::CancellationToken;

/// The service name the guest daemon reports to telemetry.
pub const SERVICE_NAME: &str = "space-spaced-guest";

/// Everything [`run`] needs from the process that hosts it.
///
/// `spaced-svc` takes no flags beyond `--version`, so the deployed binary
/// passes the default: the guest daemon is configured by the environment the
/// microVM boots it in, and reading that environment stays here with the code
/// that acts on it. The override exists for a host that already knows which
/// sockets the service should bind, which is how the in-process signal test
/// and an embedding `main` reach the service.
#[derive(Clone, Debug, Default)]
pub struct SpacedGuestRunConfig {
    /// Service configuration to serve. `None` derives it from the environment.
    pub service_config: Option<SpacedGuestServiceConfig>,
}

/// Why the guest daemon returned without a clean shutdown.
#[derive(Debug, thiserror::Error)]
pub enum RunSpacedGuestError {
    #[error("failed to initialize {service} telemetry: {source}")]
    Telemetry {
        service: &'static str,
        #[source]
        source: pplx_space_common_svc::ObservabilityError,
    },
    #[error(transparent)]
    FilesystemWorker(#[from] RunFilesystemWorkerError),
    #[error("failed to build the spaced guest Tokio runtime: {0}")]
    Runtime(#[source] std::io::Error),
    #[error(transparent)]
    Serve(#[from] RunGuestServerError),
}

/// Runs `spaced-svc` end to end: this owns the whole process, which is why the
/// binary's `main` is only a flag parser.
///
/// The filesystem worker subprocess mode is dispatched before anything else.
/// That process is this binary re-executed as a different identity to do
/// filesystem work; it reports [`crate::WORKER_SERVICE_NAME`] and must not take over
/// the daemon's systemd watchdog contract. Its private runtime and telemetry
/// start only after switching process credentials. The daemon's runtime,
/// [`SERVICE_NAME`] telemetry and signal-driven shutdown remain separate.
pub fn run(config: SpacedGuestRunConfig) -> Result<(), RunSpacedGuestError> {
    if filesystem_worker_requested() {
        run_filesystem_worker_from_environment()?;
        return Ok(());
    }

    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(RunSpacedGuestError::Runtime)?
        .block_on(async move {
            let telemetry =
                pplx_space_common_svc::init_service(SERVICE_NAME).map_err(|source| {
                    RunSpacedGuestError::Telemetry {
                        service: SERVICE_NAME,
                        source,
                    }
                })?;
            let shutdown = pplx_space_common_svc::shutdown_token();
            let result = serve(config, shutdown).await;
            pplx_space_common_svc::shutdown_telemetry(telemetry).await;
            result
        })
}

/// Serves the guest daemon on the caller's runtime until the service exits.
///
/// [`run`] is the entry point `spaced-svc` uses; this is the same body for a
/// caller that already owns a runtime, telemetry, and a shutdown token.
pub async fn serve(
    config: SpacedGuestRunConfig,
    shutdown: CancellationToken,
) -> Result<(), RunSpacedGuestError> {
    let service_config = config
        .service_config
        .unwrap_or_else(service_config_from_environment);
    let service = SpacedGuestService::with_config(shutdown.clone(), service_config);
    // systemd already ordered spaced.service after local-fs.target. The remaining
    // required readiness edge is binding the bridge-guest command listener; the
    // server marks SPACE-ready immediately after that bind succeeds, and only
    // then may the process report READY=1.
    let readiness_service = service.clone();
    let readiness = readiness_service.wait_until_listening();
    let service = service.run();
    tokio::pin!(readiness);
    tokio::pin!(service);
    let mut readiness_observed = false;

    loop {
        tokio::select! {
            result = &mut service => {
                shutdown.cancel();
                result?;
                break;
            }
            ready = &mut readiness, if !readiness_observed => {
                readiness_observed = true;
                if ready {
                    notify_systemd_ready();
                }
            }
        }
    }

    Ok(())
}

/// Build the guest service config, applying optional UDS-bridge overrides used
/// by the local (non-Firecracker) runtime. Both are test hooks (compiled in only
/// with the `test-hooks` feature) and additive: unset leaves the
/// Firecracker/vsock auto-detect defaults untouched.
fn service_config_from_environment() -> SpacedGuestServiceConfig {
    let mut config = SpacedGuestServiceConfig::default();
    if let Some(path) =
        pplx_space_common_core::env::test_hook_var("SPACE_SPACED_GUEST_BRIDGE_SOCKET")
    {
        config.bridge_socket_path = Some(std::path::PathBuf::from(path));
    }
    if let Some(path) =
        pplx_space_common_core::env::test_hook_var("SPACE_SPACED_GUEST_HOST_BRIDGE_SOCKET")
    {
        config.host_connector_type = HostConnectorType::Uds(std::path::PathBuf::from(path));
    }
    config
}

fn notify_systemd_ready() -> bool {
    let Some(notify_socket) = std::env::var_os("NOTIFY_SOCKET") else {
        tracing::debug!("NOTIFY_SOCKET not set; skipping systemd readiness notification");
        return false;
    };
    let socket_path = notify_socket.to_string_lossy();
    let payload = b"READY=1
STATUS=spaced-svc ready";
    let Ok(socket) = UnixDatagram::unbound() else {
        tracing::warn!("failed to create systemd notify socket");
        return false;
    };

    if let Err(error) = send_systemd_ready(&socket, &socket_path, payload) {
        tracing::warn!(%error, notify_socket = %socket_path, "failed to notify systemd readiness");
        return false;
    }
    tracing::info!(notify_socket = %socket_path, "reported readiness to systemd");
    true
}

#[cfg(target_os = "linux")]
fn send_systemd_ready(
    socket: &UnixDatagram,
    socket_path: &str,
    payload: &[u8],
) -> std::io::Result<usize> {
    if let Some(abstract_name) = socket_path.strip_prefix('@') {
        let address = SocketAddr::from_abstract_name(abstract_name.as_bytes())?;
        socket.send_to_addr(payload, &address)
    } else {
        socket.send_to(payload, socket_path)
    }
}

#[cfg(not(target_os = "linux"))]
fn send_systemd_ready(
    socket: &UnixDatagram,
    socket_path: &str,
    payload: &[u8],
) -> std::io::Result<usize> {
    socket.send_to(payload, socket_path)
}

#[cfg(test)]
mod tests;
