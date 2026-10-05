//! Opt-in interception admission. TLS transport never authorizes HTTP forwarding.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use pplx_space_net_common::TlsInterception as PolicyTlsInterception;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, TryAcquireError};

use crate::certificates::{CERTIFICATE_REQUEST_BACKSTOP, CertificateLease};
use crate::sniff::MissingSniDetail;
use crate::tls_sni::{ClientHelloScan, HttpAlpn};

pub use crate::certificates::CertificateRequester;

const MAX_TLS_HANDSHAKES: usize = 256;

#[derive(Clone, Default)]
pub struct TlsInterception {
    requester: Option<CertificateRequester>,
    upstream: UpstreamTls,
}

#[derive(Clone)]
struct UpstreamTls {
    config: Arc<rustls::ClientConfig>,
    handshakes: Arc<HandshakeCapacity>,
}

struct HandshakeCapacity {
    permits: Arc<Semaphore>,
    limit: usize,
    client_to_netgw: AtomicUsize,
    netgw_to_origin: AtomicUsize,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum TlsHandshakeLeg {
    ClientToNetgw,
    NetgwToOrigin,
}

impl TlsHandshakeLeg {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::ClientToNetgw => "client_to_netgw",
            Self::NetgwToOrigin => "netgw_to_origin",
        }
    }
}

pub(crate) struct TlsHandshakePermit {
    permit: Option<OwnedSemaphorePermit>,
    capacity: Arc<HandshakeCapacity>,
    leg: TlsHandshakeLeg,
}

impl HandshakeCapacity {
    fn new(limit: usize) -> Self {
        Self {
            permits: Arc::new(Semaphore::new(limit)),
            limit,
            client_to_netgw: AtomicUsize::new(0),
            netgw_to_origin: AtomicUsize::new(0),
        }
    }

    fn leg_active(&self, leg: TlsHandshakeLeg) -> &AtomicUsize {
        match leg {
            TlsHandshakeLeg::ClientToNetgw => &self.client_to_netgw,
            TlsHandshakeLeg::NetgwToOrigin => &self.netgw_to_origin,
        }
    }

    fn record(&self, leg: TlsHandshakeLeg) {
        pplx_space_metrics::gateway::tls_handshake_in_flight(
            "shared",
            self.limit - self.permits.available_permits(),
            self.limit,
        );
        pplx_space_metrics::gateway::tls_handshake_in_flight(
            leg.as_str(),
            self.leg_active(leg).load(Ordering::Relaxed),
            self.limit,
        );
    }

    fn try_acquire(
        self: &Arc<Self>,
        leg: TlsHandshakeLeg,
    ) -> Result<TlsHandshakePermit, TryAcquireError> {
        let permit = match self.permits.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(error) => {
                self.record(leg);
                return Err(error);
            }
        };
        let permit = TlsHandshakePermit {
            permit: Some(permit),
            capacity: Arc::clone(self),
            leg,
        };
        self.leg_active(leg).fetch_add(1, Ordering::Relaxed);
        self.record(leg);
        Ok(permit)
    }
}

impl Drop for TlsHandshakePermit {
    fn drop(&mut self) {
        self.capacity
            .leg_active(self.leg)
            .fetch_sub(1, Ordering::Relaxed);
        drop(self.permit.take());
        self.capacity.record(self.leg);
    }
}

impl Default for UpstreamTls {
    fn default() -> Self {
        Self::new(rustls::RootCertStore::from_iter(
            webpki_roots::TLS_SERVER_ROOTS.iter().cloned(),
        ))
    }
}

impl UpstreamTls {
    fn new(roots: rustls::RootCertStore) -> Self {
        let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::aws_lc_rs::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .expect("AWS-LC supports the default TLS versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
        config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
        config.resumption = rustls::client::Resumption::disabled();
        Self {
            config: Arc::new(config),
            handshakes: Arc::new(HandshakeCapacity::new(MAX_TLS_HANDSHAKES)),
        }
    }
}

pub(crate) enum InterceptionAction {
    PassThrough,
    Terminate(Arc<CertificateLease>),
}

impl TlsInterception {
    pub fn new(requester: CertificateRequester) -> Self {
        Self {
            upstream: UpstreamTls::default(),
            requester: Some(requester),
        }
    }

    /// Overrides public origin trust, independently of interception issuer trust.
    pub fn with_upstream_roots(mut self, roots: rustls::RootCertStore) -> Self {
        self.upstream = UpstreamTls::new(roots);
        self
    }

    pub(crate) fn upstream_config(&self, protocols: &[HttpAlpn]) -> Arc<rustls::ClientConfig> {
        let mut config = (*self.upstream.config).clone();
        config.alpn_protocols = protocols
            .iter()
            .map(|protocol| protocol.wire_value().to_vec())
            .collect();
        Arc::new(config)
    }

    pub(crate) fn handshake_permit(
        &self,
        leg: TlsHandshakeLeg,
    ) -> Result<TlsHandshakePermit, TryAcquireError> {
        self.upstream.handshakes.try_acquire(leg)
    }

    /// Called only after TCP policy admission. The admitted policy generation
    /// decides whether this connection passes through or is intercepted.
    pub(crate) async fn before_relay(
        &self,
        policy: PolicyTlsInterception,
        scan: &ClientHelloScan,
        missing_sni_detail: Option<MissingSniDetail>,
        port: u16,
    ) -> Result<InterceptionAction, TlsInterceptionError> {
        match policy {
            PolicyTlsInterception::Off => Ok(InterceptionAction::PassThrough),
            PolicyTlsInterception::On => {
                let requester = self
                    .requester
                    .as_ref()
                    .ok_or(TlsInterceptionError::AuthorityUnavailable)?;
                require_certificates(requester, scan, missing_sni_detail, port).await
            }
        }
    }
}

/// Certificates permit a TLS handshake, never uninspected application relay.
async fn require_certificates(
    requester: &CertificateRequester,
    scan: &ClientHelloScan,
    missing_sni_detail: Option<MissingSniDetail>,
    port: u16,
) -> Result<InterceptionAction, TlsInterceptionError> {
    let host = match scan {
        ClientHelloScan::NotTls => return Ok(InterceptionAction::PassThrough),
        ClientHelloScan::ServerName(host) => host.clone(),
        ClientHelloScan::NoServerName
        | ClientHelloScan::Incomplete
        | ClientHelloScan::Malformed => {
            return Err(TlsInterceptionError::MissingServerName(
                missing_sni_detail.expect("missing-SNI scan must retain its diagnostic detail"),
            ));
        }
    };
    // The provider bounds itself; this only catches a requester that does not.
    // It is deliberately longer so the provider's deadline fires first and
    // reports which stage ran out of budget.
    let lease = tokio::time::timeout(CERTIFICATE_REQUEST_BACKSTOP, requester(host, port))
        .await
        .map_err(|_| TlsInterceptionError::Timeout)?
        .map_err(TlsInterceptionError::CertificateRequest)?;
    Ok(InterceptionAction::Terminate(lease))
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum TlsInterceptionError {
    #[error("TLS interception authority is unavailable")]
    AuthorityUnavailable,
    #[error("TLS interception requires a complete ClientHello with a valid SNI")]
    MissingServerName(MissingSniDetail),
    #[error("certificate acquisition exceeded the two-second deadline")]
    Timeout,
    #[error("certificate acquisition failed ({code:?})", code = .0.code())]
    CertificateRequest(#[source] tonic::Status),
    #[error("TLS transport failed: {0}")]
    Transport(#[from] crate::tcp_proxy::tls::TlsTransportError),
}

impl TlsInterceptionError {
    pub(crate) const fn as_str(&self) -> &'static str {
        match self {
            Self::AuthorityUnavailable => "authority_unavailable",
            Self::MissingServerName(_) => "missing_sni",
            Self::Timeout => "timeout",
            Self::CertificateRequest(_) => "certificate_error",
            Self::Transport(error) => error.as_str(),
        }
    }
}

#[cfg(test)]
mod tests;
