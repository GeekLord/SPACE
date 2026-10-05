use std::net::SocketAddr;
use std::sync::Arc;

use hickory_resolver::proto::op::Message;
use pplx_space_net_common::DomainName;
use tracing::error;

#[derive(Clone, Debug, Default)]
pub struct KnownEgressState {
    domains: Arc<[DomainName]>,
}

impl KnownEgressState {
    pub fn new(domains: Vec<DomainName>) -> Self {
        Self {
            domains: domains.into(),
        }
    }

    pub(crate) fn report_tcp_failure(
        &self,
        sandbox_id: &str,
        original_dst: SocketAddr,
        attempted_host: &DomainName,
        reason: &str,
    ) -> bool {
        self.report_failure(sandbox_id, original_dst, attempted_host, "tcp", reason)
    }

    fn report_failure(
        &self,
        sandbox_id: &str,
        original_dst: SocketAddr,
        attempted_host: &DomainName,
        protocol: &str,
        reason: &str,
    ) -> bool {
        let Some(destination) = self
            .domains
            .iter()
            .find(|destination| *destination == attempted_host)
        else {
            return false;
        };
        error!(
            sandbox_id,
            original_dst_port = original_dst.port(),
            destination = destination.as_str(),
            protocol,
            reason,
            "failed to connect to known egress destination"
        );
        true
    }

    pub(crate) fn report_dns_failure(
        &self,
        sandbox_id: &str,
        original_dst: SocketAddr,
        packet: &[u8],
        reason: &str,
    ) -> bool {
        if original_dst.port() != 53 {
            return false;
        }
        let Some(destination) = dns_host(packet) else {
            return false;
        };
        self.report_failure(sandbox_id, original_dst, &destination, "dns", reason)
    }
}

fn dns_host(packet: &[u8]) -> Option<DomainName> {
    let message = Message::from_vec(packet).ok()?;
    message.queries.first()?.name().to_string().parse().ok()
}

#[cfg(test)]
mod tests;
