#!/usr/bin/env bash
# Full control-plane convergence for a deploy: converge roles, apply
# migrations as space_migrator, then re-converge so credential tables the
# migrations just created are fenced and reads on new tables are granted.
# Run by the space-db-migrate Job when provisionRoles is enabled; every step
# is idempotent and convergent, so it is safe to re-run.
#
# The first bootstrap must precede the migration: migrations run as
# space_migrator via SET ROLE, which requires the role to already exist.
#
# Reads POSTGRES_CONNECTION_STRING (an admin/master URI that can create
# roles) and the SPACE_DB_BOOTSTRAP_*_PASSWORD values from the environment.
# The pipeline enables provisioning only when the bootstrap-password secret
# is present and the Job mounts it as a required secretRef, so the passwords
# are guaranteed here; a missing one makes bootstrap-roles fail loudly rather
# than silently provisioning login-less roles.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/space-db-bootstrap-roles.sh"
"$SCRIPT_DIR/space-db-migrate.sh" up
"$SCRIPT_DIR/space-db-bootstrap-roles.sh"
