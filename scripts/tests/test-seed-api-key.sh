#!/usr/bin/env bash
# Regression test for how scripts/seed-api-key.sh handles a caller-supplied
# raw token.
#
# The key it mints is a long-lived production credential. Two ways the script
# can leak one during credential provisioning:
#
#   * printing `E2B_API_KEY=<raw token>` on stdout when the caller already had
#     the token — a CI log, a scrollback buffer, or a terminal
#     recording then holds the credential for nothing, since the caller
#     learned nothing it did not already know; and
#   * taking the token in argv, where every other process on the host reads it
#     out of `ps` for the lifetime of the invocation.
#
# The generated-token path is different and must keep printing: there the
# stdout line is the only copy the operator will ever see.
#
# Every case runs without --execute and without --secrets-manager-key, so
# nothing here contacts Kubernetes or AWS.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../seed-api-key.sh"

ORG_ID="00000000-0000-0000-0000-000000000002"
USER_ID="00000000-0000-0000-0000-000000000020"
TOKEN="e2b_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"
# printf '%s' "$TOKEN" | shasum -a 256
TOKEN_HASH="e195200e0d9d1e7f4ca027e0c6eb521e2383ab1c233be76252129d003afdc6b3"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'PASS: %s\n' "$*"
}

seed() {
  bash "${SCRIPT}" --org-id "${ORG_ID}" --created-by "${USER_ID}" --name test-key "$@"
}

# A caller-supplied token must not be echoed back.
out="$(seed --token "${TOKEN}")"
if grep -q "${TOKEN}" <<<"${out}"; then
  fail "--token echoes the raw credential to stdout"
else
  pass "--token keeps the raw credential out of stdout"
fi
if grep -q "KEY_HASH=${TOKEN_HASH}" <<<"${out}"; then
  pass "--token still reports the key hash"
else
  fail "--token did not report KEY_HASH=${TOKEN_HASH}"
fi

# --token-file is the argv-free way in, and must hash identically.
token_file="${WORK_DIR}/token"
(umask 077 && printf '%s' "${TOKEN}" >"${token_file}")
out="$(seed --token-file "${token_file}")"
if grep -q "KEY_HASH=${TOKEN_HASH}" <<<"${out}"; then
  pass "--token-file hashes the same token as --token"
else
  fail "--token-file did not report KEY_HASH=${TOKEN_HASH}"
fi
if grep -q "${TOKEN}" <<<"${out}"; then
  fail "--token-file echoes the raw credential to stdout"
else
  pass "--token-file keeps the raw credential out of stdout"
fi

# A trailing newline in the file is the shape `aws ... --output text > file`
# produces; hashing it would silently mint a key nobody can authenticate with.
printf '%s\n' "${TOKEN}" >"${WORK_DIR}/token-nl"
out="$(seed --token-file "${WORK_DIR}/token-nl")"
if grep -q "KEY_HASH=${TOKEN_HASH}" <<<"${out}"; then
  pass "--token-file ignores a trailing newline"
else
  fail "--token-file hashed the trailing newline"
fi

# The generated path is the one case where stdout is the only copy.
out="$(seed)"
if grep -qE '^E2B_API_KEY=[0-9a-f]{64}$' <<<"${out}"; then
  pass "a generated token is still printed"
else
  fail "a generated token was not printed"
fi

# Native callers receive the native bearer variable, while the default ECW
# surface retains its E2B SDK-compatible output contract.
out="$(seed --surface native)"
if grep -qE '^SPACE_API_TOKEN=[0-9a-f]{64}$' <<<"${out}" &&
   ! grep -q '^E2B_API_KEY=' <<<"${out}"; then
  pass "the native path prints SPACE_API_TOKEN"
else
  fail "the native path did not print SPACE_API_TOKEN exclusively"
fi

# Ambiguous input is an error, not a silent winner.
if seed --token "${TOKEN}" --token-file "${token_file}" >/dev/null 2>&1; then
  fail "--token and --token-file together were accepted"
else
  pass "--token and --token-file together are rejected"
fi

if seed --token-file "${WORK_DIR}/missing" >/dev/null 2>&1; then
  fail "--token-file accepted a missing file"
else
  pass "--token-file rejects a missing file"
fi

: >"${WORK_DIR}/empty"
if seed --token-file "${WORK_DIR}/empty" >/dev/null 2>&1; then
  fail "--token-file accepted an empty file"
else
  pass "--token-file rejects an empty file"
fi

# --- bootstrapping independent organizations -----------------------------
#
# Independent organizations need separate rate limits, quotas, and accounting.
# Bootstrapping must accept the organization and service user as parameters.
#
# The user is not optional garnish. `sandboxes.user_id` is NOT NULL, and the ECW
# auth query resolves it through a LATERAL join that falls back to the org's
# oldest user when `api_keys.created_by` is NULL — an org with no user rows
# cannot own a sandbox at all.

bootstrap() {
  bash "${SCRIPT}" --name test-key "$@"
}

out="$(bootstrap --bootstrap-org smoke-org --bootstrap-org-name 'Smoke Org' \
                 --bootstrap-user 'smoke@local')"
for want in "'smoke-org'" "'Smoke Org'" "'smoke@local'" "'!'" "'member'"; do
  if grep -qF "${want}" <<<"${out}"; then
    pass "--bootstrap-org emits ${want}"
  else
    fail "--bootstrap-org did not emit ${want}"
  fi
done

# The display name defaults to the org name rather than demanding a fourth flag.
out="$(bootstrap --bootstrap-org smoke-org --bootstrap-org-name 'Smoke Org' \
                 --bootstrap-user 'smoke@local' --bootstrap-user-display 'Smoke Bot' \
                 --bootstrap-user-role organization_admin)"
if grep -qF "'Smoke Bot'" <<<"${out}" && grep -qF "'organization_admin'" <<<"${out}"; then
  pass "--bootstrap-user-display and --bootstrap-user-role are honored"
else
  fail "--bootstrap-user-display / --bootstrap-user-role were ignored"
fi

# Partial or conflicting bootstrap input is an error, not a half-built org.
if bootstrap --bootstrap-org smoke-org --bootstrap-org-name 'Smoke Org' >/dev/null 2>&1; then
  fail "--bootstrap-org without --bootstrap-user was accepted"
else
  pass "--bootstrap-org without --bootstrap-user is rejected"
fi

if bootstrap --bootstrap-org smoke-org --bootstrap-user 'smoke@local' >/dev/null 2>&1; then
  fail "--bootstrap-org without --bootstrap-org-name was accepted"
else
  pass "--bootstrap-org without --bootstrap-org-name is rejected"
fi

if bootstrap --bootstrap-org smoke-org --bootstrap-org-name 'Smoke Org' \
             --bootstrap-user 'smoke@local' --org-id "${ORG_ID}" >/dev/null 2>&1; then
  fail "--bootstrap-org and --org-id together were accepted"
else
  pass "--bootstrap-org and --org-id together are rejected"
fi

if bootstrap --bootstrap-org smoke-org --bootstrap-org-name 'Smoke Org' \
             --bootstrap-user 'smoke@local' --bootstrap-user-role root >/dev/null 2>&1; then
  fail "--bootstrap-user-role accepted a value outside the users_role_check set"
else
  pass "--bootstrap-user-role rejects a value outside users_role_check"
fi

# A bootstrap flag without --bootstrap-org must not be silently dropped.
#
# Omitting --bootstrap-org while passing its companions falls through to the
# plain --org-id/--created-by path, which succeeds and inserts the key into the
# *existing* org — discarding the request to create an isolated one. That is the
# exact outcome this whole change exists to prevent, arrived at by a typo.
for flag_value in \
  "--bootstrap-org-name:Smoke Org" \
  "--bootstrap-user:smoke@local" \
  "--bootstrap-user-display:Smoke Bot" \
  "--bootstrap-user-role:organization_admin"; do
  flag="${flag_value%%:*}"
  value="${flag_value#*:}"
  if bash "${SCRIPT}" --name test-key --org-id "${ORG_ID}" --created-by "${USER_ID}" \
       "${flag}" "${value}" >/dev/null 2>&1; then
    fail "${flag} without --bootstrap-org was silently ignored"
  else
    pass "${flag} without --bootstrap-org is rejected"
  fi
done

# The plain path itself must keep working.
if bash "${SCRIPT}" --name test-key --org-id "${ORG_ID}" --created-by "${USER_ID}" >/dev/null 2>&1; then
  pass "--org-id/--created-by alone still works"
else
  fail "--org-id/--created-by alone no longer works"
fi

# Operator-supplied strings reach SQL, so quoting has to survive one.
out="$(bootstrap --bootstrap-org smoke-org --bootstrap-org-name "O'Brien Smoke" \
                 --bootstrap-user 'smoke@local')"
if grep -qF "'O''Brien Smoke'" <<<"${out}"; then
  pass "a quote in an operator-supplied name is escaped for SQL"
else
  fail "a quote in an operator-supplied name was not escaped"
fi

# Surface and assertion trust are independent, explicit choices in both
# issuance paths. The old default remains ECW-only with no assertion trust.
for issuance in existing bootstrap; do
  for surface in ecw native; do
    for trust in false true; do
      args=(--token-file "${token_file}")
      if [[ "${surface}" == native ]]; then
        args+=(--surface native)
      fi
      if [[ "${trust}" == true ]]; then
        args+=(--federated-owner-assertions)
      fi
      if [[ "${issuance}" == bootstrap ]]; then
        out="$(bootstrap --bootstrap-org smoke-org --bootstrap-org-name 'Smoke Org' \
                         --bootstrap-user 'smoke@local' "${args[@]}")"
      else
        out="$(seed "${args[@]}")"
      fi
      if grep -qF "allowed_surfaces, federated_owner_assertions_enabled" <<<"${out}" &&
         grep -qFx "  ARRAY['${surface}']," <<<"${out}" &&
         grep -qFx "  ${trust}" <<<"${out}" &&
         [[ "$(grep -cF "ARRAY[" <<<"${out}")" == 1 ]]; then
        pass "${issuance} emits only ${surface} with assertion trust ${trust}"
      else
        fail "${issuance} lost exclusive ${surface} scope or assertion trust ${trust}"
      fi
      if grep -qF "${TOKEN}" <<<"${out}"; then
        fail "${issuance}/${surface}/${trust} echoed a supplied token"
      fi
    done
  done
done

out="$(seed --token-file "${token_file}" --surface ecw)"
if grep -qFx "  ARRAY['ecw']," <<<"${out}" &&
   grep -qFx "  false" <<<"${out}"; then
  pass "explicit ECW keeps assertion trust disabled"
else
  fail "explicit ECW changed the default trust"
fi

for invalid_surface in '' both 'native,ecw' "native'); SELECT 1; --"; do
  if seed --token-file "${token_file}" --surface "${invalid_surface}" >/dev/null 2>&1; then
    fail "invalid or combined surface was accepted"
  else
    pass "invalid or combined surface is rejected"
  fi
done
if seed --surface >/dev/null 2>&1; then
  fail "--surface without a value was accepted"
else
  pass "--surface without a value is rejected"
fi

# --- --secrets-manager-key with a caller-supplied token -------------------
#
# The refusal has to fire on the flag combination, not on whether the secret
# happens to exist. Checking it only in the already-exists branch leaves the
# dangerous half open: run the pair against an account where the id is absent
# and the script cheerfully creates the secret there, planting a raw production
# bearer token into a second AWS account and printing a success-shaped
# `E2B_API_KEY_SECRET=` line. That is the mint's step 3 exactly — the cluster's
# account, where the sandbox-side id does not exist.
#
# A stub `aws` stands in for both branches so nothing here touches real AWS.
# The script redirects create-secret's stdout to /dev/null, so the stub records
# the call in a marker file instead of printing it.
CREATE_MARKER="${WORK_DIR}/create-secret-called"

stub_aws() {
  # Two locals on purpose: in a single `local`, dir would be expanded before
  # mode took effect and would silently read the caller's global instead.
  local mode="$1"
  local dir="${WORK_DIR}/stub-${mode}"
  mkdir -p "${dir}"
  cat >"${dir}/aws" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *describe-secret*)
  if [ "${mode}" = absent ]; then
      echo "An error occurred (ResourceNotFoundException) ..." >&2
      exit 254
  fi
  echo '{"Name":"x"}'; exit 0 ;;
  *create-secret*) echo "\$*" >>"${CREATE_MARKER}"; exit 0 ;;
  *get-secret-value*) printf 'e2b_deadbeef\n'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "${dir}/aws"
  printf '%s' "${dir}"
}

created() { [[ -s "${CREATE_MARKER}" ]]; }

rm -f "${CREATE_MARKER}"
PATH="$(stub_aws absent):${PATH}" \
  seed --surface 'native,ecw' --secrets-manager-key some/secret/id >/dev/null 2>&1 && rc=0 || rc=$?
if [[ "${rc}" -ne 0 ]] && ! created; then
  pass "invalid surface is rejected before secret creation"
else
  fail "invalid surface reached secret creation"
fi

for mode in absent exists; do
  rm -f "${CREATE_MARKER}"
  PATH="$(stub_aws "${mode}"):${PATH}" \
    seed --token "${TOKEN}" --secrets-manager-key some/secret/id >/dev/null 2>&1 && rc=0 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    pass "--secrets-manager-key + --token rejected when the secret is ${mode}"
  else
    fail "--secrets-manager-key + --token accepted when the secret is ${mode}"
  fi
  if created; then
    fail "--secrets-manager-key + --token created a secret (${mode})"
  else
    pass "--secrets-manager-key + --token created no secret (${mode})"
  fi
done

# The same has to hold for the argv-free spelling.
rm -f "${CREATE_MARKER}"
PATH="$(stub_aws absent):${PATH}" \
  seed --token-file "${token_file}" --secrets-manager-key some/secret/id >/dev/null 2>&1 && rc=0 || rc=$?
if [[ "${rc}" -ne 0 ]] && ! created; then
  pass "--secrets-manager-key + --token-file rejected before any create"
else
  fail "--secrets-manager-key + --token-file was not rejected"
fi

# --secrets-manager-key alone must still generate a token and create the
# secret; rejecting that would break the documented step 1.
rm -f "${CREATE_MARKER}"
PATH="$(stub_aws absent):${PATH}" seed --secrets-manager-key some/secret/id >/dev/null 2>&1
if created; then
  pass "--secrets-manager-key alone still creates the secret"
else
  fail "--secrets-manager-key alone no longer creates the secret"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
  printf '\n%d check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nAll checks passed.\n'
