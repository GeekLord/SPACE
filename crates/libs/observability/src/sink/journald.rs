use super::{METRICS_TARGET, Metric, MetricKind, MetricSink, MetricValue, all_metric_tags};

pub(super) struct JournaldSink {
    namespace: String,
    constant_tags: Vec<String>,
}

impl JournaldSink {
    pub(super) fn new(namespace: String, constant_tags: Vec<String>) -> Self {
        Self {
            namespace,
            constant_tags,
        }
    }
}

impl MetricSink for JournaldSink {
    fn label(&self) -> &'static str {
        "journald"
    }

    fn emit(&self, metric: Metric<'_>) {
        // Unit metadata is consumed only by native OTLP. Keep the legacy
        // structured-event schema unchanged for non-OTLP builds.
        let _ = metric.unit;
        let metric_name = format!("{}.{}", self.namespace, metric.name);
        let metric_kind = metric.kind.label();
        let metric_tags = all_metric_tags(&self.constant_tags, metric.tags);
        match metric.value {
            MetricValue::Unsigned(value) => tracing::info!(
                target: METRICS_TARGET,
                metric_name = %metric_name,
                metric_kind = metric_kind,
                metric_value = value,
                metric_tags = %metric_tags,
                "space metric"
            ),
            MetricValue::Float(value) => tracing::info!(
                target: METRICS_TARGET,
                metric_name = %metric_name,
                metric_kind = metric_kind,
                metric_value = value,
                metric_tags = %metric_tags,
                "space metric"
            ),
        }
    }
}

impl MetricKind {
    fn label(self) -> &'static str {
        match self {
            Self::Counter => "counter",
            Self::Gauge => "gauge",
            Self::Distribution => "distribution",
        }
    }
}
