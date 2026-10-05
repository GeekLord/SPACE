#!/usr/bin/env bash
# The fixture Job has its own lifecycle, independent of the backend release.
set -euo pipefail
[[ $# == 3 || ( $# == 4 && $4 == --faults ) ]] || {
  echo 'Usage: run.sh RUN IMAGE NEW_OUTPUT_DIR [--faults]' >&2; exit 2;
}
run=$1
image=$2
output=$3
[[ $run =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo 'Invalid run name' >&2; exit 2; }
[[ ! -e $output ]] || { echo 'Evidence path already exists' >&2; exit 2; }
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$test_dir/../../../.." && pwd)
helper=$repo/infra/space/kind/metrics/local.sh
kube=(kubectl --context kind-space-local -n space-metrics)
bash "$helper" status
manifest=$(mktemp)
created=false
cleanup() {
  if $created; then
    bash "$helper" status >/dev/null &&
      "${kube[@]}" delete job "workload-$run" --ignore-not-found --wait=true
  fi
  rm -f -- "$manifest"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
helm template "workload-$run" "$test_dir/fixtures/workload" \
  --set-string "run=$run" --set-string "version=$run" --set-string "image=$image" > "$manifest"
# create refuses an existing run, so cleanup cannot adopt someone else's Job.
"${kube[@]}" create -f "$manifest"
created=true
"${kube[@]}" wait --for=jsonpath='{.status.active}'=2 "job/workload-$run" --timeout=60s
"${kube[@]}" wait --for=condition=Ready pod \
  -l "batch.kubernetes.io/job-name=workload-$run" --timeout=60s
python3 "$test_dir/capture.py" "$output" --run "$run" "${@:4}"
python3 "$test_dir/assess.py" "$output"
