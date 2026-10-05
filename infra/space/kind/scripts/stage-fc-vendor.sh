#!/usr/bin/env bash
# stage-fc-vendor.sh — make the Firecracker vendor tree (firecracker + jailer
# + vmlinux kernel) available at /space/vendor inside the kind nodes that run
# sandbox or builder services.
#
# Production stages /space/vendor on the AMI via Packer; the multi-worker
# `space-local` cluster bind-mounts the devbox copy via kind extraMounts. The
# `space-local-3486` bench cannot use extraMounts (Docker Desktop on macOS has
# no /home/dev to share), so this script `docker cp`s the tree into the node
# instead. No-ops for nodes that already have it — safe for both clusters.
#
# Usage:
#   bash infra/space/kind/scripts/stage-fc-vendor.sh [cluster-name]
#
# Env knobs:
#   SPACE_KIND_CLUSTER   kind cluster name (default: space-local-3486)
set -euo pipefail

KIND_CLUSTER="${1:-${SPACE_KIND_CLUSTER:-space-local-3486}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=lib/kind-host-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/kind-host-paths.sh"
kind_host_paths__require SPACE_VENDOR_ROOT
VENDOR_DIR="$SPACE_VENDOR_ROOT"

log() { printf '[stage-fc-vendor] %s\n' "$*"; }
die() { printf '[stage-fc-vendor] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ ! -x "$VENDOR_DIR/$KIND_HOST_PATHS_VENDOR_PROBE" ]]; then
  log "vendor tree missing on the host; running install-fc-vendor.sh"
  SPACE_VENDOR_ROOT="$VENDOR_DIR" \
    bash "$REPO_ROOT/infra/space/kind/scripts/install-fc-vendor.sh"
fi

nodes=$(docker ps --format '{{.Names}}' --filter "label=io.x-k8s.kind.cluster=$KIND_CLUSTER" \
  | grep -E "^${KIND_CLUSTER}-worker[0-9]*$" || true)
[[ -n "$nodes" ]] || die "no kind worker containers found for cluster $KIND_CLUSTER"

for node in $nodes; do
  if docker exec "$node" test -x "/space/vendor/$KIND_HOST_PATHS_VENDOR_PROBE" 2>/dev/null; then
    log "$node already has /space/vendor"
    continue
  fi
  log "docker cp vendor tree → $node:/space/vendor"
  docker exec "$node" mkdir -p /space
  docker cp "$VENDOR_DIR" "$node:/space/vendor"
done
log "done"
