#!/usr/bin/env bash
# Regression test for where the containerd shim gets published.
#
# Exercises configured branch routing and ensures a failed upload to any
# target fails the build rather than shipping a SHA to only some clusters.
#
# run-shim-build.sh only calls main() when executed directly, so each case can
# source it and call the function under test.
#
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_SCRIPT="${TEST_DIR}/run-shim-build.sh"

EXPECT_TESTING="example-testing-bootstrap"
EXPECT_PROD="example-prod-bootstrap"
EXPECT_PROD_2="example-prod-2-bootstrap"
EXPECT_PROD_3="example-prod-3-bootstrap"
EXPECT_MAIN="${EXPECT_TESTING},${EXPECT_PROD},${EXPECT_PROD_2},${EXPECT_PROD_3}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

FAILURES=0

check() {
  local desc="$1" want="$2" got="$3"
  if [[ "${got}" == "${want}" ]]; then
    printf 'PASS: %s\n' "${desc}"
    return
  fi
  printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${desc}" "${want}" "${got}" >&2
  FAILURES=$((FAILURES + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

# ── resolve_target_buckets ───────────────────────────────────────────────────

targets_for() {
  (
    unset SPACE_SHIM_BUCKETS
    export BUILDKITE_BRANCH="$1" BUILDKITE_PULL_REQUEST="$2"
    export SPACE_SHIM_MAIN_BUCKETS="$EXPECT_MAIN" SPACE_SHIM_BRANCH_BUCKETS="$EXPECT_TESTING"
    if [[ $# -ge 3 ]]; then export SPACE_SHIM_BUCKETS="$3"; fi
    # shellcheck source=./run-shim-build.sh
    source "${SHIM_SCRIPT}"
    resolve_target_buckets
  )
}

check "main builds fan out to every cluster bucket" \
  "${EXPECT_MAIN}" \
  "$(targets_for main false)"

check "refs/heads/main is resolved as main" \
  "${EXPECT_MAIN}" \
  "$(targets_for refs/heads/main false)"

check "PR builds publish to testing only" \
  "${EXPECT_TESTING}" \
  "$(targets_for main 4867)"

check "non-main branches publish to testing only" \
  "${EXPECT_TESTING}" \
  "$(targets_for feature/shim false)"

check "SPACE_SHIM_BUCKETS overrides the resolved set" \
  "override-a,override-b" \
  "$(targets_for main false override-a,override-b)"

for branch in main feature/shim; do
  if env -u SPACE_SHIM_BUCKETS -u SPACE_SHIM_MAIN_BUCKETS -u SPACE_SHIM_BRANCH_BUCKETS \
    BUILDKITE_BRANCH="$branch" BUILDKITE_PULL_REQUEST=false \
    bash -c 'source "$1"; resolve_target_buckets' _ "$SHIM_SCRIPT" \
      >"${WORK_DIR}/targets" 2>"${WORK_DIR}/error"; then
    fail "$branch accepted missing bucket configuration"
  fi
  [[ ! -s "${WORK_DIR}/targets" ]] || fail "$branch resolved unconfigured targets"
  grep -Fq SPACE_SHIM_ "${WORK_DIR}/error" || fail "$branch omitted the configuration error"
done

# ── publish_shim fan-out ─────────────────────────────────────────────────────

# Stub `aws` so publish_shim can run without credentials or a built binary.
# Every invocation is recorded; the stub fails the upload when a destination
# names STUB_FAIL_BUCKET.
mkdir -p "${WORK_DIR}/bin"
cat >"${WORK_DIR}/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CALLS}"
if [[ -n "${STUB_FAIL_BUCKET:-}" && "$*" == *"${STUB_FAIL_BUCKET}"* ]]; then
  printf 'stub: upload denied for %s\n' "$*" >&2
  exit 1
fi
STUB
chmod +x "${WORK_DIR}/bin/aws"

# Runs publish_shim for a main build and echoes its exit status. Uploads
# touching "$1" fail; pass "" for the all-succeed case. The stub's recorded
# invocations land in "${WORK_DIR}/calls".
#
# The publish runs in its own `bash -c` rather than a subshell of this test:
# relaxing errexit here to capture a non-zero status would also relax it inside
# publish_to_bucket, which is exactly the behavior under test.
publish_exit_status() {
  local fail_bucket="$1" status=0
  : >"${WORK_DIR}/calls"
  # SC2016: "$1" is expanded by the inner shell, not here.
  # SC2031: PATH is only "modified in a subshell" from run-shim-build.sh's own
  # install_go, which this test never calls.
  # shellcheck disable=SC2016,SC2031
  env -u SPACE_SHIM_BUCKETS \
    SPACE_SHIM_MAIN_BUCKETS="$EXPECT_MAIN" \
    SPACE_SHIM_BRANCH_BUCKETS="$EXPECT_TESTING" \
    BUILDKITE_BRANCH="main" \
    BUILDKITE_PULL_REQUEST="false" \
    BUILDKITE_COMMIT="0000000000000000000000000000000000000000" \
    STUB_CALLS="${WORK_DIR}/calls" \
    STUB_FAIL_BUCKET="${fail_bucket}" \
    PATH="${WORK_DIR}/bin:${PATH}" \
    bash -c '
      source "$1"
      # The stub already provides `aws`; skip the real installer.
      run_install_tools() { :; }
      publish_shim
    ' _ "${SHIM_SCRIPT}" >/dev/null 2>&1 || status=$?
  printf '%s' "${status}"
}

check "publishing to every target bucket succeeds" "0" "$(publish_exit_status "")"

for bucket in "${EXPECT_TESTING}" "${EXPECT_PROD}" "${EXPECT_PROD_2}" "${EXPECT_PROD_3}"; do
  if ! grep -q "s3://${bucket}/containerd-shim-space-v2/" "${WORK_DIR}/calls"; then
    fail "publish_shim never uploaded to ${bucket}"
    continue
  fi
  printf 'PASS: publish_shim uploads to %s\n' "${bucket}"
done

check "a failed prod-2 upload fails the build" \
  "1" \
  "$(publish_exit_status "${EXPECT_PROD_2}")"

# ── Result ───────────────────────────────────────────────────────────────────

if [[ "${FAILURES}" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nAll shim publish target checks passed\n'
