use super::TcpProxy;
use std::net::SocketAddr;
use std::sync::Arc;

use pplx_space_net_common::{
    DenyReason, DomainName, EgressDecision, NetworkPolicyV1, TlsInterception,
};

use crate::dns::DnsAllowCache;
use crate::egress::{
    EgressContext, EgressProtocol, dns_allow_required, evaluate_egress,
    evaluate_egress_with_post_policy,
};
use crate::sniff::MissingClientHello;
use crate::state::TrafficPolicy;
use crate::tls_sni::ClientHelloScan;

/// Hostname exemptions require DNS attribution even with independent IP access.
/// Address exemptions select passthrough without relying on guest-supplied SNI.
pub(super) fn interception_mode(
    policy: &NetworkPolicyV1,
    destination: SocketAddr,
    scan: &ClientHelloScan,
    dns_allow_cache: &DnsAllowCache,
) -> TlsInterception {
    policy.tls_interception_for(
        destination.ip(),
        dns_attributed_host(destination, scan, dns_allow_cache),
    )
}

pub(super) fn dns_attributed_host<'a>(
    destination: SocketAddr,
    scan: &'a ClientHelloScan,
    dns_allow_cache: &DnsAllowCache,
) -> Option<&'a DomainName> {
    scan.server_name()
        .filter(|host| dns_allow_cache.contains_host_binding(destination.ip(), host.as_str()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum AdmittedTcp {
    Tunnel(SocketAddr),
    HostBoundHttp(SocketAddr),
}

impl AdmittedTcp {
    pub(super) const fn destination(self) -> SocketAddr {
        match self {
            Self::Tunnel(destination) | Self::HostBoundHttp(destination) => destination,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
#[error("TCP admission denied: {label}", label = self.label())]
pub(super) enum TcpAdmissionDenial {
    DnsAttribution(DenyReason),
    PolicyChanged,
}

impl TcpAdmissionDenial {
    pub(super) const fn label(self) -> &'static str {
        match self {
            Self::DnsAttribution(reason) => reason.label(),
            Self::PolicyChanged => "policy_changed",
        }
    }
}

impl TcpProxy {
    /// Apply normal destination admission before interpreting traffic to a
    /// reserved resolver as DNS. DNS attribution cannot authorize access to
    /// the resolver address itself.
    pub(super) fn admit_reserved_dns_destination(
        &self,
        destination: SocketAddr,
        policy: &NetworkPolicyV1,
    ) -> Result<AdmittedTcp, TcpAdmissionDenial> {
        match evaluate_egress(
            EgressContext::Admission(EgressProtocol::Tcp),
            destination,
            false,
            policy,
        ) {
            EgressDecision::Allow => Ok(AdmittedTcp::Tunnel(destination)),
            EgressDecision::Deny { reason } => Err(TcpAdmissionDenial::DnsAttribution(reason)),
        }
    }

    /// Confirm that an admission still belongs to the current policy. The
    /// caller performs this after registering the flow so a concurrent policy
    /// install must either sweep the registration or invalidate this check.
    pub(super) fn validate_admission_policy(
        &self,
        policy: &Arc<NetworkPolicyV1>,
    ) -> Result<(), TcpAdmissionDenial> {
        if self.network_state.is_current_tcp_policy(policy) {
            Ok(())
        } else {
            Err(TcpAdmissionDenial::PolicyChanged)
        }
    }

    /// How the ClientHello peek must treat a flow that shows none. Two kinds
    /// of admitted flow are denied for lacking one:
    ///
    /// - a destination the default deny refuses without DNS evidence, and the
    ///   guest's DNS evidence admits (see [`Self::admit`]);
    /// - with TLS interception on, any destination admitted without DNS
    ///   evidence, unless its IP is exempt, because interception closes a flow without SNI
    ///   (see `tls_interception::require_certificates`).
    ///
    /// A guardrail or an explicit deny refuses the flow before its ClientHello
    /// is read, and with interception off every other flow is decided without
    /// SNI, so neither waits for one.
    pub(super) fn missing_client_hello(
        &self,
        destination: SocketAddr,
        policy: &TrafficPolicy,
    ) -> MissingClientHello {
        let TrafficPolicy::Ready(policy) = policy else {
            return MissingClientHello::Proceeds;
        };
        match dns_allow_required(destination, policy) {
            Some(DenyReason::Default)
                if self.dns_allow_cache.allows_ip(destination.ip(), policy) =>
            {
                MissingClientHello::Denied
            }
            None if !policy.tls_interception_for(destination.ip(), None).is_off() => {
                MissingClientHello::Denied
            }
            _ => MissingClientHello::Proceeds,
        }
    }

    /// Admission based on the original destination and guest DNS attribution.
    pub(super) fn admit(
        &self,
        destination: SocketAddr,
        scan: &ClientHelloScan,
        policy: &NetworkPolicyV1,
    ) -> Result<AdmittedTcp, TcpAdmissionDenial> {
        let dns_allowed = self.dns_allow_cache.allows_ip(destination.ip(), policy);
        let explicit_domain_deny = scan
            .server_name()
            .is_some_and(|server_name| policy.denies_domain(server_name));
        let exempt = !policy.tls_interception.is_off()
            && interception_mode(policy, destination, scan, &self.dns_allow_cache).is_off();
        let mut admitted = AdmittedTcp::Tunnel(destination);
        let mut binding_metric = None;
        let decision = evaluate_egress_with_post_policy(
            EgressContext::Admission(EgressProtocol::Tcp),
            destination,
            dns_allowed,
            policy,
            |decision| {
                if explicit_domain_deny
                    && ((exempt && decision.is_allowed())
                        || matches!(
                            decision,
                            EgressDecision::Deny {
                                reason: DenyReason::Default,
                            }
                        ))
                {
                    return EgressDecision::Deny {
                        reason: DenyReason::Rule,
                    };
                }
                if !decision.is_allowed() {
                    return decision;
                }
                let Some(fail_closed_reason) = dns_allow_required(destination, policy) else {
                    return decision;
                };
                match scan {
                    ClientHelloScan::ServerName(server_name) => {
                        let host_allowed = policy.explicitly_allows_domain_name(server_name);
                        let host_attributed = self
                            .dns_allow_cache
                            .contains_host_binding(destination.ip(), server_name.as_str());
                        if host_allowed && host_attributed {
                            if interception_mode(policy, destination, scan, &self.dns_allow_cache)
                                .is_off()
                            {
                                binding_metric = Some(("tls_sni", "opaque_relay"));
                                decision
                            } else {
                                binding_metric = Some(("tls_sni", "allowed"));
                                decision
                            }
                        } else {
                            binding_metric = Some((
                                "tls_sni",
                                if host_attributed {
                                    "host_not_allowed"
                                } else {
                                    "host_unattributed"
                                },
                            ));
                            EgressDecision::Deny {
                                // An explicit domain deny outranks the missing-evidence reason.
                                reason: if explicit_domain_deny {
                                    DenyReason::Rule
                                } else {
                                    fail_closed_reason
                                },
                            }
                        }
                    }
                    ClientHelloScan::NotTls => {
                        admitted = AdmittedTcp::HostBoundHttp(destination);
                        binding_metric = Some(("http_host", "plaintext_http"));
                        decision
                    }
                    ClientHelloScan::Incomplete
                    | ClientHelloScan::NoServerName
                    | ClientHelloScan::Malformed => {
                        binding_metric = Some(("tls_sni", "host_missing"));
                        EgressDecision::Deny {
                            reason: fail_closed_reason,
                        }
                    }
                }
            },
        );
        if let Some((evidence, outcome)) = binding_metric {
            pplx_space_metrics::gateway::domain_binding("tcp", evidence, outcome, None);
        }
        match decision {
            EgressDecision::Allow => Ok(admitted),
            EgressDecision::Deny { reason } => Err(TcpAdmissionDenial::DnsAttribution(reason)),
        }
    }
}
