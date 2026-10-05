#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/release.sh"
action=${1:-status}
shift || true
release_init traces
case "$action" in
  up)
    helm_options "$@"
    helm_upgrade 5m
    ;;
  status) "${kube[@]}" -n "$namespace" get pods,deploy,svc ;;
  ui) exec "${kube[@]}" -n "$namespace" port-forward --address 127.0.0.1 svc/tempo 13200:3200 ;;
  cleanup)
    confirm_cleanup "${1:-}" 'Requires --confirm-delete-local-data; deletes the local trace PVC'
    "${kube[@]}" delete namespace "$namespace" --wait=false
    ;;
  *) echo 'Usage: local.sh up [helm flags] | status | ui | cleanup --confirm-delete-local-data' >&2; exit 2 ;;
esac
