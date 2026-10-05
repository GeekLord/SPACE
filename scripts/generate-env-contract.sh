#!/usr/bin/env bash
# Generate or check the shim's contract using the Rust validation authority.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
case "${*}" in
  "" | --check) ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
rustc --edition=2024 -D warnings scripts/generate-env-contract.rs -o "$task_tmp/generate"
"$task_tmp/generate" > "$task_tmp/env_contract_generated.go"
if [[ "${1:-}" == --check ]]; then
  if ! diff -u shim/env_contract_generated.go "$task_tmp/env_contract_generated.go"; then
    echo 'Environment contract is stale; run bash scripts/generate-env-contract.sh' >&2
    exit 1
  fi
else
  cp "$task_tmp/env_contract_generated.go" shim/env_contract_generated.go
fi
