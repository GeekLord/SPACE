use std::os::fd::RawFd;
use std::path::PathBuf;

use clap::Parser;
use pplx_space_common_core::host::linux::paths::RUNTIME_SUPERVISOR_SOCKET;
use pplx_space_node_runtime_supervisor::{
    RuntimeSupervisorRunConfig, SIDECAR_LAUNCHER_FD_ARG_NAME,
};

#[derive(Parser)]
#[command(
    name = "space-runtime-supervisor",
    about = "SPACE host runtime supervisor",
    version,
    disable_version_flag = true
)]
struct Cli {
    /// Print version.
    #[arg(short = 'v', long = "version", action = clap::ArgAction::Version)]
    _version: (),

    /// Unix socket path to listen on.
    #[arg(long, default_value = RUNTIME_SUPERVISOR_SOCKET)]
    socket: PathBuf,

    /// Run the internal single-threaded sidecar launcher protocol.
    #[arg(long = SIDECAR_LAUNCHER_FD_ARG_NAME, hide = true)]
    sidecar_launcher_fd: Option<RawFd>,
}

impl From<Cli> for RuntimeSupervisorRunConfig {
    fn from(cli: Cli) -> Self {
        Self {
            socket_path: cli.socket,
            sidecar_launcher_fd: cli.sidecar_launcher_fd,
        }
    }
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    // The library owns the Tokio runtime, telemetry, and the shutdown token for
    // this service: launcher mode has to run in a single-threaded process with
    // none of them, so the mode choice cannot be made out here.
    Ok(pplx_space_node_runtime_supervisor::run(cli.into())?)
}
