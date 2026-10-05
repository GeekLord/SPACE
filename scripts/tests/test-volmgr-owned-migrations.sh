#!/usr/bin/env bash
# Volume-manager migrations must execute inside the daemon after it owns
# service.mutex. The node-stack launcher may migrate other stores, but must not
# invoke the non-owning external volume-manager migrator.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
status=0

for script in \
  "$repo_root/scripts/k8s/node-stack-start.sh"; do
  if grep -Eq 'space-db-migrator[[:space:]]+volume-manager' "$script"; then
    echo "FAIL: external volume-manager migration remains in $script" >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "ok: the node-stack launcher leaves volume-manager migrations with the mutex owner"
fi
exit "$status"
