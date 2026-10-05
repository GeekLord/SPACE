//! Registry of established TCP flows, reconciled on policy changes.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use parking_lot::Mutex;
use pplx_space_net_common::{
    DenyReason, DomainName, EgressDecision, NetworkPolicyV1, TlsInterception,
};
use tokio_util::sync::CancellationToken;

use super::admission::dns_attributed_host;
use crate::dns::DnsAllowCache;
use crate::egress::{EgressContext, dns_allow_required, evaluate_egress_with_post_policy};
use crate::tls_sni::ClientHelloScan;

/// Established-flow registry shared by admission and policy resweeps.
#[derive(Clone, Debug, Default)]
pub struct DnsAttributedTcpTracker {
    inner: Arc<DnsAttributedInner>,
}

#[derive(Debug, Default)]
struct DnsAttributedInner {
    next_id: AtomicU64,
    connections: Mutex<HashMap<u64, DnsAttributedConnection>>,
}

#[derive(Debug)]
struct DnsAttributedConnection {
    destination: SocketAddr,
    /// The admission-time ClientHello verdict. Only `NotTls` proves a flow is
    /// plaintext; `None` server names also arise from late, absent, malformed
    /// or oversized ClientHellos that Off relays opaquely.
    scan: ClientHelloScan,
    // The admission policy fixes the transport for this connection's lifetime.
    // This is the effective mode after destination exemptions.
    admitted_tls_interception: TlsInterception,
    // DNS expiry limits new admissions, not the lifetime of an exempt TLS flow.
    // Current policy permissions and exemptions are still checked on each sweep.
    admitted_exempt_host: Option<DomainName>,
    shutdown_token: CancellationToken,
}

pub(super) struct TcpConnectionGuard {
    pub(super) interception_mode: TlsInterception,
    id: u64,
    tracker: DnsAttributedTcpTracker,
}

impl DnsAttributedTcpTracker {
    /// Register an established flow. The guard unregisters on drop, so the
    /// caller must hold it for the lifetime of the connection.
    #[must_use]
    pub(super) fn register(
        &self,
        destination: SocketAddr,
        scan: ClientHelloScan,
        policy: &NetworkPolicyV1,
        dns_allow_cache: &DnsAllowCache,
        shutdown_token: CancellationToken,
    ) -> TcpConnectionGuard {
        let attributed_host = dns_attributed_host(destination, &scan, dns_allow_cache);
        let admitted_tls_interception =
            policy.tls_interception_for(destination.ip(), attributed_host);
        let admitted_exempt_host =
            if !policy.tls_interception.is_off() && admitted_tls_interception.is_off() {
                attributed_host.cloned()
            } else {
                None
            };
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        self.inner.connections.lock().insert(
            id,
            DnsAttributedConnection {
                destination,
                scan,
                admitted_tls_interception,
                admitted_exempt_host,
                shutdown_token,
            },
        );
        TcpConnectionGuard {
            interception_mode: admitted_tls_interception,
            id,
            tracker: self.clone(),
        }
    }

    /// Cancel every tracked flow the given policy no longer allows. Returns how
    /// many were cancelled.
    pub fn cancel_denied(
        &self,
        policy: &NetworkPolicyV1,
        dns_allow_cache: &DnsAllowCache,
    ) -> usize {
        self.cancel_matching(|connection| {
            dns_attributed_flow_is_denied(connection, policy, dns_allow_cache)
        })
    }

    /// Cancel every tracked flow when there is no policy left to authorize it.
    pub fn cancel_all(&self) -> usize {
        self.cancel_matching(|_| true)
    }

    fn cancel_matching(&self, predicate: impl Fn(&DnsAttributedConnection) -> bool) -> usize {
        let tokens = self
            .inner
            .connections
            .lock()
            .values()
            .filter(|connection| !connection.shutdown_token.is_cancelled() && predicate(connection))
            .map(|connection| connection.shutdown_token.clone())
            .collect::<Vec<_>>();
        let cancelled = tokens.len();
        tokens.into_iter().for_each(|token| token.cancel());
        cancelled
    }

    fn unregister(&self, id: u64) {
        self.inner.connections.lock().remove(&id);
    }
}

impl Drop for TcpConnectionGuard {
    fn drop(&mut self) {
        self.tracker.unregister(self.id);
    }
}

fn dns_attributed_flow_is_denied(
    connection: &DnsAttributedConnection,
    policy: &NetworkPolicyV1,
    dns_allow_cache: &DnsAllowCache,
) -> bool {
    // Opaque TLS must reconnect when its destination requires interception.
    // Prefer the admission binding for an exempt flow; other flows use live DNS.
    let attributed_host = connection
        .admitted_exempt_host
        .as_ref()
        .or_else(|| dns_attributed_host(connection.destination, &connection.scan, dns_allow_cache));
    let interception_mode =
        policy.tls_interception_for(connection.destination.ip(), attributed_host);
    if connection.scan != ClientHelloScan::NotTls
        && connection.admitted_tls_interception.is_off()
        && interception_mode == TlsInterception::On
    {
        return true;
    }
    let dns_allowed = dns_allow_cache.allows_ip(connection.destination.ip(), policy)
        || connection
            .admitted_exempt_host
            .as_ref()
            .is_some_and(|host| policy.explicitly_allows_domain_name(host));
    let server_name = connection.scan.server_name();
    let explicit_domain_deny =
        server_name.is_some_and(|server_name| policy.denies_domain(server_name));
    let decision = evaluate_egress_with_post_policy(
        EgressContext::Resweep,
        connection.destination,
        dns_allowed,
        policy,
        |decision| {
            if explicit_domain_deny
                && ((decision.is_allowed()
                    && !policy.tls_interception.is_off()
                    && interception_mode.is_off())
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
            let Some(fail_closed_reason) = dns_allow_required(connection.destination, policy)
            else {
                return decision;
            };
            // A plaintext flow can carry a different Host on every request.
            // Close it so a retry starts under the new policy.
            let Some(server_name) = server_name else {
                return EgressDecision::Deny {
                    reason: fail_closed_reason,
                };
            };
            if policy.explicitly_allows_domain_name(server_name)
                && attributed_host == Some(server_name)
            {
                decision
            } else {
                EgressDecision::Deny {
                    reason: if explicit_domain_deny {
                        DenyReason::Rule
                    } else {
                        fail_closed_reason
                    },
                }
            }
        },
    );
    !decision.is_allowed()
}

#[cfg(test)]
mod tests;
