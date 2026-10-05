use pplx_space_common_core::types::{
    ExecutionGeneration, GuestPort, NodeId, RouteGeneration, SandboxId,
};

/// Parsed request/runtime identity for independently exported RPC spans.
/// This is an in-process request extension, never diagnostic wire headers.
#[derive(Clone, Debug)]
pub struct SandboxTraceContext {
    pub sandbox_id: SandboxId,
    pub port: GuestPort,
    pub route_generation: Option<RouteGeneration>,
    pub execution_generation: Option<ExecutionGeneration>,
    pub current_node_id: Option<NodeId>,
}

impl SandboxTraceContext {
    pub fn new(sandbox_id: SandboxId, port: GuestPort) -> Self {
        Self {
            sandbox_id,
            port,
            route_generation: None,
            execution_generation: None,
            current_node_id: None,
        }
    }

    pub fn record(&self, span: &tracing::Span) {
        // Serialize this span's context so its structured logs link directly to
        // the independently exported span, without copying diagnostic headers.
        if let Some(traceparent) =
            pplx_space_observability::trace_propagation::traceparent_for_span(span)
        {
            span.record("traceparent", traceparent.as_str());
        }
        span.record("sandbox_id", tracing::field::display(self.sandbox_id));
        span.record("sandbox_port", self.port.get().get());
        if let Some(value) = self.route_generation {
            span.record("route_generation", value.get());
        }
        if let Some(value) = self.execution_generation {
            span.record("execution_generation", value.get());
        }
        if let Some(value) = self.current_node_id {
            span.record("current_node_id", tracing::field::display(value));
        }
    }
}

/// Record a typed guest outcome without changing the enclosing span's status.
/// Public HTTP spans still classify their legitimate 502 as an HTTP error.
pub fn record_guest_service_outcome(status: &tonic::Status, span: &tracing::Span) -> bool {
    if crate::GuestServiceUnavailable::from_status(status).is_none() {
        return false;
    }
    span.record("failure_origin", "guest");
    span.record("failure_reason", "connection_refused");
    true
}

/// Keep the gRPC status visible without classifying an expected guest refusal
/// as an internal APM error. The marker and code must both match.
pub fn record_guest_service_status(status: &tonic::Status, span: &tracing::Span) -> bool {
    if !record_guest_service_outcome(status, span) {
        return false;
    }
    span.record("otel.status_code", "OK");
    true
}
