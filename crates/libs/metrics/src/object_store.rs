use crate::emit::{counter, tag};

/// One S3 SDK error observed by the shared object-store client.
///
/// Target bucket/key stays in structured logs, not metric tags, to keep
/// custom metric cardinality bounded.
pub fn s3_error(operation: &str, error_kind: &str, error_code: &str, http_status: &str) {
    counter(
        "object_store.s3.error",
        1,
        &[
            tag("operation", operation),
            tag("error_kind", error_kind),
            tag("error_code", error_code),
            tag("http_status", http_status),
        ],
    );
}
