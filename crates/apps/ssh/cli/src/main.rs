use pplx_space_sbx_mgr_client::proto::{GetEnvRequest, StateRequest};
use std::collections::BTreeMap;
use std::process::{Command, exit};

use clap::Parser;
use pplx_space_common_core::ids::sandbox_label_or_id as sandbox_label;
use pplx_space_common_core::types::{DEFAULT_GUEST_USER, OneOrMany, SandboxId, SandboxSelector};

const SSH_KEY: &str = "/root/.ssh/sandbox_ed25519";
const GUEST_IP: &str = "169.254.0.21";

#[derive(Parser)]
#[command(
    name = "space-ssh",
    about = "SSH into a running Firecracker sandbox",
    version,
    disable_version_flag = true
)]
struct Cli {
    /// Print version.
    #[arg(short = 'v', long = "version", action = clap::ArgAction::Version)]
    _version: (),

    /// Sandbox ID, long UUID prefix, or short random label
    id: SandboxSelector,

    /// SSH user (default: user)
    #[arg(long, default_value_t = DEFAULT_GUEST_USER.to_string())]
    user: String,

    /// Command to run (default: interactive shell)
    #[arg(trailing_var_arg = true)]
    command: Vec<String>,
}

#[tokio::main]
async fn main() {
    pplx_space_common_cli::init_logging("space-ssh");
    let cli = Cli::parse();

    let mut client = pplx_space_common_cli::unwrap_or_exit(
        pplx_space_sbx_mgr_client::connect().await,
        "cannot connect to sbx-manager (is space-sbx-manager running?)",
    );

    let sandboxes = pplx_space_sbx_mgr_client::list_all_sandboxes(&mut client)
        .await
        .unwrap_or_else(|error| pplx_space_common_cli::exit_error(error));

    if sandboxes.is_empty() {
        pplx_space_common_cli::exit_message("No sandboxes found.");
    }

    let listed = match cli.id.find(sandboxes.iter(), |sandbox| {
        sandbox
            .sandbox_id
            .parse::<SandboxId>()
            .unwrap_or_else(|error| {
                eprintln!(
                    "ERROR: sbx-manager returned invalid sandbox id '{}': {error}",
                    sandbox.sandbox_id
                );
                exit(1);
            })
    }) {
        Some(OneOrMany::One(sandbox)) => sandbox,
        Some(OneOrMany::Many(matches)) => {
            eprintln!("Ambiguous sandbox id '{}', matches:", cli.id);
            for sandbox in &matches {
                eprintln!("  {}", sandbox_label(&sandbox.sandbox_id));
            }
            exit(1);
        }
        None => {
            pplx_space_common_cli::exit_message(format!("No sandbox matching '{}'", cli.id));
        }
    };
    let sandbox = client
        .state(StateRequest {
            sandbox_ids: vec![listed.sandbox_id.clone()],
        })
        .await
        .unwrap_or_else(|error| pplx_space_common_cli::exit_error(error))
        .into_inner()
        .sandboxes
        .into_iter()
        .next()
        .unwrap_or_else(|| {
            pplx_space_common_cli::exit_message(format!(
                "Sandbox {} disappeared before state lookup.",
                sandbox_label(&listed.sandbox_id)
            ))
        });

    let lifecycle = sandbox
        .observed_lifecycle()
        .unwrap_or_else(|error| pplx_space_common_cli::exit_error(error));
    if !sandbox.pid.is_some_and(is_alive) {
        eprintln!(
            "Sandbox {} is not running (state: {}).",
            sandbox_label(&sandbox.sandbox_id),
            lifecycle.label()
        );
        exit(1);
    }

    let ns = sandbox.namespace.as_deref().unwrap_or_else(|| {
        eprintln!(
            "Sandbox {} has no network namespace.",
            sandbox_label(&sandbox.sandbox_id)
        );
        exit(1);
    });
    let target = format!("{}@{}", cli.user, GUEST_IP);
    let sandbox_env = client
        .get_env(GetEnvRequest {
            sandbox_id: sandbox.sandbox_id.clone(),
        })
        .await
        .unwrap_or_else(|error| {
            pplx_space_common_cli::exit_error(format!("failed to fetch sandbox env: {error}"))
        })
        .into_inner()
        .env;
    let (sandbox_env, issues) = pplx_space_common_core::types::EnvMap::sanitize(sandbox_env);
    for issue in issues {
        eprintln!("WARNING: sandbox env sanitized: {issue:?}");
    }
    let sandbox_env: BTreeMap<String, String> = sandbox_env.into();

    let mut args = vec![
        "nsenter".to_string(),
        format!("--net=/var/run/netns/{ns}"),
        "ssh".to_string(),
        "-i".to_string(),
        SSH_KEY.to_string(),
        "-o".to_string(),
        "StrictHostKeyChecking=no".to_string(),
        "-o".to_string(),
        "UserKnownHostsFile=/dev/null".to_string(),
        "-o".to_string(),
        "LogLevel=ERROR".to_string(),
    ];
    for (key, value) in &sandbox_env {
        let Some(value) = openssh_set_env_value(value) else {
            eprintln!("WARNING: skipping sandbox env '{key}' for ssh: value contains newline");
            continue;
        };
        args.push("-o".to_string());
        args.push(format!("SetEnv={key}={value}"));
    }
    args.push(target);

    if !cli.command.is_empty() {
        args.extend(cli.command);
    }

    let status = Command::new("sudo")
        .args(&args)
        .status()
        .unwrap_or_else(|error| {
            pplx_space_common_cli::exit_error(format!("failed to run ssh: {error}"))
        });

    exit(status.code().unwrap_or(1));
}

fn is_alive(pid: u32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}

fn openssh_set_env_value(value: &str) -> Option<String> {
    if value.contains('\n') || value.contains('\r') {
        return None;
    }
    if value
        .chars()
        .all(|ch| !ch.is_whitespace() && ch != '"' && ch != '\\')
    {
        return Some(value.to_string());
    }

    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for ch in value.chars() {
        if ch == '"' || ch == '\\' {
            quoted.push('\\');
        }
        quoted.push(ch);
    }
    quoted.push('"');
    Some(quoted)
}

#[cfg(test)]
mod tests;
