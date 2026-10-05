use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use futures_util::future::BoxFuture;
use futures_util::stream::BoxStream;
use futures_util::{StreamExt, TryStreamExt};
use hickory_resolver::config::ConnectionConfig;
use hickory_resolver::net::NetError;
use hickory_resolver::net::xfer::{DnsExchange, DnsHandle};
use hickory_resolver::proto::op::{DnsRequest, DnsResponse};
use hickory_resolver::{ConnectionProvider, PoolContext};
use tokio::sync::Semaphore;

use super::{GatewayRuntimeProvider, MAX_CONCURRENT_LOOKUPS};

/// Log before Hickory's server pool can replace I/O or Busy with NoConnections.
#[derive(Clone)]
pub(super) struct LoggingConnectionProvider(pub(super) GatewayRuntimeProvider);

impl ConnectionProvider for LoggingConnectionProvider {
    type Conn = LoggingDnsHandle;
    type FutureConn = BoxFuture<'static, Result<Self::Conn, NetError>>;
    type RuntimeProvider = GatewayRuntimeProvider;

    fn new_connection(
        &self,
        ip: IpAddr,
        config: &ConnectionConfig,
        cx: &PoolContext,
    ) -> Result<Self::FutureConn, NetError> {
        let upstream_addr = SocketAddr::new(ip, config.port);
        let log_error = move |error: &NetError| {
            tracing::warn!(%upstream_addr, ?error, "reserved DNS upstream connection failed");
        };
        let connection = self
            .0
            .new_connection(ip, config, cx)
            .inspect_err(log_error)?;
        let lookup_slots = self.0.lookup_slots.clone();
        Ok(Box::pin(async move {
            let handle = connection.await.inspect_err(log_error)?;
            Ok(LoggingDnsHandle {
                handle,
                upstream_addr,
                lookup_slots,
            })
        }))
    }

    fn runtime_provider(&self) -> &Self::RuntimeProvider {
        &self.0
    }
}

#[derive(Clone)]
pub(super) struct LoggingDnsHandle {
    handle: DnsExchange<GatewayRuntimeProvider>,
    upstream_addr: SocketAddr,
    lookup_slots: Arc<Semaphore>,
}

impl DnsHandle for LoggingDnsHandle {
    type Response = BoxStream<'static, Result<DnsResponse, NetError>>;
    type Runtime = GatewayRuntimeProvider;

    fn send(&self, request: DnsRequest) -> Self::Response {
        let upstream_addr = self.upstream_addr;
        let query_type = request.queries.first().map(|query| query.query_type);
        let lookup_slots = self.lookup_slots.clone();
        self.handle
            .send(request)
            .inspect_err(move |error| {
                if matches!(error, NetError::Busy) {
                    let space_lookups_in_flight = record_busy(&lookup_slots);
                    tracing::warn!(
                        %upstream_addr,
                        ?query_type,
                        ?error,
                        space_lookups_in_flight,
                        "reserved DNS upstream request failed"
                    );
                    return;
                }
                tracing::warn!(
                    %upstream_addr,
                    ?query_type,
                    ?error,
                    "reserved DNS upstream request failed"
                );
            })
            .boxed()
    }
}

fn record_busy(lookup_slots: &Semaphore) -> usize {
    let active = MAX_CONCURRENT_LOOKUPS - lookup_slots.available_permits();
    pplx_space_metrics::gateway::reserved_dns_upstream_busy_lookup_in_flight(active);
    active
}
