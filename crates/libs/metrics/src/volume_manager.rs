use std::time::Instant;

use crate::emit::{counter, distribution, elapsed_ms, gauge, tag, timing_ms};
use pplx_space_common_core::types::{MaterializationLayout, MaterializationMode};

pub fn transfer_phase_duration(
    kind: &str,
    artifact: &str,
    phase: &str,
    mode: MaterializationMode,
    started_at: Instant,
) {
    timing_ms(
        "volume_manager.transfer.phase.duration_ms",
        elapsed_ms(started_at),
        &[
            tag("kind", kind),
            tag("artifact", artifact),
            tag("phase", phase),
            tag("mode", mode.as_str()),
        ],
    );
}

pub fn transfer_bytes(kind: &str, artifact: &str, form: &str, bytes: u64) {
    distribution(
        "volume_manager.transfer.bytes",
        bytes as f64,
        &[
            tag("kind", kind),
            tag("artifact", artifact),
            tag("form", form),
        ],
    );
}

pub fn transfer_inflation_ratio(kind: &str, artifact: &str, ratio: f64) {
    distribution(
        "volume_manager.transfer.inflation_ratio",
        ratio,
        &[tag("kind", kind), tag("artifact", artifact)],
    );
}

pub fn transfer_throughput_mib_s(
    kind: &str,
    artifact: &str,
    phase: &str,
    mode: MaterializationMode,
    mib_s: f64,
) {
    distribution(
        "volume_manager.transfer.throughput_mib_s",
        mib_s,
        &[
            tag("kind", kind),
            tag("artifact", artifact),
            tag("phase", phase),
            tag("mode", mode.as_str()),
        ],
    );
}

pub fn transfer_materialization_allocation(
    kind: &str,
    artifact: &str,
    mode: MaterializationMode,
    layout: MaterializationLayout,
    logical_bytes: u64,
    allocated_bytes: u64,
    candidate_hole_bytes: u64,
) {
    let tags = &[
        tag("kind", kind),
        tag("artifact", artifact),
        tag("mode", mode.as_str()),
        tag("layout", layout.as_str()),
    ];
    distribution(
        "volume_manager.transfer.materialization.logical_bytes",
        logical_bytes as f64,
        tags,
    );
    distribution(
        "volume_manager.transfer.materialization.allocated_bytes",
        allocated_bytes as f64,
        tags,
    );
    distribution(
        "volume_manager.transfer.materialization.candidate_hole_bytes",
        candidate_hole_bytes as f64,
        tags,
    );
    distribution(
        "volume_manager.transfer.materialization.projected_allocated_bytes",
        logical_bytes.saturating_sub(candidate_hole_bytes) as f64,
        tags,
    );
    if logical_bytes > 0 {
        distribution(
            "volume_manager.transfer.materialization.allocation_ratio",
            allocated_bytes as f64 / logical_bytes as f64,
            tags,
        );
    }
}

pub fn transfer_materialization_shadow_comparison(artifact: &str, outcome: &str) {
    counter(
        "volume_manager.transfer.materialization.shadow_comparison",
        1,
        &[tag("artifact", artifact), tag("outcome", outcome)],
    );
}

pub fn stream_writeback_outstanding_bytes(bytes: u64) {
    gauge(
        "volume_manager.stream_writeback.outstanding_bytes",
        bytes as f64,
        &[],
    );
}

pub fn stream_writeback_producer_blocked_ms(blocked_ms: f64, priority_class: &str) {
    distribution(
        "volume_manager.stream_writeback.producer_blocked_ms",
        blocked_ms,
        &[tag("priority_class", priority_class)],
    );
}

pub fn stream_writeback_failure(operation: &str) {
    counter(
        "volume_manager.stream_writeback.failure",
        1,
        &[tag("operation", operation)],
    );
}
