/// Validation error for converting transport payloads into domain types.
///
/// The optional field path lets boundary code point clients to the failing
/// input while preserving a client-safe domain parse message.
///
/// ```
/// # use pplx_space_common_svc::types::DomainParseError;
/// let err = DomainParseError::new("must be positive").field("memory_mib");
/// assert_eq!(err.to_string(), "memory_mib: must be positive");
/// ```
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum DomainParseError {
    #[error("{message}")]
    Message { message: String },
    #[error("{field}: {message}")]
    Field { field: String, message: String },
}

impl DomainParseError {
    /// Creates a domain parse error without field context.
    ///
    /// The message is sent to clients by gRPC/HTTP helpers, so callers must pass
    /// a client-safe validation message, not an arbitrary internal error.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::DomainParseError;
    /// let err = DomainParseError::new("invalid sandbox id");
    /// assert_eq!(err.message(), "invalid sandbox id");
    /// assert_eq!(err.field_path(), None);
    /// ```
    pub fn new(message: impl Into<String>) -> Self {
        Self::Message {
            message: message.into(),
        }
    }

    /// Adds field context, prepending nested paths when called repeatedly.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::DomainParseError;
    /// let err = DomainParseError::new("invalid")
    ///     .field("memory")
    ///     .field("shape");
    /// assert_eq!(err.field_path(), Some("shape.memory"));
    /// ```
    pub fn field(self, field: impl Into<String>) -> Self {
        let field = field.into();
        match self {
            Self::Message { message } => Self::Field { field, message },
            Self::Field {
                field: existing,
                message,
            } => Self::Field {
                field: format!("{field}.{existing}"),
                message,
            },
        }
    }

    /// Returns the parse message without field context.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::DomainParseError;
    /// let err = DomainParseError::new("invalid value").field("cpu");
    /// assert_eq!(err.message(), "invalid value");
    /// ```
    pub fn message(&self) -> &str {
        match self {
            Self::Message { message } | Self::Field { message, .. } => message,
        }
    }

    /// Returns the dotted field path, when one was attached.
    ///
    /// ```
    /// # use pplx_space_common_svc::types::DomainParseError;
    /// let err = DomainParseError::new("invalid").field("sandbox_id");
    /// assert_eq!(err.field_path(), Some("sandbox_id"));
    /// ```
    pub fn field_path(&self) -> Option<&str> {
        match self {
            Self::Message { .. } => None,
            Self::Field { field, .. } => Some(field),
        }
    }
}

#[cfg(test)]
mod tests;
