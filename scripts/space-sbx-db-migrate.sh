#!/usr/bin/env bash
# Run pending node-local SQLite migrations for SPACE node services using SQLx.
#
# Usage:
#   space-sbx-db-migrate.sh              # apply pending migrations
#   space-sbx-db-migrate.sh status       # show migration status
#   space-sbx-db-migrate.sh down         # rollback last migration
#   CONFIRM_DATA_LOSS=1 space-sbx-db-migrate.sh reset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATOR="${SPACE_DB_MIGRATOR_BIN:-$SCRIPT_DIR/space-db-migrator}"
COMMAND="${1:-up}"
CONFIRM_ARGS=()

if [[ "$COMMAND" == "reset" ]]; then
  if [[ "${CONFIRM_DATA_LOSS:-}" != "1" ]]; then
    echo "ERROR: reset requires CONFIRM_DATA_LOSS=1" >&2
    exit 2
  fi
  CONFIRM_ARGS=(--confirm-data-loss)
fi

if [[ ! -x "$MIGRATOR" ]]; then
  echo "ERROR: space-db-migrator not found at $MIGRATOR" >&2
  exit 1
fi

run_store() {
  local store="$1"
  local db_path="$2"

  "$MIGRATOR" "$store" \
    --database-path "$db_path" \
    "${CONFIRM_ARGS[@]}" \
    "$COMMAND"
  chmod 0600 "$db_path" "$db_path-shm" "$db_path-wal" 2>/dev/null || true
}

run_store sandbox-manager \
  "${SPACE_SBX_DB_PATH:-/space/run/sandbox-manager/sbx-manager.db}"
run_store template-manager \
  "${SPACE_TEMPLATE_DB_PATH:-/space/run/template-manager/template-manager.db}"
run_store node-manager \
  "${SPACE_NODE_MANAGER_DB_PATH:-/space/run/node-manager/node-manager.db}"
run_store node-ctl \
  "${SPACE_NODE_CTL_DB_PATH:-/space/run/node-ctl/node-ctl.db}"
