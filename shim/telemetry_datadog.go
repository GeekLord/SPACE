package main

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/DataDog/datadog-go/v5/statsd"
)

type datadogMetricsSink struct{ client *statsd.Client }

func newDatadogMetricsSink() (metricsSink, error) {
	client, err := statsd.New(dogstatsdAddress(), statsd.WithTags(telemetryTags()))
	if err != nil {
		return nil, fmt.Errorf("cannot connect to DogStatsD: %w", err)
	}
	return &datadogMetricsSink{client}, nil
}

func dogstatsdAddress() string {
	if socket := os.Getenv("DD_DOGSTATSD_SOCKET"); socket != "" {
		return "unix://" + socket
	}
	host := os.Getenv("DD_AGENT_HOST")
	if host == "" {
		host = "127.0.0.1"
	}
	port := 8125
	if raw := os.Getenv("DD_DOGSTATSD_PORT"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			port = parsed
		}
	}
	return fmt.Sprintf("%s:%d", host, port)
}

func (s *datadogMetricsSink) count(name string, value int64, tags []string) error {
	return s.client.Count(name, value, tags, 1)
}

func (s *datadogMetricsSink) distribution(name string, value float64, tags []string) error {
	return s.client.Distribution(name, value, tags, 1)
}

func (s *datadogMetricsSink) shutdown(ctx context.Context) error {
	done := make(chan error, 1)
	// Close flushes the aggregator and pending packets before closing the socket.
	go func() { done <- s.client.Close() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}
