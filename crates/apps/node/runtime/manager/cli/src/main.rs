use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};
use std::fmt::Write as _;

use comfy_table::{Table, presets::NOTHING};
use pplx_space_common_core::types::RuntimeKind as Runtime;
use pplx_space_node_runtime_manager_client::execution::{ArtifactComponentKind, RuntimeKind};
use pplx_space_node_runtime_manager_client::labels::label;
use pplx_space_node_runtime_manager_client::proto::{
    ArtifactLocation, ArtifactManagement, ArtifactProvenance, ArtifactProvider,
    CancelOperationRequest, ExecutionArtifact, ExecutionArtifactKind, ExecutionArtifactStatus,
    ExecutionArtifactVersionSource, GetOperationRequest, GetStatusRequest, GetStatusResponse,
    InstallKernelRequest, KernelPresence, ListAvailableKernelsRequest,
    ListAvailableKernelsResponse, ListExecutionArtifactsRequest, ListExecutionArtifactsResponse,
    Operation, OperationKind, OperationOutcome, OperationState, PathProtection, ProtectedPathRole,
    ScanIssueKind, ScanRootPresence, UninstallKernelRequest,
};

#[derive(Parser)]
#[command(
    name = "space-rtmgr",
    about = "Inspect the SPACE node runtime manager and manage its guest kernels",
    version
)]
struct Cli {
    /// Runtime-manager Unix socket.
    #[arg(long, global = true, default_value = pplx_space_node_runtime_manager_client::RUNTIME_MANAGER_SOCKET)]
    socket: PathBuf,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List the runtime releases and guest kernels on this node.
    List {
        /// Only list these kinds. Repeat to list several; omit to list all.
        #[arg(long = "kind", value_enum)]
        kinds: Vec<KindArg>,

        /// Also show architecture, state format, digest, layout, provider,
        /// and the scanned roots.
        #[arg(long, conflicts_with = "json")]
        wide: bool,

        /// Print the listing response as JSON.
        #[arg(long)]
        json: bool,
    },
    /// Check that the paths the runtime manager relies on are protected from
    /// other accounts. Exits non-zero when any path is absent or unprotected.
    Status {
        /// Print the status response as JSON.
        #[arg(long)]
        json: bool,
    },
    /// List, install, and uninstall guest kernels.
    Kernels {
        #[command(subcommand)]
        command: KernelsCommand,
    },
    /// Show one install or uninstall.
    Operation {
        operation_id: String,
        /// Print the operation as JSON.
        #[arg(long)]
        json: bool,
    },
    /// Cancel an operation that is still queued or downloading.
    Cancel {
        operation_id: String,
        /// Print the operation as JSON.
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum KernelsCommand {
    /// List the kernels published for a runtime's release line, and whether
    /// each is on this node.
    Available {
        /// The runtime, optionally with a line (fc-1.15) or release
        /// (fc-1.15.1). A runtime alone lists every line this node has a
        /// release of it for; no flag means the runtime the kernel source
        /// publishes for.
        #[arg(long, value_parser = parse_runtime)]
        runtime: Option<RuntimeArg>,
        /// Print the response as JSON.
        #[arg(long)]
        json: bool,
    },
    /// Download and install a kernel published for a runtime's release line.
    /// Requires root or the local operator account.
    Install {
        /// The kernel version, as `kernels available` lists it.
        version: String,
        /// The runtime line (fc-1.15) or release (fc-1.15.1) to install for.
        #[arg(long, value_parser = parse_runtime)]
        runtime: RuntimeArg,
        /// Return once the install is accepted instead of waiting for it.
        #[arg(long)]
        no_wait: bool,
        /// Print the operation as JSON.
        #[arg(long)]
        json: bool,
    },
    /// Remove a kernel the runtime manager installed. Requires root or the
    /// local operator account.
    Uninstall {
        version: String,
        /// Print the operation as JSON.
        #[arg(long)]
        json: bool,
    },
}

/// A runtime and, optionally, one of its versions: `fc`, `fc-1.15`,
/// `cloud-hypervisor-48.0`. Runtimes are spelled as the shared vocabulary
/// spells them, by alias or full name.
#[derive(Clone, Debug, Eq, PartialEq)]
struct RuntimeArg {
    kind: Runtime,
    version: Option<String>,
}

impl RuntimeArg {
    /// The runtime as a request names it.
    fn kind(&self) -> i32 {
        RuntimeKind::from(self.kind) as i32
    }
}

fn parse_runtime(value: &str) -> Result<RuntimeArg, String> {
    if let Ok(kind) = Runtime::parse(value) {
        return Ok(RuntimeArg {
            kind,
            version: None,
        });
    }
    // A name may itself hold a hyphen, so try each one as the separator.
    value
        .match_indices('-')
        .find_map(|(at, _)| {
            let kind = Runtime::parse(value.get(..at)?).ok()?;
            let version = value.get(at + 1..).filter(|version| !version.is_empty())?;
            Some(RuntimeArg {
                kind,
                version: Some(version.to_string()),
            })
        })
        .ok_or_else(|| {
            format!("'{value}' is not a runtime; expected fc, or fc-<version> such as fc-1.15")
        })
}

/// `fc-1.15.1`: a runtime's alias and a version of it. A kind this build
/// does not know shows its label.
fn runtime_label(kind: i32, version: &str) -> String {
    let name = RuntimeKind::try_from(kind)
        .ok()
        .and_then(|kind| Runtime::try_from(kind).ok())
        .map_or_else(
            || label::<RuntimeKind>(kind),
            |kind| kind.alias().to_string(),
        );
    format!("{name}-{version}")
}

#[derive(Clone, Copy, ValueEnum)]
enum KindArg {
    Runtime,
    Kernel,
}

/// Map `--kind` flags onto the request's artifact and component kinds. A
/// kernel is a component, so naming it also narrows components to kernels.
fn list_request(kinds: &[KindArg]) -> ListExecutionArtifactsRequest {
    let mut request = ListExecutionArtifactsRequest::default();
    for kind in kinds {
        match kind {
            KindArg::Runtime => request.kinds.push(ExecutionArtifactKind::Runtime as i32),
            KindArg::Kernel => {
                request.kinds.push(ExecutionArtifactKind::Component as i32);
                request
                    .component_kinds
                    .push(ArtifactComponentKind::Kernel as i32);
            }
        }
    }
    request
}

/// `firecracker` for a runtime, `kernel` for a component.
fn what(kind: i32, runtime_kind: i32, component_kind: i32) -> String {
    match ExecutionArtifactKind::try_from(kind) {
        Ok(ExecutionArtifactKind::Runtime) => label::<RuntimeKind>(runtime_kind),
        Ok(ExecutionArtifactKind::Component) => label::<ArtifactComponentKind>(component_kind),
        _ => label::<ExecutionArtifactKind>(kind),
    }
}

/// `space` for the runtime manager's own artifacts, `external` for everything
/// it only lists; `wide` adds the external provider.
fn managed_by(management: i32, provider: i32, wide: bool) -> String {
    match ArtifactManagement::try_from(management) {
        Ok(ArtifactManagement::SpaceManaged) => "space".to_string(),
        Ok(ArtifactManagement::External) if wide => {
            format!("external/{}", label::<ArtifactProvider>(provider))
        }
        Ok(ArtifactManagement::External) => "external".to_string(),
        _ => label::<ArtifactManagement>(management),
    }
}

/// `vendor/version-directory`, for example.
fn found_in(location: i32, provenance: i32) -> String {
    format!(
        "{}/{}",
        label::<ArtifactLocation>(location),
        label::<ArtifactProvenance>(provenance)
    )
}

/// A refused install, uninstall, or cancel, with how to get permission when
/// that is why.
fn mutation_error(status: tonic::Status) -> String {
    if status.code() == tonic::Code::PermissionDenied {
        format!(
            "ERROR: {}\nInstalling, uninstalling, and cancelling change the node: run the command as root or the local operator account.",
            status.message()
        )
    } else {
        format!("ERROR: {}", status.message())
    }
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    pplx_space_common_cli::init_logging("space-rtmgr");
    match run(Cli::parse()).await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}

async fn run(cli: Cli) -> Result<(), String> {
    let socket = pplx_space_node_runtime_manager_client::UnixSocketPath::parse(cli.socket.clone())
        .map_err(|error| format!("ERROR: invalid runtime-manager socket: {error}"))?;
    let mut client = pplx_space_node_runtime_manager_client::connect_at(socket)
        .await
        .map_err(|error| {
            format!(
                "ERROR: cannot connect to the runtime manager at {} (is space-rtmgr-svc running?): {error}",
                cli.socket.display()
            )
        })?;

    match cli.command {
        Command::List { kinds, wide, json } => {
            let response = client
                .list_execution_artifacts(list_request(&kinds))
                .await
                .map_err(|status| format!("ERROR: {}", status.message()))?
                .into_inner();
            if json {
                let rendered = serde_json::to_string_pretty(&response)
                    .map_err(|error| format!("ERROR: render JSON: {error}"))?;
                println!("{rendered}");
            } else {
                print!("{}", render_listing(&response, wide));
            }
            if !response.complete {
                eprintln!("WARNING: the listing is incomplete; see the issues it reports");
            }
            Ok(())
        }
        Command::Status { json } => {
            let response = client
                .get_status(GetStatusRequest {})
                .await
                .map_err(|status| format!("ERROR: {}", status.message()))?
                .into_inner();
            if json {
                let rendered = serde_json::to_string_pretty(&response)
                    .map_err(|error| format!("ERROR: render JSON: {error}"))?;
                println!("{rendered}");
            } else {
                print_status(&response);
            }
            status_outcome(&response)
        }
        Command::Kernels { command } => match command {
            KernelsCommand::Available { runtime, json } => {
                let response = client
                    .list_available_kernels(ListAvailableKernelsRequest {
                        runtime_kind: runtime
                            .as_ref()
                            .map_or(RuntimeKind::Unspecified as i32, RuntimeArg::kind),
                        runtime_version: runtime.and_then(|runtime| runtime.version),
                    })
                    .await
                    .map_err(|status| format!("ERROR: {}", status.message()))?
                    .into_inner();
                if json {
                    print_json(&response)?;
                } else {
                    print!("{}", render_available(&response));
                }
                Ok(())
            }
            KernelsCommand::Install {
                version,
                runtime,
                no_wait,
                json,
            } => {
                let runtime_kind = runtime.kind();
                let runtime_version = runtime
                    .version
                    .ok_or("ERROR: name the line to install for, such as --runtime fc-1.15")?;
                let mut operation = client
                    .install_kernel(InstallKernelRequest {
                        runtime_kind,
                        runtime_version,
                        version,
                    })
                    .await
                    .map_err(mutation_error)?
                    .into_inner()
                    .operation
                    .ok_or("ERROR: the runtime manager returned no operation")?;
                if !no_wait && in_progress(&operation) {
                    if !json {
                        eprintln!(
                            "Installing kernel {} (operation {}); interrupting this command does not stop it.",
                            operation.kernel_version, operation.operation_id
                        );
                    }
                    operation = wait_for(&mut client, operation).await?;
                }
                report(&operation, json)
            }
            KernelsCommand::Uninstall { version, json } => {
                let operation = client
                    .uninstall_kernel(UninstallKernelRequest { version })
                    .await
                    .map_err(mutation_error)?
                    .into_inner()
                    .operation
                    .ok_or("ERROR: the runtime manager returned no operation")?;
                report(&operation, json)
            }
        },
        Command::Operation { operation_id, json } => {
            let operation = client
                .get_operation(GetOperationRequest { operation_id })
                .await
                .map_err(|status| format!("ERROR: {}", status.message()))?
                .into_inner()
                .operation
                .ok_or("ERROR: the runtime manager returned no operation")?;
            if json {
                print_json(&operation)
            } else {
                print!("{}", render_operation(&operation));
                Ok(())
            }
        }
        Command::Cancel { operation_id, json } => {
            let operation = client
                .cancel_operation(CancelOperationRequest { operation_id })
                .await
                .map_err(mutation_error)?
                .into_inner()
                .operation
                .ok_or("ERROR: the runtime manager returned no operation")?;
            // Cancelled is what was asked for; anything else the operation
            // ended as is reported as usual.
            if operation.state == OperationState::Cancelled as i32 {
                return if json {
                    print_json(&operation)
                } else {
                    print!("{}", render_operation(&operation));
                    Ok(())
                };
            }
            report(&operation, json)
        }
    }
}

const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(500);

fn in_progress(operation: &Operation) -> bool {
    matches!(
        OperationState::try_from(operation.state),
        Ok(OperationState::Queued
            | OperationState::Downloading
            | OperationState::Publishing
            | OperationState::Removing
            | OperationState::Cancelling)
    )
}

async fn wait_for(
    client: &mut pplx_space_node_runtime_manager_client::RuntimeManagerGrpcClient,
    mut operation: Operation,
) -> Result<Operation, String> {
    while in_progress(&operation) {
        tokio::time::sleep(POLL_INTERVAL).await;
        operation = client
            .get_operation(GetOperationRequest {
                operation_id: operation.operation_id.clone(),
            })
            .await
            .map_err(|status| format!("ERROR: {}", status.message()))?
            .into_inner()
            .operation
            .ok_or("ERROR: the runtime manager returned no operation")?;
    }
    Ok(operation)
}

fn print_json(value: &impl serde::Serialize) -> Result<(), String> {
    let rendered = serde_json::to_string_pretty(value)
        .map_err(|error| format!("ERROR: render JSON: {error}"))?;
    println!("{rendered}");
    Ok(())
}

/// Print an operation and fail unless it succeeded or is still running.
fn report(operation: &Operation, json: bool) -> Result<(), String> {
    if json {
        print_json(operation)?;
    } else {
        print!("{}", render_operation(operation));
    }
    operation_outcome(operation)
}

fn operation_outcome(operation: &Operation) -> Result<(), String> {
    match OperationState::try_from(operation.state) {
        Ok(OperationState::Succeeded) => Ok(()),
        _ if in_progress(operation) => Ok(()),
        _ => Err(format!(
            "ERROR: {} {}: {}",
            label::<OperationKind>(operation.kind),
            label::<OperationState>(operation.state),
            operation.error.as_deref().unwrap_or("no reason recorded")
        )),
    }
}

fn render_operation(operation: &Operation) -> String {
    let mut fields = vec![
        ("Operation", operation.operation_id.clone()),
        ("Kind", label::<OperationKind>(operation.kind)),
        ("Kernel", operation.kernel_version.clone()),
    ];
    if let Some(line) = &operation.runtime_line {
        fields.push(("Runtime", runtime_label(operation.runtime_kind, line)));
    }
    let state = label::<OperationState>(operation.state);
    fields.push((
        "State",
        match OperationOutcome::try_from(operation.outcome) {
            Ok(OperationOutcome::Unspecified) | Err(_) => state,
            Ok(_) => format!("{state} ({})", label::<OperationOutcome>(operation.outcome)),
        },
    ));
    for (name, value) in [
        ("Error", &operation.error),
        ("Path", &operation.path),
        ("Digest", &operation.digest),
        ("Source", &operation.source),
    ] {
        if let Some(value) = value {
            fields.push((name, value.clone()));
        }
    }
    let mut out = String::new();
    for (name, value) in fields {
        let _ = writeln!(out, "{:<13}{value}", format!("{name}:"));
    }
    out
}

/// Megabytes with one decimal, which is how kernel sizes read best.
fn megabytes(bytes: u64) -> String {
    let tenths = (bytes * 10 + 524_288) / 1_048_576;
    format!("{}.{} MiB", tenths / 10, tenths % 10)
}

fn render_available(response: &ListAvailableKernelsResponse) -> String {
    let mut out = String::new();
    if response.runtime_lines.is_empty() {
        let _ = writeln!(
            out,
            "No {} release is on this node; name a line with --runtime {} to list its kernels.",
            label::<RuntimeKind>(response.runtime_kind),
            runtime_label(response.runtime_kind, "<line>")
        );
        return out;
    }
    if response.kernels.is_empty() {
        let lines: Vec<String> = response
            .runtime_lines
            .iter()
            .map(|line| runtime_label(response.runtime_kind, line))
            .collect();
        let _ = writeln!(
            out,
            "{} publishes no kernels for {} on this architecture.",
            response.source,
            lines.join(", ")
        );
        return out;
    }
    let mut table = plain_table(&["VERSION", "RUNTIME", "SIZE", "ON THIS NODE"]);
    for kernel in &response.kernels {
        // A kernel of this version is here, but not one installed from
        // this entry; its bytes may or may not match.
        let presence = if kernel.md5.is_none() {
            "unverifiable".to_string()
        } else {
            label::<KernelPresence>(kernel.presence)
        };
        table.add_row(vec![
            kernel.version.clone(),
            runtime_label(kernel.runtime_kind, &kernel.runtime_line),
            megabytes(kernel.size),
            presence,
        ]);
    }
    let _ = writeln!(out, "{table}");
    let _ = writeln!(out, "Source: {}", response.source);
    out
}

/// Succeeds only when every path is protected, naming absent and unprotected
/// paths separately: an absent path is unprovisioned, an unprotected one is
/// exposed.
fn status_outcome(response: &GetStatusResponse) -> Result<(), String> {
    let count = |protection: PathProtection| {
        response
            .protected_paths
            .iter()
            .filter(|path| path.protection == protection as i32)
            .count()
    };
    let protected = count(PathProtection::Protected);
    let total = response.protected_paths.len();
    if protected == total {
        return Ok(());
    }
    let absent = count(PathProtection::Absent);
    let other = total - protected - absent;
    Err(format!(
        "ERROR: {protected} of {total} runtime-manager paths are protected; {absent} absent, {other} unprotected"
    ))
}

fn print_status(response: &GetStatusResponse) {
    println!(
        "Runtime manager account: uid {} gid {}",
        response.service_uid, response.service_gid
    );
    for path in &response.protected_paths {
        println!(
            "  {:<12} {:<19} {}",
            label::<PathProtection>(path.protection),
            label::<ProtectedPathRole>(path.role),
            path.path
        );
        for problem in &path.problems {
            println!("      - {problem}");
        }
    }
}

fn optional(value: Option<&str>) -> String {
    value.unwrap_or("-").to_string()
}

/// Marks a version the layout did not name.
const DERIVED_VERSION_MARK: &str = "[*]";

/// The runtime release a kernel ships with or was installed for, such as
/// `fc-1.15.1`.
fn for_runtime(artifact: &ExecutionArtifact) -> String {
    artifact.for_runtime_version.as_deref().map_or_else(
        || "-".to_string(),
        |version| runtime_label(artifact.for_runtime_kind, version),
    )
}

/// A borderless table, the columns separated by padding alone.
fn plain_table(header: &[&str]) -> Table {
    let mut table = Table::new();
    table.load_style(NOTHING);
    table.set_header(header.to_vec());
    table
}

/// The listing as text. The default fits a terminal: what each artifact is,
/// whether it is usable, whose it is, and where it lives, with problems listed
/// below the table instead of widening it. `wide` adds the evidence columns and
/// the scanned roots.
fn render_listing(response: &ListExecutionArtifactsResponse, wide: bool) -> String {
    let mut out = String::new();
    let mut derived_versions = false;
    if response.artifacts.is_empty() {
        out.push_str("No runtime releases or kernels found.\n");
    } else {
        let mut table = if wide {
            plain_table(&[
                "KIND", "VERSION", "RUNTIME", "STATUS", "OWNER", "ARCH", "STATE", "DIGEST",
                "FOUND IN", "PATH",
            ])
        } else {
            plain_table(&["KIND", "VERSION", "RUNTIME", "STATUS", "OWNER", "PATH"])
        };
        for artifact in &response.artifacts {
            let version = match artifact.version.as_deref() {
                Some(version)
                    if artifact.version_source
                        == ExecutionArtifactVersionSource::ImageBanner as i32 =>
                {
                    derived_versions = true;
                    format!("{version} {DERIVED_VERSION_MARK}")
                }
                version => optional(version),
            };
            let mut row = vec![
                what(
                    artifact.kind,
                    artifact.runtime_kind,
                    artifact.component_kind,
                ),
                version,
                for_runtime(artifact),
                label::<ExecutionArtifactStatus>(artifact.status),
                managed_by(artifact.management, artifact.provider, wide),
            ];
            if wide {
                row.extend([
                    optional(artifact.architecture.as_deref()),
                    artifact.state_format.as_ref().map_or_else(
                        || "-".to_string(),
                        |state| format!("{} {}", state.format, state.version),
                    ),
                    optional(artifact.digest.as_deref()),
                    found_in(artifact.location, artifact.provenance),
                ]);
            }
            row.push(artifact.path.clone());
            table.add_row(row);
        }
        let _ = writeln!(out, "{table}");
    }
    if derived_versions {
        let _ = writeln!(
            out,
            "{DERIVED_VERSION_MARK} version read from the kernel image"
        );
    }

    let details: Vec<_> = response
        .artifacts
        .iter()
        .filter_map(|artifact| {
            artifact.detail.as_deref().map(|detail| {
                format!(
                    "  {}: {}: {detail}",
                    artifact.path,
                    label::<ExecutionArtifactStatus>(artifact.status)
                )
            })
        })
        .collect();
    if !details.is_empty() {
        out.push_str("\nProblems:\n");
        for line in details {
            let _ = writeln!(out, "{line}");
        }
    }

    if !response.aliases.is_empty() {
        out.push_str("\nAliases (observed on disk; not a runtime-manager selection):\n");
        for alias in &response.aliases {
            let target = match (&alias.target, &alias.resolved) {
                (Some(target), Some(resolved)) if wide && target != resolved => {
                    format!("{target} ({resolved})")
                }
                (Some(target), _) => target.clone(),
                (None, _) => "-".to_string(),
            };
            let _ = match &alias.detail {
                Some(detail) => writeln!(out, "  {} -> {target}  [{detail}]", alias.path),
                None => writeln!(out, "  {} -> {target}", alias.path),
            };
        }
    }

    if wide {
        out.push_str("\nScanned roots:\n");
        let mut table = plain_table(&["KIND", "FOUND IN", "PRESENCE", "PATH"]);
        for root in &response.roots {
            table.add_row(vec![
                what(root.kind, root.runtime_kind, root.component_kind),
                found_in(root.location, root.provenance),
                label::<ScanRootPresence>(root.presence),
                root.path.clone(),
            ]);
        }
        let _ = writeln!(out, "{table}");
    }

    if !response.issues.is_empty() {
        out.push_str("\nIssues (the listing is incomplete):\n");
        for issue in &response.issues {
            let _ = writeln!(
                out,
                "  {} {}: {}",
                label::<ScanIssueKind>(issue.kind),
                issue.path,
                issue.detail
            );
        }
    }
    out
}

#[cfg(test)]
mod tests;
