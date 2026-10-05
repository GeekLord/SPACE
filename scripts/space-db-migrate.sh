#!/usr/bin/env bash
# Run pending control-plane Postgres migrations using SQLx.
#
# Reads POSTGRES_CONNECTION_STRING from env or /space/config/space.env.
# Platform-agnostic — usable by deployment tooling, k8s init containers,
# or manual SSH invocation.
#
# Usage:
#   space-db-migrate.sh              # apply pending migrations
#   space-db-migrate.sh status       # show migration status
#   space-db-migrate.sh down         # rollback last migration
#
# Environment:
#   POSTGRES_CONNECTION_STRING   Control-plane Postgres connection URI (required)
#   SPACE_DB_MIGRATOR_BIN        Override migrator binary path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATOR="${SPACE_DB_MIGRATOR_BIN:-$SCRIPT_DIR/space-db-migrator}"
COMMAND="${1:-up}"

# Load connection string from space.env if not already in env
if [[ -z "${POSTGRES_CONNECTION_STRING:-}" ]]; then
  if [[ -f /space/config/space.env ]]; then
    POSTGRES_CONNECTION_STRING=$(grep '^POSTGRES_CONNECTION_STRING=' /space/config/space.env | cut -d= -f2-)
    export POSTGRES_CONNECTION_STRING
  fi
fi

if [[ -z "${POSTGRES_CONNECTION_STRING:-}" ]]; then
  echo "ERROR: POSTGRES_CONNECTION_STRING not set and not found in /space/config/space.env" >&2
  exit 1
fi

if [[ ! -x "$MIGRATOR" ]]; then
  echo "ERROR: space-db-migrator not found at $MIGRATOR" >&2
  echo "Build space-db-migrator (cargo build --locked --bin space-db-migrator) and set SPACE_DB_MIGRATOR_BIN to its executable path." >&2
  exit 1
fi

exec "$MIGRATOR" control-plane \
  --database-url "$POSTGRES_CONNECTION_STRING" \
  "$COMMAND"
