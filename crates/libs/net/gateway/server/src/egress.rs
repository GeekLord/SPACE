//! The gateway's DNS-attribution egress decision point.
//!
//! TCP admission, UDP forwarding, and established-flow resweeps
//! route their decisions through [`evaluate_egress`]:
//!
//! * the TCP accept path ([`crate::tcp_proxy`]),
//! * the UDP forward path ([`crate::udp_proxy`]), and
//! * the live-connection sweep that re-evaluates established TCP flows when a
//!   new policy is installed
//!   ([`crate::tcp_proxy::DnsAttributedTcpTracker::cancel_denied`]).
//!
//! Within the DNS-attribution paths, centralizing the decision keeps policy
//! evaluation and metric emission out of the individual proxies. The installed
//! [`NetworkPolicyV1`] always applies explicit denies before allows.
//!
//! The DNS allow cache is deliberately **not** owned here. The caller supplies
//! whether the destination IP has current DNS allow evidence; the evaluator
//! combines that input with the network policy to reach a verdict.

use std::fmt;
use std::net::SocketAddr;
use std::time::Instant;

use pplx_space_net_common::{DenyReason, EgressDecision, NetworkPolicyV1};

/// Transport an egress decision applies to.
///
/// Replaces the `"tcp"` / `"udp"` string literals that were previously threaded
/// into metric tags and log fields at each decision site.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EgressProtocol {
    Tcp,
    Udp,
}

impl EgressProtocol {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Tcp => "tcp",
            Self::Udp => "udp",
        }
    }
}

impl fmt::Display for EgressProtocol {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Which phase of egress enforcement produced a decision.
///
/// Becomes the `phase` tag on `gateway.policy.decision` so a burst of
/// [`Resweep`](Self::Resweep) re-evaluations on policy install does not inflate
/// the live [`Admission`](Self::Admission) rate.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EgressPhase {
    /// A new guest flow asking to leave.
    Admission,
    /// Re-evaluation of an already-established flow against a freshly installed
    /// policy.
    Resweep,
}

impl EgressPhase {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Admission => "admission",
            Self::Resweep => "resweep",
        }
    }
}

impl fmt::Display for EgressPhase {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Why an egress verdict is being computed.
///
/// This distinguishes the two semantically different callers of the unified
/// decision point so the single `gateway.policy.decision` emission can tag them
/// apart:
///
/// * [`Admission`](Self::Admission) — a brand-new guest flow asking to leave on
///   the given transport. This is the per-flow hot path and the thing the
///   decision rate is meant to measure.
/// * [`Resweep`](Self::Resweep) — re-evaluation of an *already-established* flow
///   when a new policy is installed, to cancel flows the new policy now denies.
///   A resweep produces a burst of verdicts over steady-state connections;
///   tagging it `phase = resweep` keeps it from inflating the new-flow admission
///   rate while still making the enforcement pass observable.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EgressContext {
    Admission(EgressProtocol),
    Resweep,
}

impl EgressContext {
    /// Transport tag for the decision metric. The connection sweep runs only
    /// over TCP flows, so a resweep is always TCP.
    fn protocol(self) -> EgressProtocol {
        match self {
            Self::Admission(protocol) => protocol,
            Self::Resweep => EgressProtocol::Tcp,
        }
    }

    /// Phase distinguishing a live admission decision from a policy resweep.
    fn phase(self) -> EgressPhase {
        match self {
            Self::Admission(_) => EgressPhase::Admission,
            Self::Resweep => EgressPhase::Resweep,
        }
    }
}

/// Decide whether `destination` may be reached under the installed `policy`,
/// given whether its IP has current DNS allow evidence, and record the egress
/// decision metrics tagged by `context` (transport + admission/resweep phase).
///
/// This is the decision point for DNS-attribution admission and resweeps.
/// Explicit denies always take precedence over overlapping allows.
pub fn evaluate_egress(
    context: EgressContext,
    destination: SocketAddr,
    dns_allowed: bool,
    policy: &NetworkPolicyV1,
) -> EgressDecision {
    evaluate_egress_with_post_policy(
        context,
        destination,
        dns_allowed,
        policy,
        std::convert::identity,
    )
}

/// Evaluate tenant policy, then let a protocol-specific gate refine the result
/// before the single enforced decision is metered. The gate may turn an allow
/// into a deny or refine a default deny to an explicit rule deny, but it must
/// preserve explicit address denies and platform guardrails.
pub(crate) fn evaluate_egress_with_post_policy(
    context: EgressContext,
    destination: SocketAddr,
    dns_allowed: bool,
    policy: &NetworkPolicyV1,
    post_policy: impl FnOnce(EgressDecision) -> EgressDecision,
) -> EgressDecision {
    let started_at = Instant::now();
    let policy_decision = evaluate_egress_unmetered(destination, dns_allowed, policy);
    let decision = post_policy(policy_decision);
    debug_assert!(
        policy_decision.is_allowed()
            || decision == policy_decision
            || matches!(
                (policy_decision, decision),
                (
                    EgressDecision::Deny {
                        reason: DenyReason::Default,
                    },
                    EgressDecision::Deny {
                        reason: DenyReason::Rule,
                    },
                )
            )
    );
    // Measured before emitting the decision counter so the latency reflects
    // the policy evaluation and protocol gate, but not the metric plumbing
    // around them.
    record_latency(context, started_at);
    record_decision(context, decision, policy.tls_interception);

    decision
}

/// Compute a verdict without emitting per-decision telemetry. The plaintext
/// HTTP request gate uses this for every request on an already-admitted flow;
/// recording those as new TCP admissions would inflate the flow metric.
pub(crate) fn evaluate_egress_unmetered(
    destination: SocketAddr,
    dns_allowed: bool,
    policy: &NetworkPolicyV1,
) -> EgressDecision {
    policy.egress_decision_for_socket(destination, dns_allowed)
}

/// If removing DNS-domain allow evidence would turn this flow's allow into a
/// deny, return that fail-closed reason. Call only after the metered evaluation
/// allowed the flow.
pub(crate) fn dns_allow_required(
    destination: SocketAddr,
    policy: &NetworkPolicyV1,
) -> Option<pplx_space_net_common::DenyReason> {
    match evaluate_egress_unmetered(destination, false, policy) {
        EgressDecision::Allow => None,
        EgressDecision::Deny { reason } => Some(reason),
    }
}

/// Record how long the verdict above took to compute. Fractional milliseconds:
/// a single decision is usually well under a millisecond, so rounding to whole
/// milliseconds would report zero almost every time and hide regressions as the
/// rule set grows.
fn record_latency(context: EgressContext, started_at: Instant) {
    pplx_space_metrics::gateway::policy_decision_latency_ms(
        context.protocol().as_str(),
        context.phase().as_str(),
        started_at.elapsed().as_secs_f64() * 1_000.0,
    );
}

/// `interception` is the policy choice in force for this verdict, so admission
/// panels can be split by rollout state instead of inferred from deploy timing.
fn record_decision(
    context: EgressContext,
    decision: EgressDecision,
    interception: pplx_space_net_common::TlsInterception,
) {
    pplx_space_metrics::gateway::policy_decision(
        pplx_space_metrics::gateway::PolicyDecisionKind::DnsAttributed,
        context.protocol().as_str(),
        context.phase().as_str(),
        "v1",
        decision.label(),
        interception.as_str(),
    );
}

#[cfg(test)]
mod tests;
