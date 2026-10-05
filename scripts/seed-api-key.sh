#!/usr/bin/env bash
# Generate a SPACE API token and the SQL row needed to seed it.
#
# By default, this script does not connect to Postgres. Run the emitted SQL
# from an environment that can reach the SPACE control-plane database.
set -euo pipefail

PROGRAM_NAME="${0##*/}"

usage() {
  printf 'Usage:\n  %s --org-id <uuid> --created-by <user-uuid> --name <key-name> [--execute]\n  %s --bootstrap-org <slug> --bootstrap-org-name <name> \\\n      --bootstrap-user <email> --name <key-name> [--execute]\n' \
    "$PROGRAM_NAME" "$PROGRAM_NAME"
  cat <<'EOF'

Options:
  --token <raw-token>          Use an existing raw token instead of generating one.
                               Visible in ps for the life of the run; prefer
                               --token-file for a production credential.
  --token-file <path>          Read an existing raw token from a file. Trailing
                               newlines are stripped, so the output of
                               `aws secretsmanager get-secret-value ... --output text`
                               can be redirected straight into it.
  --surface <ecw|native>       Restrict the credential to one API surface.
                               Defaults to ecw; never grants both surfaces.
  --federated-owner-assertions Trust this key to assert upstream owner headers.
                               Defaults to off. Enable only for a designated
                               first-party caller, not an end-user credential.
  --bootstrap-org <slug>       Create an organization with this slug and a service
                               user inside it, then hang the key off both. Needs
                               --bootstrap-org-name and --bootstrap-user. Use a dedicated smoke
                               organization to isolate test quota and accounting.
  --bootstrap-org-name <name>  Display name for --bootstrap-org.
  --bootstrap-user <email>     Service-user email for --bootstrap-org. A user is
                               required, not optional: sandboxes.user_id is NOT
                               NULL and is resolved from the org's users, so an
                               org with none cannot own a sandbox.
  --bootstrap-user-display <n> Service-user display name. Defaults to the org name.
  --bootstrap-user-role <role> organization_admin or member. Defaults to member;
                               the ECW key path does not branch on it.
  --execute                    Execute the SQL through a short-lived Kubernetes pod.
  --context <kubectl-context>  Kubernetes context to use. Defaults to current context.
  --namespace <namespace>      Namespace for the helper pod. Defaults to current namespace.
  --secret-namespace <ns>      Namespace containing the Postgres secret. Default: space.
  --secret-name <name>         Postgres secret name. Default: space-postgres.
  --secret-key <key>           Postgres connection secret key. Default: POSTGRES_CONNECTION_STRING.
  --pod-name <name>            Helper pod name. Defaults to a generated name.
  --pod-image <image>          Helper pod image. Default: postgres:17.
  --secrets-manager-key <id>   Store/read the raw token in AWS Secrets Manager.
  -h, --help                  Show this help.

Output:
  E2B_API_KEY=<raw token> for ECW, or SPACE_API_TOKEN=<raw token> for native,
  only when this run generated the token. Secrets Manager output uses the
  corresponding E2B_API_KEY_SECRET or SPACE_API_TOKEN_SECRET name.
  KEY_HASH=<sha256 hex>

  A token supplied with --token or --token-file is never echoed back: the
  caller already has it, and printing it puts a long-lived credential into
  terminal scrollback and CI logs for nothing.
  SQL insert for api_keys
  or, when bootstrapping, SQL inserts for the org, its service user, and the
  api_keys row, in one transaction

Store the raw credential in a secret manager. SPACE stores only KEY_HASH.

Execute mode:
  --execute copies the Postgres connection string from the secret namespace into
  a temporary secret in the helper pod namespace, schedules a postgres:17 pod on
  the general node pool, runs the insert with psql, and removes the pod and
  temporary secret on exit.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

sql_literal() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{print $1}'
  else
    die "one of shasum, sha256sum, or openssl is required"
  fi
}

current_kube_namespace() {
  local namespace
  namespace="$(kubectl_cmd config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)"
  if [[ -n "$namespace" ]]; then
    printf '%s\n' "$namespace"
  else
    printf 'default\n'
  fi
}

kubectl_cmd() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

base64_decode() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

validate_kube_name() {
  local field="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [[ ${#value} -gt 63 ]]; then
    die "$field must be a DNS label"
  fi
}

validate_secret_key() {
  local value="$1"

  if [[ ! "$value" =~ ^[-._a-zA-Z0-9]+$ ]]; then
    die "--secret-key must contain only letters, numbers, '.', '-', or '_'"
  fi
}

insert_sql() {
  if [[ -n "$BOOTSTRAP_ORG_SLUG" ]]; then
    cat <<EOF
BEGIN;

WITH inserted_org AS (
  INSERT INTO organizations (id, name, slug, parent_id)
  VALUES (
    gen_random_uuid(),
    $(sql_literal "$BOOTSTRAP_ORG_NAME"),
    $(sql_literal "$BOOTSTRAP_ORG_SLUG"),
    NULL
  )
  RETURNING id
),
inserted_user AS (
  INSERT INTO users (id, email, password_hash, display_name, org_id, role)
  SELECT
    gen_random_uuid(),
    $(sql_literal "$BOOTSTRAP_USER_EMAIL"),
    '!',
    $(sql_literal "$BOOTSTRAP_USER_DISPLAY"),
    inserted_org.id,
    $(sql_literal "$BOOTSTRAP_USER_ROLE")
  FROM inserted_org
  RETURNING id
)
INSERT INTO api_keys (org_id, name, key_hash, created_by, allowed_surfaces, federated_owner_assertions_enabled)
SELECT
  inserted_org.id,
  $(sql_literal "$KEY_NAME"),
  $(sql_literal "$KEY_HASH"),
  inserted_user.id,
  ARRAY[$(sql_literal "$SURFACE")],
  $FEDERATED_OWNER_ASSERTIONS
FROM inserted_org
CROSS JOIN inserted_user
RETURNING org_id, created_by;

COMMIT;
EOF
    return
  fi

  cat <<EOF
INSERT INTO api_keys (org_id, name, key_hash, created_by, allowed_surfaces, federated_owner_assertions_enabled)
VALUES (
  $(sql_literal "$ORG_ID"),
  $(sql_literal "$KEY_NAME"),
  $(sql_literal "$KEY_HASH"),
  $(sql_literal "$CREATED_BY"),
  ARRAY[$(sql_literal "$SURFACE")],
  $FEDERATED_OWNER_ASSERTIONS
);
EOF
}

cleanup_execute_resources() {
  if [[ -n "$CONNECTION_STRING_FILE" ]]; then
    rm -f "$CONNECTION_STRING_FILE"
  fi

  if [[ -n "$SECRETS_MANAGER_VALUE_FILE" ]]; then
    rm -f "$SECRETS_MANAGER_VALUE_FILE"
  fi

  if [[ "$EXECUTE" != "true" ]]; then
    return
  fi

  if [[ "$POD_CREATED" == "true" ]]; then
    kubectl_cmd -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  if [[ "$TEMP_SECRET_CREATED" == "true" ]]; then
    kubectl_cmd -n "$NAMESPACE" delete secret "$TEMP_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

execute_sql() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required for --execute"

  if [[ -z "$NAMESPACE" ]]; then
    NAMESPACE="$(current_kube_namespace)"
  fi

  if [[ -z "$POD_NAME" ]]; then
    POD_NAME="seed-api-key-$(date +%s)-$$"
  fi

  validate_kube_name "--namespace" "$NAMESPACE"
  validate_kube_name "--secret-namespace" "$SECRET_NAMESPACE"
  validate_kube_name "--secret-name" "$SECRET_NAME"
  validate_kube_name "--pod-name" "$POD_NAME"
  validate_secret_key "$SECRET_KEY"

  TEMP_SECRET_NAME="$POD_NAME"
  CONNECTION_STRING_FILE="$(mktemp)"
  chmod 600 "$CONNECTION_STRING_FILE"

  local encoded_connection_string
  encoded_connection_string="$(
    kubectl_cmd -n "$SECRET_NAMESPACE" get secret "$SECRET_NAME" \
      -o "go-template={{ index .data \"${SECRET_KEY}\" }}" \
  )"
  [[ -n "$encoded_connection_string" ]] || die "secret $SECRET_NAMESPACE/$SECRET_NAME is missing key $SECRET_KEY"
  printf '%s' "$encoded_connection_string" | base64_decode > "$CONNECTION_STRING_FILE"

  kubectl_cmd -n "$NAMESPACE" create secret generic "$TEMP_SECRET_NAME" \
    "--from-file=${SECRET_KEY}=${CONNECTION_STRING_FILE}" >/dev/null
  TEMP_SECRET_CREATED="true"

  local pod_overrides
  pod_overrides="$(cat <<EOF
{"spec":{"nodeSelector":{"space.pplx.net/node-pool":"general"},"containers":[{"name":"${POD_NAME}","image":"${POD_IMAGE}","env":[{"name":"PGCONNECT_TIMEOUT","value":"10"}],"envFrom":[{"secretRef":{"name":"${TEMP_SECRET_NAME}"}}],"command":["sleep","3600"]}]}}
EOF
)"

  kubectl_cmd -n "$NAMESPACE" run "$POD_NAME" \
    --image="$POD_IMAGE" \
    --restart=Never \
    --overrides="$pod_overrides" >/dev/null
  POD_CREATED="true"

  kubectl_cmd -n "$NAMESPACE" wait "pod/$POD_NAME" \
    --for=condition=Ready \
    --timeout=120s >/dev/null

  insert_sql | kubectl_cmd -n "$NAMESPACE" exec -i "pod/$POD_NAME" -- \
    sh -lc "psql \"\$${SECRET_KEY}\" -v ON_ERROR_STOP=1"
}

ensure_raw_token() {
  if [[ -n "$RAW_TOKEN" ]]; then
    return
  fi

  command -v openssl >/dev/null 2>&1 || die "openssl is required to generate a token"
  RAW_TOKEN="$(openssl rand -hex 32)"
  TOKEN_GENERATED="true"
}

read_token_file() {
  local path="$1"

  [[ -f "$path" ]] || die "--token-file $path does not exist"
  # Command substitution strips trailing newlines, which is what a redirected
  # `aws ... --output text` leaves behind. Hashing that newline would mint a
  # key that authenticates nothing.
  RAW_TOKEN="$(<"$path")"
  [[ -n "$RAW_TOKEN" ]] || die "--token-file $path is empty"
  [[ "$RAW_TOKEN" != *[[:space:]]* ]] || die "--token-file $path contains whitespace"
  RAW_TOKEN_FROM_ARG="$RAW_TOKEN"
}

sync_secrets_manager_key() {
  if [[ -z "$SECRETS_MANAGER_KEY" ]]; then
    return
  fi

  command -v aws >/dev/null 2>&1 || die "aws is required for --secrets-manager-key"

  local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
  local describe_output
  if describe_output="$(
    aws secretsmanager describe-secret \
      --region "$region" \
      --secret-id "$SECRETS_MANAGER_KEY" 2>&1
  )"; then
    RAW_TOKEN="$(
      aws secretsmanager get-secret-value \
        --region "$region" \
        --secret-id "$SECRETS_MANAGER_KEY" \
        --query SecretString \
        --output text
    )"
    [[ -n "$RAW_TOKEN" ]] || die "AWS secret $SECRETS_MANAGER_KEY has an empty SecretString"
    return
  fi

  if [[ "$describe_output" != *"ResourceNotFoundException"* ]]; then
    die "failed to describe AWS secret $SECRETS_MANAGER_KEY: $describe_output"
  fi

  ensure_raw_token
  SECRETS_MANAGER_VALUE_FILE="$(mktemp)"
  chmod 600 "$SECRETS_MANAGER_VALUE_FILE"
  printf '%s' "$RAW_TOKEN" > "$SECRETS_MANAGER_VALUE_FILE"

  aws secretsmanager create-secret \
    --region "$region" \
    --name "$SECRETS_MANAGER_KEY" \
    --description "SPACE API key generated by scripts/seed-api-key.sh" \
    --secret-string "file://$SECRETS_MANAGER_VALUE_FILE" >/dev/null
}

ORG_ID=""
CREATED_BY=""
KEY_NAME=""
SURFACE="ecw"
FEDERATED_OWNER_ASSERTIONS="false"
RAW_TOKEN=""
RAW_TOKEN_FROM_ARG=""
TOKEN_FILE=""
TOKEN_GENERATED="false"
BOOTSTRAP_ORG_SLUG=""
BOOTSTRAP_ORG_NAME=""
BOOTSTRAP_USER_EMAIL=""
BOOTSTRAP_USER_DISPLAY=""
BOOTSTRAP_USER_ROLE="member"
# The role has a default, so emptiness cannot distinguish "not passed" from
# "passed the default" when checking for orphaned bootstrap arguments below.
BOOTSTRAP_USER_ROLE_SET="false"
EXECUTE="false"
KUBE_CONTEXT=""
NAMESPACE=""
SECRET_NAMESPACE="space"
SECRET_NAME="space-postgres"
SECRET_KEY="POSTGRES_CONNECTION_STRING"
POD_NAME=""
POD_IMAGE="postgres:17"
TEMP_SECRET_NAME=""
CONNECTION_STRING_FILE=""
TEMP_SECRET_CREATED="false"
POD_CREATED="false"
SECRETS_MANAGER_KEY=""
SECRETS_MANAGER_VALUE_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id)
      [[ $# -ge 2 ]] || die "--org-id requires a value"
      ORG_ID="$2"
      shift 2
      ;;
    --created-by)
      [[ $# -ge 2 ]] || die "--created-by requires a value"
      CREATED_BY="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      KEY_NAME="$2"
      shift 2
      ;;
    --surface)
      [[ $# -ge 2 ]] || die "--surface requires a value"
      SURFACE="$2"
      shift 2
      ;;
    --federated-owner-assertions)
      FEDERATED_OWNER_ASSERTIONS="true"
      shift
      ;;
    --token)
      [[ $# -ge 2 ]] || die "--token requires a value"
      RAW_TOKEN="$2"
      RAW_TOKEN_FROM_ARG="$2"
      shift 2
      ;;
    --token-file)
      [[ $# -ge 2 ]] || die "--token-file requires a value"
      TOKEN_FILE="$2"
      shift 2
      ;;
    --bootstrap-org)
      [[ $# -ge 2 ]] || die "--bootstrap-org requires a value"
      BOOTSTRAP_ORG_SLUG="$2"
      shift 2
      ;;
    --bootstrap-org-name)
      [[ $# -ge 2 ]] || die "--bootstrap-org-name requires a value"
      BOOTSTRAP_ORG_NAME="$2"
      shift 2
      ;;
    --bootstrap-user)
      [[ $# -ge 2 ]] || die "--bootstrap-user requires a value"
      BOOTSTRAP_USER_EMAIL="$2"
      shift 2
      ;;
    --bootstrap-user-display)
      [[ $# -ge 2 ]] || die "--bootstrap-user-display requires a value"
      BOOTSTRAP_USER_DISPLAY="$2"
      shift 2
      ;;
    --bootstrap-user-role)
      [[ $# -ge 2 ]] || die "--bootstrap-user-role requires a value"
      BOOTSTRAP_USER_ROLE="$2"
      BOOTSTRAP_USER_ROLE_SET="true"
      shift 2
      ;;
    --execute)
      EXECUTE="true"
      shift
      ;;
    --context)
      [[ $# -ge 2 ]] || die "--context requires a value"
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --secret-namespace)
      [[ $# -ge 2 ]] || die "--secret-namespace requires a value"
      SECRET_NAMESPACE="$2"
      shift 2
      ;;
    --secret-name)
      [[ $# -ge 2 ]] || die "--secret-name requires a value"
      SECRET_NAME="$2"
      shift 2
      ;;
    --secret-key)
      [[ $# -ge 2 ]] || die "--secret-key requires a value"
      SECRET_KEY="$2"
      shift 2
      ;;
    --pod-name)
      [[ $# -ge 2 ]] || die "--pod-name requires a value"
      POD_NAME="$2"
      shift 2
      ;;
    --pod-image)
      [[ $# -ge 2 ]] || die "--pod-image requires a value"
      POD_IMAGE="$2"
      shift 2
      ;;
    --secrets-manager-key)
      [[ $# -ge 2 ]] || die "--secrets-manager-key requires a value"
      SECRETS_MANAGER_KEY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -n "$BOOTSTRAP_ORG_SLUG" ]]; then
  [[ -n "$BOOTSTRAP_ORG_NAME" ]] || die "--bootstrap-org requires --bootstrap-org-name"
  [[ -n "$BOOTSTRAP_USER_EMAIL" ]] || die "--bootstrap-org requires --bootstrap-user"
  [[ -z "$ORG_ID" ]] || die "--org-id cannot be used when bootstrapping an org"
  [[ -z "$CREATED_BY" ]] || die "--created-by cannot be used when bootstrapping an org"
  # Mirrors the users_role_check constraint, so a typo fails here rather than
  # inside a transaction against a production database.
  case "$BOOTSTRAP_USER_ROLE" in
    organization_admin | member) ;;
    *) die "--bootstrap-user-role must be organization_admin or member" ;;
  esac
  BOOTSTRAP_USER_DISPLAY="${BOOTSTRAP_USER_DISPLAY:-$BOOTSTRAP_ORG_NAME}"
else
  # No bootstrap mode selected. Its companion flags must not be silently
  # dropped: omitting --bootstrap-org while passing them lands here, succeeds,
  # and inserts the key into the *existing* --org-id instead of creating the
  # isolated org that was asked for. A typo would quietly put a production
  # credential in the wrong org.
  [[ -z "$BOOTSTRAP_ORG_NAME$BOOTSTRAP_USER_EMAIL$BOOTSTRAP_USER_DISPLAY" ]] &&
    [[ "$BOOTSTRAP_USER_ROLE_SET" == "false" ]] ||
    die "--bootstrap-org-name/-user/-user-display/-user-role require --bootstrap-org"
  [[ -n "$ORG_ID" ]] || die "--org-id is required"
  [[ -n "$CREATED_BY" ]] || die "--created-by is required"
fi
[[ -n "$KEY_NAME" ]] || die "--name is required"
case "$SURFACE" in
  ecw | native) ;;
  *) die "--surface must be ecw or native" ;;
esac

if [[ "$SURFACE" == "ecw" ]]; then
  OUTPUT_VARIABLE="E2B_API_KEY"
else
  OUTPUT_VARIABLE="SPACE_API_TOKEN"
fi

if [[ -n "$TOKEN_FILE" ]]; then
  [[ -z "$RAW_TOKEN_FROM_ARG" ]] || die "--token and --token-file are mutually exclusive"
  read_token_file "$TOKEN_FILE"
fi

# Refuse on the flag combination, not on whether the secret happens to exist.
# Checked inside sync_secrets_manager_key's already-exists branch, the guard
# missed the dangerous half: against an account where the id is absent the
# script would create the secret from the caller's token, planting a raw
# production credential into a second AWS account and reporting success. That
# is reachable by simply leaving the flag on the mint's step-3 command line.
if [[ -n "$SECRETS_MANAGER_KEY" && -n "$RAW_TOKEN_FROM_ARG" ]]; then
  die "--secrets-manager-key cannot be combined with --token/--token-file; \
--secrets-manager-key both mints and stores, so supplying a token means either \
overwriting a secret or writing it into whichever account is ambient"
fi

trap cleanup_execute_resources EXIT

if [[ -n "$SECRETS_MANAGER_KEY" ]]; then
  sync_secrets_manager_key
else
  ensure_raw_token
fi

KEY_HASH="$(printf '%s' "$RAW_TOKEN" | sha256_hex)"

report_token() {
  if [[ -n "$SECRETS_MANAGER_KEY" ]]; then
    printf '%s_SECRET=%s\n' "$OUTPUT_VARIABLE" "$SECRETS_MANAGER_KEY"
  elif [[ "$TOKEN_GENERATED" == "true" ]]; then
    printf '%s=%s\n' "$OUTPUT_VARIABLE" "$RAW_TOKEN"
  else
    printf '# %s supplied by the caller; deliberately not echoed\n' "$OUTPUT_VARIABLE"
  fi
}

cat <<EOF
$(report_token)
KEY_HASH=$KEY_HASH

Store $OUTPUT_VARIABLE in a secret manager. Run this SQL from an environment that can reach the SPACE control-plane DB:

$(insert_sql)
EOF

if [[ "$EXECUTE" == "true" ]]; then
  echo
  echo "Executing SQL through Kubernetes helper pod..."
  execute_sql
  echo "Inserted API key row."
fi
