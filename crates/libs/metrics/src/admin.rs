use crate::emit::{counter, gauge, tag};

pub fn audit_persist_failed(method: &str, mode: &str) {
    counter(
        "admin.audit.persist_failed",
        1,
        &[tag("method", method), tag("mode", mode)],
    );
}

pub fn audit_retention_deleted(count: u64) {
    if count == 0 {
        return;
    }
    counter("admin.audit.retention_deleted", count, &[]);
}

pub fn audit_retained_rows(count: u64) {
    gauge("admin.audit.rows", count as f64, &[]);
}
