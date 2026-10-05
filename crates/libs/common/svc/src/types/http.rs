use http::StatusCode;

use super::errors::DomainParseError;

/// Parse error type used by HTTP request converters.
///
/// This alias keeps service code explicit about where domain parse errors cross
/// an HTTP boundary.
///
/// ```
/// # use pplx_space_common_svc::types::HttpParseError;
/// let err = HttpParseError::new("invalid request");
/// assert_eq!(err.message(), "invalid request");
/// ```
pub type HttpParseError = DomainParseError;

/// HTTP representation of a domain parse failure.
///
/// The body is plain text and carries the same client-safe field-context message
/// that gRPC returns in `INVALID_ARGUMENT`.
///
/// ```
/// # use pplx_space_common_svc::types::{bad_request, DomainParseError};
/// let response = bad_request(DomainParseError::new("invalid sandbox id"));
/// assert_eq!(response.status(), ::http::StatusCode::BAD_REQUEST);
/// assert_eq!(response.body(), "invalid sandbox id");
/// ```
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpBadRequest {
    body: String,
}

impl HttpBadRequest {
    /// Returns the HTTP status code for this response.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::{bad_request, DomainParseError};
    /// let response = bad_request(DomainParseError::new("invalid"));
    /// assert_eq!(response.status(), ::http::StatusCode::BAD_REQUEST);
    /// ```
    pub const fn status(&self) -> StatusCode {
        StatusCode::BAD_REQUEST
    }

    /// Returns the client-safe plain text response body.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::{bad_request, DomainParseError};
    /// let response = bad_request(DomainParseError::new("invalid").field("sandbox_id"));
    /// assert_eq!(response.body(), "sandbox_id: invalid");
    /// ```
    pub fn body(&self) -> &str {
        &self.body
    }

    /// Splits this response into status and body parts.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::{bad_request, DomainParseError};
    /// let (status, body) = bad_request(DomainParseError::new("invalid")).into_parts();
    /// assert_eq!(status, ::http::StatusCode::BAD_REQUEST);
    /// assert_eq!(body, "invalid");
    /// ```
    pub fn into_parts(self) -> (StatusCode, String) {
        (StatusCode::BAD_REQUEST, self.body)
    }
}

/// Converts a domain parse error into an HTTP `400 Bad Request` response.
///
/// ```
/// # use pplx_space_common_svc::types::{bad_request, DomainParseError};
/// let response = bad_request(DomainParseError::new("invalid sandbox id"));
/// assert_eq!(response.status(), ::http::StatusCode::BAD_REQUEST);
/// ```
pub fn bad_request(error: DomainParseError) -> HttpBadRequest {
    HttpBadRequest {
        body: error.to_string(),
    }
}
