package main

import (
	"context"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	otelruntime "go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
)

// The collection cadence the Rust sink uses, so a Collector receives one
// cadence from every SPACE producer unless an operator changes it.
const defaultExportInterval = 10 * time.Second

type otlpMetricsSink struct {
	provider   *sdkmetric.MeterProvider
	meter      metric.Meter
	attributes []attribute.KeyValue
	mu         sync.Mutex
	counters   map[string]metric.Int64Counter
	histograms map[string]metric.Float64Histogram
}

// shimMeterScope names the shim's own instrumentation scope. Runtime
// instrumentation shares the provider under its own scope, so consumers must
// select by scope rather than assume the export carries only one.
const shimMeterScope = "pplx-space-shim"

func metricsEndpoint() (string, error) {
	return otlpEndpoint("metric", "METRICS", "")
}

func metricResourceAttributes() []attribute.KeyValue {
	// Match Rust: PID keeps same-host shim processes in distinct delta streams.
	instanceHost := otlpSetting("HOSTNAME", "SPACE_NODE_ID", "unknown-host")
	attrs := []attribute.KeyValue{attribute.String("service.instance.id", fmt.Sprintf("%s:%d", instanceHost, os.Getpid()))}
	if node := otlpSetting("SPACE_K8S_NODE_NAME", "KUBE_NODE_NAME", ""); node != "" {
		attrs = append(attrs, attribute.String("host.name", node), attribute.String("k8s.node.name", node))
	} else if _, inKubernetes := os.LookupEnv("KUBERNETES_SERVICE_HOST"); !inKubernetes {
		// Kubernetes HOSTNAME identifies a pod, not its underlying host.
		if host := strings.TrimSpace(os.Getenv("HOSTNAME")); host != "" {
			attrs = append(attrs, attribute.String("host.name", host))
		}
	}
	if pod := strings.TrimSpace(os.Getenv("SPACE_K8S_POD_NAME")); pod != "" {
		attrs = append(attrs, attribute.String("k8s.pod.name", pod))
	}
	return attrs
}

func newOTLPMetricsSink() (metricsSink, error) {
	endpoint, err := metricsEndpoint()
	if err != nil {
		return nil, err
	}
	interval, err := metricExportInterval()
	if err != nil {
		return nil, err
	}
	res, err := otlpResource(metricResourceAttributes()...)
	if err != nil {
		return nil, fmt.Errorf("OTel metrics resource: %w", err)
	}
	initOTelErrorHandler()
	// Match the Rust sink's wire profile and collection bounds so one Collector
	// pipeline can convert both producers the same way. Converting these delta
	// exponential histograms to cumulative native histograms is a Collector
	// responsibility, not something this exporter does.
	exporter, err := otlpmetricgrpc.New(context.Background(),
		otlpmetricgrpc.WithEndpointURL(endpoint), otlpmetricgrpc.WithInsecure(),
		otlpmetricgrpc.WithTimeout(3*time.Second),
		otlpmetricgrpc.WithTemporalitySelector(func(sdkmetric.InstrumentKind) metricdata.Temporality {
			return metricdata.DeltaTemporality
		}),
		otlpmetricgrpc.WithAggregationSelector(func(kind sdkmetric.InstrumentKind) sdkmetric.Aggregation {
			if kind == sdkmetric.InstrumentKindHistogram {
				return sdkmetric.AggregationBase2ExponentialHistogram{MaxSize: 160, MaxScale: 8}
			}
			return sdkmetric.DefaultAggregationSelector(kind)
		}),
	)
	if err != nil {
		return nil, fmt.Errorf("OTLP metrics exporter: %w", err)
	}
	// otelruntime.Start registers the memory, goroutine and GC instruments, but
	// the scheduler histogram only comes from its Producer. Both ride this one
	// reader, so runtime metrics reuse the sink's resource, exporter and
	// configured cadence instead of standing up a second pipeline.
	reader := sdkmetric.NewPeriodicReader(exporter,
		sdkmetric.WithInterval(interval), sdkmetric.WithTimeout(3*time.Second),
		sdkmetric.WithProducer(otelruntime.NewProducer()),
	)
	provider := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader), sdkmetric.WithResource(res), sdkmetric.WithCardinalityLimit(2000))
	// Runtime visibility is supplementary to space.shim.*: report a failure
	// through the OTel error handler and keep the custom metrics flowing.
	if err := otelruntime.Start(otelruntime.WithMeterProvider(provider)); err != nil {
		otel.Handle(fmt.Errorf("Go runtime metrics instrumentation: %w", err))
	}
	return &otlpMetricsSink{
		provider: provider, meter: provider.Meter(shimMeterScope),
		attributes: constantPointAttributes(telemetryTags()),
		counters:   make(map[string]metric.Int64Counter), histograms: make(map[string]metric.Float64Histogram),
	}, nil
}

// Read the metric export interval in milliseconds, defaulting to
// defaultExportInterval. Anything that is not a positive whole number of
// milliseconds fails telemetry setup rather than being ignored.
func metricExportInterval() (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv("OTEL_METRIC_EXPORT_INTERVAL"))
	if raw == "" {
		return defaultExportInterval, nil
	}
	millis, err := strconv.ParseInt(raw, 10, 64)
	// Reject a value the Duration multiplication below would overflow, rather
	// than wrapping it into a short or negative cadence.
	if err != nil || millis <= 0 || millis > int64(math.MaxInt64)/int64(time.Millisecond) {
		return 0, fmt.Errorf("OTEL_METRIC_EXPORT_INTERVAL must be a positive whole number of milliseconds")
	}
	return time.Duration(millis) * time.Millisecond, nil
}

// The OTel resource owns env and version. Point-level copies make receivers
// such as the Datadog Agent surface duplicate identity tags with ambiguous
// precedence, so the Rust sink drops them from metric points as well; the
// DogStatsD sink keeps them because it has no resource to carry them.
func constantPointAttributes(tags []string) []attribute.KeyValue {
	kept := make([]string, 0, len(tags))
	for _, tag := range tags {
		if key, _, _ := strings.Cut(tag, ":"); key == "env" || key == "version" {
			continue
		}
		kept = append(kept, tag)
	}
	return metricAttributes(kept)
}

func metricAttributes(tags []string) []attribute.KeyValue {
	attrs := make([]attribute.KeyValue, 0, len(tags))
	for _, tag := range tags {
		key, value, hasValue := strings.Cut(tag, ":")
		if key == "" {
			continue
		}
		if hasValue {
			attrs = append(attrs, attribute.String(key, value))
		} else {
			attrs = append(attrs, attribute.Bool(key, true))
		}
	}
	return attrs
}

func (s *otlpMetricsSink) measurementAttributes(tags []string) metric.MeasurementOption {
	attrs := make([]attribute.KeyValue, 0, len(s.attributes)+len(tags))
	attrs = append(attrs, s.attributes...)
	attrs = append(attrs, metricAttributes(tags)...)
	return metric.WithAttributes(attrs...)
}

func (s *otlpMetricsSink) count(name string, value int64, tags []string) error {
	s.mu.Lock()
	counter, ok := s.counters[name]
	if !ok {
		var err error
		counter, err = s.meter.Int64Counter(name, metric.WithUnit("1"))
		if err != nil {
			s.mu.Unlock()
			return err
		}
		s.counters[name] = counter
	}
	s.mu.Unlock()
	counter.Add(context.Background(), value, s.measurementAttributes(tags))
	return nil
}

func (s *otlpMetricsSink) distribution(name string, value float64, tags []string) error {
	s.mu.Lock()
	histogram, ok := s.histograms[name]
	if !ok {
		var err error
		histogram, err = s.meter.Float64Histogram(name, metric.WithUnit("ms"))
		if err != nil {
			s.mu.Unlock()
			return err
		}
		s.histograms[name] = histogram
	}
	s.mu.Unlock()
	histogram.Record(context.Background(), value, s.measurementAttributes(tags))
	return nil
}

func (s *otlpMetricsSink) shutdown(ctx context.Context) error {
	// PeriodicReader.Shutdown exports pending measurements before closing gRPC.
	return s.provider.Shutdown(ctx)
}
