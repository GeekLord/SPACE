use tonic::Status;

use super::errors::DomainParseError;

/// Parse error type used by gRPC request converters.
///
/// This alias keeps service code explicit about where domain parse errors cross
/// a gRPC boundary.
///
/// ```
/// # use pplx_space_common_svc::types::GrpcParseError;
/// let err = GrpcParseError::new("invalid template");
/// assert_eq!(err.message(), "invalid template");
/// ```
pub type GrpcParseError = DomainParseError;

/// Converts a domain parse error into a gRPC `INVALID_ARGUMENT` status.
///
/// ```
/// # use pplx_space_common_svc::types::{invalid_argument, DomainParseError};
/// # use tonic::Code;
/// let status = invalid_argument(DomainParseError::new("invalid sandbox id"));
/// assert_eq!(status.code(), Code::InvalidArgument);
/// ```
pub fn invalid_argument(error: DomainParseError) -> Status {
    Status::invalid_argument(error.to_string())
}
