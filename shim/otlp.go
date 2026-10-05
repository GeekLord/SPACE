package main

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/sdk/resource"
)

func otlpSetting(specific, generic, fallback string) string {
	for _, key := range []string{specific, generic} {
		if value := strings.TrimSpace(os.Getenv(key)); value != "" {
			return value
		}
	}
	return fallback
}

// Validate transport without connecting or starting any exporter goroutines.
func otlpEndpoint(signal, envSignal, fallback string) (string, error) {
	prefix := "OTEL_EXPORTER_OTLP_" + envSignal
	// The SDK reads these implicitly even with an explicit plaintext endpoint.
	// Reject them before initialization without including secret values in errors.
	for _, key := range []string{prefix + "_HEADERS", "OTEL_EXPORTER_OTLP_HEADERS"} {
		if strings.TrimSpace(os.Getenv(key)) != "" {
			return "", fmt.Errorf("%s is not allowed with the plaintext OTLP %s profile", key, signal)
		}
	}
	protocol := otlpSetting(prefix+"_PROTOCOL", "OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")
	if !strings.EqualFold(protocol, "grpc") {
		return "", fmt.Errorf("OTLP %ss require grpc, got %q", signal, protocol)
	}
	endpoint := otlpSetting(prefix+"_ENDPOINT", "OTEL_EXPORTER_OTLP_ENDPOINT", fallback)
	if endpoint == "" {
		return "", fmt.Errorf("missing OTLP endpoint; set %s_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT", prefix)
	}
	if err := validateOTLPEndpoint(endpoint); err != nil {
		return "", fmt.Errorf("%s_ENDPOINT or OTEL_EXPORTER_OTLP_ENDPOINT %w", prefix, err)
	}
	return endpoint, nil
}

// Apply the endpoint rule the Rust services apply, so one Collector address
// works for every SPACE producer and a typo is refused the same way everywhere
// instead of being ignored by one exporter and rejected by another. The rule
// is written down for operators in docs/observability.md.
//
// Each message describes the requirement rather than repeating the value: an
// endpoint can embed credentials in its userinfo, and the caller already names
// the setting.
func validateOTLPEndpoint(endpoint string) error {
	// A valid endpoint is scheme, host, optional port and at most a bare "/",
	// so either marker is a rejection however empty it is. url.Parse keeps a
	// fragment out of Path and reports an empty query as none, so read the raw
	// string rather than inferring them from the parse.
	if strings.ContainsAny(endpoint, "?#") {
		return errors.New("must not include a query or fragment")
	}
	parsed, err := url.Parse(endpoint)
	if err != nil {
		// url.Parse refuses a non-numeric port outright, where the Rust and
		// Python producers report the port requirement. Name the same one, in
		// the same order, so one address reads the same everywhere.
		authority := authorityText(endpoint)
		if strings.Contains(authority, "@") {
			return errors.New("must not embed credentials")
		}
		if _, found := portText(authority); found {
			return errors.New("must use a port between 1 and 65535")
		}
		return errors.New("must be a URL")
	}
	switch {
	case parsed.Scheme != "http":
		return errors.New("must use the plaintext http:// scheme")
	case parsed.Hostname() == "":
		return errors.New("must include a host")
	case parsed.User != nil:
		return errors.New("must not embed credentials")
	}
	// An omitted port is left to the scheme default, but a port that is present
	// has to be usable. url.Parse reports an empty or unreadable port the same
	// way it reports none at all, so read the delimiter from the host text.
	if port, found := portText(parsed.Host); found {
		number, err := strconv.Atoi(port)
		if err != nil || number < 1 || number > 65535 {
			return errors.New("must use a port between 1 and 65535")
		}
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return errors.New("must not include a path")
	}
	return nil
}

// authorityText is the host[:port] portion of an endpoint, read without
// parsing so a rejection can name the same requirement the other producers
// name for an address url.Parse refuses outright.
func authorityText(endpoint string) string {
	rest := endpoint
	if _, after, found := strings.Cut(rest, "://"); found {
		rest = after
	}
	if end := strings.IndexAny(rest, "/?#"); end >= 0 {
		rest = rest[:end]
	}
	return rest
}

// portText reports the port an authority carries, and whether it carries the
// delimiter at all. An IPv6 literal keeps its own colons inside brackets, so
// the delimiter is the colon after the closing bracket.
func portText(host string) (string, bool) {
	if bracket := strings.LastIndex(host, "]"); bracket >= 0 {
		rest := host[bracket+1:]
		return strings.TrimPrefix(rest, ":"), strings.HasPrefix(rest, ":")
	}
	if colon := strings.LastIndex(host, ":"); colon >= 0 {
		return host[colon+1:], true
	}
	return "", false
}

func otlpResource(producerAttrs ...attribute.KeyValue) (*resource.Resource, error) {
	id := newIdentity(defaultShimService)
	// Shared attributes are applied first so the resolved identity outranks
	// them; the resolver has already removed the identity keys it owns and the
	// producer keys, which must never be inherited.
	attrs := make([]attribute.KeyValue, 0, len(id.attributes)+3)
	for key, value := range id.attributes {
		attrs = append(attrs, attribute.String(key, value))
	}
	attrs = append(attrs, attribute.String("service.name", id.serviceName()),
		attribute.String("service.version", id.resourceVersion()))
	if environment := id.resourceEnvironment(); environment != "" {
		attrs = append(attrs, attribute.String("deployment.environment.name", environment))
	}
	// Only static attribute sets are merged here, so there is no detector left
	// to return a partial resource; the environment is parsed by the resolver
	// above, which ignores malformed entries without failing.
	return resource.New(context.Background(),
		resource.WithTelemetrySDK(), resource.WithAttributes(attrs...),
		// Shared environment attributes must not collapse distinct metric producers.
		resource.WithAttributes(producerAttrs...),
	)
}

var otelErrorHandlerOnce sync.Once

func initOTelErrorHandler() {
	otelErrorHandlerOnce.Do(func() {
		otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) { logShim("OTel exporter error: %v", err) }))
	})
}
