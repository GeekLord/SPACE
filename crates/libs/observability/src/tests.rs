use std::collections::HashMap;

use opentelemetry::{
    Context, KeyValue,
    baggage::BaggageExt as _,
    propagation::TextMapPropagator as _,
    trace::{TraceContextExt as _, Tracer as _, TracerProvider as _},
};

#[test]
fn text_map_propagator_injects_trace_context_and_baggage() {
    let provider = opentelemetry_sdk::trace::SdkTracerProvider::default();
    let span = provider.tracer("space-observability-test").start("root");
    let cx =
        Context::current_with_span(span).with_baggage(vec![KeyValue::new("space.test", "upgrade")]);

    let mut carrier = HashMap::new();
    super::text_map_propagator().inject_context(&cx, &mut carrier);

    assert!(carrier.contains_key("traceparent"));
    assert_eq!(
        carrier.get("baggage").map(String::as_str),
        Some("space.test=upgrade")
    );
}

#[test]
fn traceparent_link_preserves_follower_parent_and_rejects_invalid_context() {
    use opentelemetry_sdk::trace::{InMemorySpanExporter, SdkTracerProvider};
    use tracing_subscriber::layer::SubscriberExt as _;

    opentelemetry::global::set_text_map_propagator(super::text_map_propagator());
    let exporter = InMemorySpanExporter::default();
    let provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let subscriber = tracing_subscriber::registry()
        .with(tracing_opentelemetry::layer().with_tracer(provider.tracer("wake-link-test")));
    let request_traceparent = "00-11111111111111111111111111111111-2222222222222222-01";
    let leader_traceparent = "00-33333333333333333333333333333333-4444444444444444-01";
    tracing::subscriber::with_default(subscriber, || {
        let wait = tracing::info_span!("restore.wait");
        super::trace_propagation::set_span_parent_from_traceparent(&wait, request_traceparent);
        super::trace_propagation::link_span_from_traceparent(&wait, leader_traceparent);
        super::trace_propagation::link_span_from_traceparent(&wait, "invalid");
    });
    let spans = exporter.get_finished_spans().unwrap();
    assert_eq!(spans.len(), 1);
    let wait = &spans[0];
    assert_eq!(
        wait.span_context.trace_id().to_string(),
        "11111111111111111111111111111111"
    );
    assert_eq!(wait.parent_span_id.to_string(), "2222222222222222");
    assert_eq!(wait.links.links.len(), 1);
    assert_eq!(
        wait.links.links[0].span_context.trace_id().to_string(),
        "33333333333333333333333333333333"
    );
    assert_eq!(
        wait.links.links[0].span_context.span_id().to_string(),
        "4444444444444444"
    );
}
