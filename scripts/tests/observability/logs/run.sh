#!/usr/bin/env bash
# Restore collection settings and remove this run's Jobs after saving evidence.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: run.sh RUN IMAGE NEW_OUTPUT_DIR' >&2; exit 2; }
run=$1
image=$2
output=$3
[[ $run =~ ^[a-z0-9][a-z0-9-]{0,15}$ ]] || { echo 'Invalid run name' >&2; exit 2; }
[[ ! -e $output ]] || { echo 'Evidence path already exists' >&2; exit 2; }
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$test_dir/../../../.." && pwd)
helper=$repo/infra/space/kind/logs/local.sh
bash "$helper" status
saved=$(mktemp)
helm get values space-logs --kube-context kind-space-local -n space-logs -o yaml > "$saved"
echo "Pre-test logs values: $saved"
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -d $output ]]; then
    cp -- "$saved" "$output/backend-values-before.yaml"
    # jobs.json is written only after create succeeds; never delete by a broad selector.
    if ! python3 - "$output/jobs.json" "$run" <<'PY'
import json, subprocess, sys
from pathlib import Path
path = Path(sys.argv[1])
kube = ["kubectl", "--context", "kind-space-local", "-n", "space-logs"]
if path.exists():
    for name in json.loads(path.read_text()):
        job = json.loads(subprocess.check_output([*kube, "get", "job", name, "-o", "json"]))
        labels = job["metadata"]["labels"]
        if labels.get("space-local-owner") != "logs" or labels.get("logs-run") != sys.argv[2]:
            raise RuntimeError("Refusing cleanup of an unowned Job: " + name)
        subprocess.run([*kube, "delete", "job", name, "--wait=true"], check=True)
PY
    then
      result=1
    fi
  fi
  if ! bash "$helper" up -f "$saved"; then
    echo "Restore failed; retained pre-test values at $saved" >&2
    exit 1
  fi
  rm -f -- "$saved"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bash "$helper" up -f "$saved" -f "$test_dir/values.yaml"
python3 "$test_dir/validate.py" "$output" --run "$run" --image "$image"
