use std::time::Duration;

const GUEST_FILESYSTEM_FLUSH_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum GuestSnapshotPreparationBudget {
    Standard,
    AutoLifecycle,
}

impl GuestSnapshotPreparationBudget {
    const fn timeout(self) -> Duration {
        match self {
            Self::Standard => GUEST_FILESYSTEM_FLUSH_TIMEOUT,
            // Background auto-lifecycle work can allow a longer flush budget
            // without extending foreground suspend latency.
            Self::AutoLifecycle => Duration::from_secs(180),
        }
    }
}

/// Flush storage for a disk-only snapshot that does not capture VM memory.
///
/// This may run earlier in a scheduler tick that later creates a distinct
/// memory-bearing checkpoint. For the memory-bearing snapshot itself, use
/// [`prepare_guest_for_vm_snapshot_via_spaced_host`] instead.
pub(crate) async fn flush_guest_filesystems_via_spaced_host(
    sandbox_id: &str,
) -> Result<(), String> {
    tokio::time::timeout(
        GUEST_FILESYSTEM_FLUSH_TIMEOUT,
        flush_guest_filesystems_via_spaced_host_unbounded(sandbox_id),
    )
    .await
    .map_err(|_| {
        format!("guest filesystem flush timed out after {GUEST_FILESYSTEM_FLUSH_TIMEOUT:?}")
    })?
}

/// Flush storage and release cached guest bridge clients before a VM memory snapshot.
///
/// This is the complete pre-memory-snapshot operation; callers must not add
/// [`flush_guest_filesystems_via_spaced_host`] for that same memory snapshot.
pub(crate) async fn prepare_guest_for_vm_snapshot_via_spaced_host(
    sandbox_id: &str,
    budget: GuestSnapshotPreparationBudget,
) -> Result<(), String> {
    let timeout = budget.timeout();
    tokio::time::timeout(
        timeout,
        prepare_guest_for_vm_snapshot_via_spaced_host_unbounded(sandbox_id, timeout),
    )
    .await
    .map_err(|_| format!("guest snapshot preparation timed out after {timeout:?}"))?
}

async fn flush_guest_filesystems_via_spaced_host_unbounded(sandbox_id: &str) -> Result<(), String> {
    let socket_path = pplx_space_common_core::host::linux::paths::spaced_host_socket(sandbox_id);
    flush_guest_filesystems_at_socket(socket_path).await
}

async fn prepare_guest_for_vm_snapshot_via_spaced_host_unbounded(
    sandbox_id: &str,
    timeout: Duration,
) -> Result<(), String> {
    let started_at = tokio::time::Instant::now();
    let socket_path = pplx_space_common_core::host::linux::paths::spaced_host_socket(sandbox_id);
    let config = pplx_space_spaced_host_client::SpacedHostClientConfig::default()
        .with_socket_path(socket_path);
    let client = pplx_space_spaced_host_client::SpacedHostClient::new_with_config(config)
        .await
        .map_err(|error| error.to_string())?;
    client
        .prepare_suspend(timeout.saturating_sub(started_at.elapsed()))
        .await
        .map_err(|error| error.to_string())
}

async fn flush_guest_filesystems_at_socket(socket_path: String) -> Result<(), String> {
    let started_at = tokio::time::Instant::now();
    let config = pplx_space_spaced_host_client::SpacedHostClientConfig::default()
        .with_socket_path(socket_path);
    let client = pplx_space_spaced_host_client::SpacedHostClient::new_with_config(config)
        .await
        .map_err(|error| error.to_string())?;
    client
        .flush_guest_filesystems(
            GUEST_FILESYSTEM_FLUSH_TIMEOUT.saturating_sub(started_at.elapsed()),
        )
        .await
        .map_err(|error| error.to_string())
}
