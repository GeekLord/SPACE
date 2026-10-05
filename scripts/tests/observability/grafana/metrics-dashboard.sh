#!/usr/bin/env bash
# Provision the synthetic dashboard only for this local inspection session.
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$test_dir/../../../.." && pwd)
helper=$repo/infra/space/kind/grafana/local.sh
kube=(kubectl --context kind-space-local -n space-grafana)
bash "$helper" status
saved=$(mktemp)
helm get values space-grafana --kube-context kind-space-local -n space-grafana -o yaml > "$saved"
echo "Pre-test Grafana values: $saved"
created=false
tunnel=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n $tunnel ]]; then
    kill "$tunnel" 2>/dev/null || true
    wait "$tunnel" 2>/dev/null || true
  fi
  if $created; then
    if bash "$helper" up -f "$saved"; then
      "${kube[@]}" delete configmap metrics-contract --wait=true || result=1
    else
      echo "Restore failed; retained values at $saved and the fixture ConfigMap" >&2
      exit 1
    fi
  fi
  rm -f -- "$saved"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${kube[@]}" create configmap metrics-contract \
  --from-file=metrics-contract.json="$test_dir/metrics-contract.json"
created=true
bash "$helper" up -f "$saved" -f "$test_dir/dashboard-values.yaml"
bash "$helper" ui &
tunnel=$!
wait "$tunnel"
