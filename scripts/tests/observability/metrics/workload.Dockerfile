# Pass a pinned Debian runtime compatible with the devbox's glibc.
ARG WORKLOAD_RUNTIME_IMAGE=debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
FROM ${WORKLOAD_RUNTIME_IMAGE}
COPY metrics_workload /usr/local/bin/metrics-workload
ENTRYPOINT ["/usr/local/bin/metrics-workload"]
