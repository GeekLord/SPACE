#!/usr/bin/env bash
# Converge control-plane Postgres roles via `space-db-migrator bootstrap-roles`.
#
# Reads POSTGRES_CONNECTION_STRING and the SPACE_DB_BOOTSTRAP_*_PASSWORD
# variables from env or /space/config/space.env. Convergent and safe to
# re-run; extra arguments pass through to bootstrap-roles (e.g.
# --allow-missing-passwords for grants-only runs). See db/README.md for the
# role model and provisioning order.
#
# Usage:
#   space-db-bootstrap-roles.sh [extra bootstrap-roles args]
#
# Environment:
#   POSTGRES_CONNECTION_STRING     Admin connection URI (required; must
#                                  authenticate as a role that can create
#                                  roles — the RDS master user)
#   SPACE_DB_BOOTSTRAP_*_PASSWORD  Managed role passwords
#   SPACE_DB_MIGRATOR_BIN          Override migrator binary path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATOR="${SPACE_DB_MIGRATOR_BIN:-$SCRIPT_DIR/space-db-migrator}"

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
  exit 1
fi

exec "$MIGRATOR" bootstrap-roles \
  --database-url "$POSTGRES_CONNECTION_STRING" \
  "$@"
