use pplx_space_common_core::types::NodeManagedBy;
use pplx_space_net_common::DomainName;
use pplx_space_net_gateway::tcp_proxy::TcpDomainAuthorizationMode;
use pplx_space_net_gateway::{NetGatewayRunConfig, SERVICE_NAME};

use clap::Parser;

#[derive(Parser)]
#[command(
    name = "space-netgtw-svc",
    about = "SPACE per-sandbox network gateway (transparent L4 proxy)",
    version,
    disable_version_flag = true
)]
struct Cli {
    /// Print version.
    #[arg(short = 'v', long = "version", action = clap::ArgAction::Version)]
    _version: (),

    /// Unix socket path for the control service (sbx-manager connects here)
    #[arg(long)]
    socket: String,

    /// Sandbox ID this gateway is managing
    #[arg(long)]
    sandbox_id: String,

    /// Inherited TCP listener FD (created by node-manager with `IP_TRANSPARENT`)
    #[arg(long)]
    tcp_fd: Option<i32>,

    /// Inherited UDP socket FD (created by node-manager with `IP_TRANSPARENT` + `IP_RECVORIGDSTADDR`)
    #[arg(long)]
    udp_fd: Option<i32>,

    /// Start closed without tenant identity. Used for warm-pool members.
    #[arg(long)]
    no_identity: bool,

    /// Deprecated no-op: admission always uses DNS attribution. Older
    /// sandbox-managers still pass this option when launching or cycling a
    /// gateway; retain its accepted values across independent upgrades.
    #[arg(long = "tcp-domain-authorization-mode", hide = true)]
    _tcp_domain_authorization_mode: Option<TcpDomainAuthorizationMode>,

    /// Exact domains whose failed DNS or TCP flows should emit an error.
    #[arg(long = "known-egress-domain", value_name = "DOMAIN")]
    known_egress_domains: Vec<DomainName>,

    /// Deprecated no-op: TLS ClientHello SNI sniffing is always on. Still
    /// accepted so a sandbox-manager predating the toggle's removal can launch
    /// this binary during the deploy window where the on-disk gateway binary
    /// is newer than the running sandbox-manager. Remove once no deployed
    /// sandbox-manager passes it.
    #[arg(long = "sni-sniffing", hide = true)]
    _sni_sniffing: bool,

    /// Deprecated no-op: V1 policies always apply explicit denies before
    /// allows. Accepted while older sandbox-manager builds can still launch
    /// this binary with the rollout argument.
    #[arg(
        long = "v1-deny-before-allow-mode",
        hide = true,
        default_value = "disabled"
    )]
    _v1_deny_before_allow_mode: String,

    /// SPACE route generation this gateway is bound to for ServicePort ingress.
    #[arg(long)]
    route_generation: Option<u64>,

    /// SPACE node id this gateway is bound to for ServicePort ingress.
    #[arg(long)]
    current_node_id: Option<String>,

    /// Sandbox execution generation this gateway is bound to for ServicePort ingress.
    #[arg(long)]
    execution_generation: Option<u64>,

    /// Kubernetes pod uid this gateway is bound to for ServicePort ingress.
    #[arg(long)]
    pod_uid: Option<String>,

    /// Activation dispatch this gateway is bound to for ServicePort ingress.
    #[arg(long)]
    activation_attempt_id: Option<String>,

    /// Runtime substrate (`space` for direct or `k8s` for Kubernetes).
    #[arg(long)]
    substrate_kind: Option<NodeManagedBy>,
}

impl From<Cli> for NetGatewayRunConfig {
    fn from(cli: Cli) -> Self {
        Self {
            socket_path: cli.socket,
            sandbox_id: cli.sandbox_id,
            tcp_fd: cli.tcp_fd,
            udp_fd: cli.udp_fd,
            no_identity: cli.no_identity,
            known_egress_domains: cli.known_egress_domains,
            route_generation: cli.route_generation,
            current_node_id: cli.current_node_id,
            execution_generation: cli.execution_generation,
            pod_uid: cli.pod_uid,
            activation_attempt_id: cli.activation_attempt_id,
            substrate_kind: cli.substrate_kind,
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let telemetry = pplx_space_common_svc::init_service_with_log_context(
        SERVICE_NAME,
        pplx_space_common_svc::LogContext::default().with_sandbox_id(cli.sandbox_id.clone()),
    )?;
    let shutdown_token = pplx_space_common_svc::shutdown_token();
    let result = pplx_space_net_gateway::run(cli.into(), shutdown_token).await;
    pplx_space_common_svc::shutdown_telemetry(telemetry).await;
    Ok(result?)
}
