use std::fmt;
use std::net::SocketAddr;

use http::Uri;
use pplx_space_common_core::types::{VsockCid, VsockPort};

use super::sockets::UnixSocketPath;

/// Stable service name used in routing, discovery, and telemetry.
///
/// ```
/// # use pplx_space_common_svc::types::ServiceName;
/// let name = ServiceName::parse("space-tmplmgr").unwrap();
/// assert_eq!(name.as_str(), "space-tmplmgr");
/// ```
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct ServiceName(String);

impl ServiceName {
    /// Parses a bounded, NUL-free service name.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::ServiceName;
    /// assert!(ServiceName::parse("space-api").is_ok());
    /// assert!(ServiceName::parse("").is_err());
    /// ```
    pub fn parse(value: impl Into<String>) -> Result<Self, ServiceNameParseError> {
        let value = value.into();
        if value.is_empty() || value.len() > 128 || value.contains('\0') {
            return Err(ServiceNameParseError);
        }
        Ok(Self(value))
    }

    /// Returns the validated service name as a string slice.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::ServiceName;
    /// let name = ServiceName::parse("space-node").unwrap();
    /// assert_eq!(name.as_str(), "space-node");
    /// ```
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ServiceName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// Error returned when a service name is empty, too long, or contains NUL.
///
/// ```
/// # use pplx_space_common_svc::types::ServiceName;
/// let err = ServiceName::parse("").unwrap_err();
/// assert_eq!(err.to_string(), "service name must be non-empty and bounded");
/// ```
#[derive(Debug, Clone, Eq, PartialEq, thiserror::Error)]
#[error("service name must be non-empty and bounded")]
pub struct ServiceNameParseError;

/// Error returned when a polling endpoint is not an HTTPS URL.
///
/// ```
/// # use pplx_space_common_svc::types::HttpsPollingUrl;
/// assert!(HttpsPollingUrl::parse("http://example.com/poll").is_err());
/// ```
#[derive(Debug, Clone, Eq, PartialEq, thiserror::Error)]
#[error("HTTPS polling URL must be an absolute https:// URI")]
pub struct HttpsPollingUrlParseError;

/// Validated HTTPS polling URL.
///
/// ```
/// # use pplx_space_common_svc::types::HttpsPollingUrl;
/// let url = HttpsPollingUrl::parse("https://api.example.com/poll").unwrap();
/// assert_eq!(url.as_str(), "https://api.example.com/poll");
/// ```
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct HttpsPollingUrl(String);

impl HttpsPollingUrl {
    /// Parses an absolute `https://` URL for polling.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::HttpsPollingUrl;
    /// assert!(HttpsPollingUrl::parse("https://api.example.com/poll").is_ok());
    /// assert!(HttpsPollingUrl::parse("http://api.example.com/poll").is_err());
    /// assert!(HttpsPollingUrl::parse("file:///tmp/socket").is_err());
    /// ```
    pub fn parse(value: impl Into<String>) -> Result<Self, HttpsPollingUrlParseError> {
        let value = value.into();
        let uri = value
            .parse::<Uri>()
            .map_err(|_| HttpsPollingUrlParseError)?;
        if uri.scheme_str() != Some("https") || uri.host().is_none_or(|host| host.is_empty()) {
            return Err(HttpsPollingUrlParseError);
        }
        Ok(Self(value))
    }

    /// Returns the validated URL string.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::HttpsPollingUrl;
    /// let url = HttpsPollingUrl::parse("https://api.example.com/poll").unwrap();
    /// assert_eq!(url.as_str(), "https://api.example.com/poll");
    /// ```
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for HttpsPollingUrl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl TryFrom<String> for HttpsPollingUrl {
    type Error = HttpsPollingUrlParseError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(value)
    }
}

impl From<HttpsPollingUrl> for String {
    fn from(value: HttpsPollingUrl) -> Self {
        value.0
    }
}

/// Addressing mode for reaching another SPACE service.
///
/// Keep endpoint shape explicit at the boundary so callers do not silently mix
/// Unix sockets, guest vsock, public TLS sockets, and polling endpoints.
///
/// ```
/// # use pplx_space_common_svc::types::{ServiceEndpoint, UnixSocketPath};
/// let path = UnixSocketPath::parse("/run/space/api.sock").unwrap();
/// let endpoint = ServiceEndpoint::Unix(path);
/// assert!(matches!(endpoint, ServiceEndpoint::Unix(_)));
/// ```
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ServiceEndpoint {
    /// Local Unix domain socket endpoint.
    Unix(UnixSocketPath),
    /// Guest vsock endpoint addressed by CID and port.
    Vsock { cid: VsockCid, port: VsockPort },
    /// TCP endpoint that must be reached with TLS.
    TcpTls(SocketAddr),
    /// HTTPS polling endpoint.
    HttpsPolling(HttpsPollingUrl),
}

#[cfg(test)]
mod tests;
