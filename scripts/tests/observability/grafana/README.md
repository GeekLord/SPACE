# Grafana validation assets

The deployable Grafana chart owns reusable SPACE dashboards. The synthetic
metrics contract dashboard is kept here and is never packaged with that chart.
Install the ordinary metrics and Grafana releases using their Kind helpers, then
run the [metrics integration workload](../metrics/README.md).

For an optional visual inspection of its captured run:

```bash
bash scripts/tests/observability/grafana/metrics-dashboard.sh
# Open http://127.0.0.1:13000/d/space-metrics and select the run version.
# Ctrl-C restores the previous Grafana values and deletes the fixture ConfigMap.
```

The script verifies the Kind namespace, creates its own ConfigMap and temporarily
mounts it through the chart's generic `dashboards.extraConfigMaps` interface.
It refuses to adopt an existing fixture ConfigMap. Other dashboards and backend
releases keep their own lifecycles. Do not run another Grafana upgrade during the
inspection. The script captures previous values in the temporary path it prints;
use that file with the guarded helper if the process is force-killed.

[Historical API journey and browser evidence](validation.md) describes previous
runtime checks and their limits; it is not evidence for a new chart revision.
