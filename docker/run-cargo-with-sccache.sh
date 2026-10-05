#!/usr/bin/env sh
# Run one Cargo invocation with the release-build S3 cache. The BuildKit secret
# contains the pod's short-lived IRSA token and is never copied into an image
# layer. Cache availability is an optimization, so initialization fails open.
set -eu

if [ "${SPACE_SCCACHE_ENABLED:-false}" != "true" ] || [ -z "${SPACE_SCCACHE_BUCKET:-}" ]; then
    exec "$@"
fi

token_file="${SPACE_SCCACHE_WEB_IDENTITY_TOKEN_FILE:-/run/secrets/aws_web_identity_token}"
if [ -z "${SPACE_SCCACHE_ROLE_ARN:-}" ] || [ ! -r "${token_file}" ]; then
    echo "WARNING: sccache credentials are unavailable; continuing without compiler caching." >&2
    exec "$@"
fi

export AWS_ROLE_ARN="${SPACE_SCCACHE_ROLE_ARN}"
export AWS_WEB_IDENTITY_TOKEN_FILE="${token_file}"
export AWS_REGION="${SPACE_SCCACHE_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export SCCACHE_BUCKET="${SPACE_SCCACHE_BUCKET}"
export SCCACHE_REGION="${SPACE_SCCACHE_REGION:-us-east-1}"
export SCCACHE_S3_KEY_PREFIX="${SPACE_SCCACHE_S3_KEY_PREFIX:-sccache/space/v1/release}"
export SCCACHE_S3_RW_MODE="${SPACE_SCCACHE_S3_RW_MODE:-READ_WRITE}"
export SCCACHE_S3_SERVER_SIDE_ENCRYPTION="${SPACE_SCCACHE_S3_SERVER_SIDE_ENCRYPTION:-true}"
export SCCACHE_BASEDIRS="${SCCACHE_BASEDIRS:-/workspace}"
export CARGO_INCREMENTAL=0
export RUSTC_WRAPPER=sccache

cleanup() {
    status=$?
    trap - 0
    echo "--- sccache release-build statistics"
    sccache --show-stats || true
    sccache --stop-server >/dev/null 2>&1 || true
    exit "${status}"
}
trap cleanup 0

if ! sccache --zero-stats; then
    echo "WARNING: sccache initialization failed; continuing without compiler caching." >&2
    unset RUSTC_WRAPPER
    trap - 0
    exec "$@"
fi

"$@"
