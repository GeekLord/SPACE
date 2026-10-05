#!/usr/bin/env bash
#
# Build and publish the containerd-shim-space-v2 binary.
#
# The shim is a standalone Go module under shim/. Worker nodes download the
# binary from S3 at bootstrap time.
#
# S3 layout:
#
# Immutable, one directory per commit:
#   s3://<bootstrap_bucket>/containerd-shim-space-v2/<full-sha>/containerd-shim-space-v2
#   s3://<bootstrap_bucket>/containerd-shim-space-v2/<full-sha>/containerd-shim-space-v2.sha256
#
# Mutable branch aliases, updated by each successful branch build:
#   s3://<bootstrap_bucket>/containerd-shim-space-v2/<branch>/version
#   s3://<bootstrap_bucket>/containerd-shim-space-v2/<branch>/containerd-shim-space-v2
#   s3://<bootstrap_bucket>/containerd-shim-space-v2/<branch>/containerd-shim-space-v2.sha256
#
# Worker bootstrap and the Helm shim updater accept either a full git SHA or a
# branch alias like `main`.
#
# This script is only used by Buildkite. Keep it boring:
#   - build linux/amd64
#   - publish to the bootstrap bucket of every target cluster
#     (see resolve_target_buckets)
#   - publish immutable commit artifacts and a mutable branch alias
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SHIM_DIR="${REPO_ROOT}/shim"

BINARY_NAME="containerd-shim-space-v2"
GOOS="linux"
GOARCH="amd64"
AWS_REGION="us-east-1"
COMMIT="${BUILDKITE_COMMIT:-$(git -C "${REPO_ROOT}" rev-parse HEAD)}"
BRANCH="${BUILDKITE_BRANCH:-$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)}"
GO_TRANSIENT_NETWORK_EXIT_STATUS=75

is_go_transient_network_error() {
  local output_file="$1"

  # Require a module-download/proxy marker and a network-failure marker to
  # co-occur on the SAME line so genuine build failures aren't reclassified as
  # transient just because a network-ish phrase appears elsewhere in the output.
  # Real Go proxy download errors emit the proxy host and the network error
  # together on one line (e.g. `go: <mod>: reading https://proxy.golang.org/...:
  # unexpected EOF`).
  grep -Eiq '(proxy\.golang\.org|go: downloading).*(stream error|INTERNAL_ERROR|unexpected EOF|i/o timeout|TLS handshake timeout|connection reset|connection refused|no such host|network is unreachable|temporary failure|timeout awaiting response headers|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout)' "$output_file"
}

run_go_with_transient_network_exit() {
  local output_file status

  output_file="$(mktemp)"
  set +e
  "$@" 2> >(tee "$output_file" >&2)
  status="$?"
  set -e

  if [ "$status" -eq 0 ]; then
    rm -f "$output_file"
    return 0
  fi

  if is_go_transient_network_error "$output_file"; then
    rm -f "$output_file"
    echo "Detected transient Go module download/network failure; exiting ${GO_TRANSIENT_NETWORK_EXIT_STATUS} so Buildkite can retry." >&2
    return "$GO_TRANSIENT_NETWORK_EXIT_STATUS"
  fi

  rm -f "$output_file"
  return "$status"
}

branch_ref() {
  local branch="$1"
  branch="${branch#refs/heads/}"
  printf '%s' "${branch}"
}

BRANCH_REF="$(branch_ref "${BRANCH}")"
if [[ -z "${BRANCH_REF}" || "${BRANCH_REF}" == "HEAD" ]]; then
  BRANCH_REF="local"
fi

# Configure comma-separated destinations with SPACE_SHIM_MAIN_BUCKETS for
# non-PR main builds and SPACE_SHIM_BRANCH_BUCKETS for PRs and other branches.
#
# Every resolved target is mandatory — a failed publish fails the build rather
# than silently shipping a SHA that can't be deployed to one of the clusters.
# Override the whole set via SPACE_SHIM_BUCKETS=b1,b2 for a one-off run.
resolve_target_buckets() {
  if [[ -n "${SPACE_SHIM_BUCKETS:-}" ]]; then
    printf '%s' "${SPACE_SHIM_BUCKETS}"
    return
  fi
  local pr="${BUILDKITE_PULL_REQUEST:-false}"
  if [[ "${BRANCH_REF}" == "main" && "${pr}" == "false" ]]; then
    printf '%s' "${SPACE_SHIM_MAIN_BUCKETS:?set SPACE_SHIM_MAIN_BUCKETS or SPACE_SHIM_BUCKETS}"
    return
  fi
  printf '%s' "${SPACE_SHIM_BRANCH_BUCKETS:?set SPACE_SHIM_BRANCH_BUCKETS or SPACE_SHIM_BUCKETS}"
}

run_install_tools() {
  local uv_bin
  uv_bin="$(bash "${REPO_ROOT}/ci/scripts/ensure-uv.sh")"
  export UV_CACHE_DIR="${UV_CACHE_DIR:-${TMPDIR:-/tmp}/space-uv-cache}"
  mkdir -p "${UV_CACHE_DIR}"
  "${uv_bin}" run --script "${REPO_ROOT}/ci/scripts/install-tools.py" "$@"
}

# ── Install Go (reuse existing helper) ──────────────────────────────────────

install_go() {
  if command -v go &>/dev/null; then
    echo "Go already available: $(go version)"
    return
  fi

  echo "--- :golang: Installing Go via install-tools.py"
  run_install_tools go
  export PATH="/usr/local/go/bin:${PATH}"
}

# ── Build ────────────────────────────────────────────────────────────────────

build_shim() {
  echo "--- :golang: Building ${BINARY_NAME} (${GOOS}/${GOARCH}, commit ${COMMIT})"

  local ldflags="-s -w -X main.Version=${COMMIT}"

  (
    cd "${SHIM_DIR}"
    run_go_with_transient_network_exit env CGO_ENABLED=0 GOOS="${GOOS}" GOARCH="${GOARCH}" \
      go build -trimpath -ldflags "${ldflags}" -o "${BINARY_NAME}" .
  )

  ls -lh "${SHIM_DIR}/${BINARY_NAME}"
  command -v file &>/dev/null && file "${SHIM_DIR}/${BINARY_NAME}" || true
}

# ── Checksum ─────────────────────────────────────────────────────────────────

generate_checksum() {
  echo "--- :lock: Generating SHA-256 checksum"
  ( cd "${SHIM_DIR}" && sha256sum "${BINARY_NAME}" > "${BINARY_NAME}.sha256" )
  printf '%s\n' "${COMMIT}" > "${SHIM_DIR}/${BINARY_NAME}.version"
  cat "${SHIM_DIR}/${BINARY_NAME}.sha256"
}

# ── Publish to S3 ────────────────────────────────────────────────────────────

publish_to_bucket() {
  local bucket="$1"
  local publish_alias="$2"
  local s3_prefix="s3://${bucket}/${BINARY_NAME}/${COMMIT}"

  echo "--- :s3: Publishing ${BINARY_NAME} to ${s3_prefix}/"

  aws s3 cp \
    "${SHIM_DIR}/${BINARY_NAME}" \
    "${s3_prefix}/${BINARY_NAME}" \
    --region "${AWS_REGION}"

  aws s3 cp \
    "${SHIM_DIR}/${BINARY_NAME}.sha256" \
    "${s3_prefix}/${BINARY_NAME}.sha256" \
    --region "${AWS_REGION}"

  aws s3 cp \
    "${SHIM_DIR}/${BINARY_NAME}.version" \
    "${s3_prefix}/version" \
    --region "${AWS_REGION}" \
    --content-type text/plain

  if [[ "${publish_alias}" != "true" ]]; then
    return
  fi

  local branch_prefix="s3://${bucket}/${BINARY_NAME}/${BRANCH_REF}"
  echo "--- :s3: Publishing ${BINARY_NAME} branch alias ${BRANCH_REF} to ${branch_prefix}/"

  aws s3 cp \
    "${SHIM_DIR}/${BINARY_NAME}" \
    "${branch_prefix}/${BINARY_NAME}" \
    --region "${AWS_REGION}"

  aws s3 cp \
    "${SHIM_DIR}/${BINARY_NAME}.sha256" \
    "${branch_prefix}/${BINARY_NAME}.sha256" \
    --region "${AWS_REGION}"

  aws s3 cp \
    "${SHIM_DIR}/${BINARY_NAME}.version" \
    "${branch_prefix}/version" \
    --region "${AWS_REGION}" \
    --content-type text/plain
}

publish_shim() {
  local buckets_csv
  buckets_csv="$(resolve_target_buckets)"

  run_install_tools aws-cli

  # Drop any injected AWS profile so we fall back to IRSA credentials.
  unset AWS_PROFILE AWS_DEFAULT_PROFILE

  # Mutable branch aliases are only useful for the shared lines (main, release
  # branches). PR builds skip the alias publish so concurrent stacked PRs and
  # repeated PR pushes can't clobber each other's pointer.
  local publish_alias="false"
  if [[ -z "${BUILDKITE_PULL_REQUEST:-}" || "${BUILDKITE_PULL_REQUEST}" == "false" ]]; then
    publish_alias="true"
  fi

  echo "--- :s3: Shim publish targets: ${buckets_csv}"

  local IFS=','
  read -r -a buckets <<<"${buckets_csv}"
  unset IFS

  local bucket
  for bucket in "${buckets[@]}"; do
    [[ -z "${bucket}" ]] && continue
    publish_to_bucket "${bucket}" "${publish_alias}"
  done

  echo ""
  echo "Published commit ${COMMIT} to:"
  for bucket in "${buckets[@]}"; do
    [[ -z "${bucket}" ]] && continue
    echo "  s3://${bucket}/${BINARY_NAME}/${COMMIT}/"
  done
  if [[ "${publish_alias}" == "true" ]]; then
    echo ""
    echo "Updated branch alias ${BRANCH_REF} in:"
    for bucket in "${buckets[@]}"; do
      [[ -z "${bucket}" ]] && continue
      echo "  s3://${bucket}/${BINARY_NAME}/${BRANCH_REF}/ -> ${COMMIT}"
    done
  else
    echo ""
    echo "Skipped branch alias publish (PR build)."
  fi
  echo ""
  echo "To deploy this exact shim with the SPACE app charts, use the manual SPACE Helm deploy pipeline:"
  echo "  SPACE_DEPLOY_SHA=${COMMIT}"
  if [[ "${publish_alias}" == "true" ]]; then
    echo ""
    echo "Worker node bootstrap resolves the ${BRANCH_REF} alias for first boot; explicit deploys should use the commit SHA."
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  resolve_target_buckets >/dev/null
  install_go
  build_shim
  generate_checksum
  publish_shim
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
