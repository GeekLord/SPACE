#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/release.sh"
action=${1:-status}
shift || true
release_init grafana
case "$action" in
  up)
    helm_options "$@"
    helm_upgrade 3m
    ;;
  status) "${kube[@]}" -n "$namespace" get pods,deploy,svc ;;
  ui) exec "${kube[@]}" -n "$namespace" port-forward --address 127.0.0.1 svc/grafana 13000:3000 ;;
  cleanup)
    confirm_cleanup "${1:-}" 'Requires --confirm-delete-local-data; removes only the disposable UI'
    "${kube[@]}" delete namespace "$namespace" --wait=false
    ;;
  *) echo 'Usage: local.sh up [helm flags] | status | ui | cleanup --confirm-delete-local-data' >&2; exit 2 ;;
esac
