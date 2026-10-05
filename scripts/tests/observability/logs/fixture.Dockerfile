ARG FIXTURE_RUNTIME_IMAGE=debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
FROM ${FIXTURE_RUNTIME_IMAGE}
ARG FIXTURE_SOURCE
LABEL org.opencontainers.image.revision=${FIXTURE_SOURCE}
COPY logging_process /usr/local/bin/logging_process
ENTRYPOINT ["/usr/local/bin/logging_process"]
