#!/usr/bin/env bash
# The Rust validation bootstrap must tolerate transient tool-download failures,
# and a losing race with the Docker daemon over the nextest Postgres container
# must not fail a job whose tests all passed.
#
# run-rust-checks.sh captures nextest's status (`|| nextest_status=$?`) and then
# calls cleanup before returning it. Under `set -euo pipefail` a non-zero
# `docker rm` inside cleanup aborts the script before that status is ever read,
# so a green 5000-test suite reports red and every dependent job cascades. The
# daemon produces exactly that when it is already removing the container:
#
#   Error response from daemon: removal of container <id> is already in progress
#
# Every other `docker rm --force` in the repo already tolerates it.
set -euo pipefail

# The function under test builds its container list with `mapfile`, a bash 4
# builtin. Under macOS's stock bash 3.2 that fails, the list stays empty, and
# the `docker rm` this test exists to exercise never runs — the test would pass
# without testing anything. Re-exec under a newer bash, or refuse.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "${candidate}" ]; then
      exec "${candidate}" "$0" "$@"
    fi
  done
  echo "FAIL: this test needs bash >= 4 (found ${BASH_VERSION}); it would pass" >&2
  echo "      vacuously otherwise. On macOS: brew install bash" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"

# `docker ps` reports one container to clean up; `docker rm` loses the race.
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ps)
    echo "b5b7bfb830ae"
    ;;
  rm)
    echo "Error response from daemon: removal of container b5b7bfb830ae is already in progress" >&2
    exit 1
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

cat >"${fake_bin}/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${CURL_ARGS_FILE}"
exit "${CURL_EXIT_STATUS:-0}"
SH
chmod +x "${fake_bin}/curl"

cat >"${fake_bin}/buildkite-agent" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BUILDKITE_AGENT_CALLS_FILE}"
if [ "${1:-}" = annotate ]; then
  cat >>"${BUILDKITE_AGENT_STDIN_FILE}"
fi
SH
chmod +x "${fake_bin}/buildkite-agent"

cat >"${fake_bin}/mkdir" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MKDIR_CALLS_FILE}"
if [ "${1:-}" = --parents ]; then
  echo "FAIL: GNU-only mkdir --parents is not supported on macOS" >&2
  exit 64
fi
command -p mkdir "$@"
SH
chmod +x "${fake_bin}/mkdir"

# Sourcing runs only env and path setup; `main` is guarded by a
# BASH_SOURCE == $0 check, so the functions are available without executing a
# validation run.
BUILDKITE="" \
  source ci/scripts/run-rust-checks.sh

if ! env -u SPACE_CI_REQUIRE_TEST_DEPS BUILDKITE=1 \
  bash -c 'source ci/scripts/run-rust-checks.sh; test "${SPACE_CI_REQUIRE_TEST_DEPS:-}" = 1'; then
  echo "FAIL: Buildkite Rust tests did not enable strict test dependencies" >&2
  exit 1
fi
if ! env -u SPACE_CI_REQUIRE_TEST_DEPS BUILDKITE= \
  bash -c 'source ci/scripts/run-rust-checks.sh; test -z "${SPACE_CI_REQUIRE_TEST_DEPS:-}"'; then
  echo "FAIL: local Rust tests unexpectedly enabled strict test dependencies" >&2
  exit 1
fi

mkdir_calls="${tmp_dir}/mkdir-calls"
skip_target_dir="${tmp_dir}/nested/buildkite-tests"
skip_log_to_reset="${skip_target_dir}/space-test-dep-skips.log"
mkdir -p "${skip_target_dir}"
printf 'stale\n' >"${skip_log_to_reset}"
MKDIR_CALLS_FILE="${mkdir_calls}" PATH="${fake_bin}:${PATH}" \
  prepare_test_dep_skip_log "${skip_target_dir}" "${skip_log_to_reset}"
grep -Fxq -- "-p ${skip_target_dir}" "${mkdir_calls}" \
  || { echo "FAIL: skip-log setup did not use portable mkdir -p" >&2; exit 1; }
test -d "${skip_target_dir}" \
  || { echo "FAIL: skip-log target directory was not created" >&2; exit 1; }
test ! -e "${skip_log_to_reset}" \
  || { echo "FAIL: stale skip log was not removed" >&2; exit 1; }

curl_args="${tmp_dir}/curl-args"
CURL_ARGS_FILE="${curl_args}" PATH="${fake_bin}:${PATH}" \
  curl_with_retries -fsSL https://example.com/tool -o "${tmp_dir}/tool"
for expected_arg in \
  --retry 5 \
  --retry-delay 2 \
  --retry-max-time 180 \
  --retry-all-errors; do
  if ! grep -Fxq -- "${expected_arg}" "${curl_args}"; then
    echo "FAIL: curl retry wrapper omitted ${expected_arg}" >&2
    exit 1
  fi
done

set +e
CURL_ARGS_FILE="${curl_args}" CURL_EXIT_STATUS=56 PATH="${fake_bin}:${PATH}" \
  curl_with_retries -fsSL https://example.com/tool -o "${tmp_dir}/tool"
curl_status="$?"
set -e
if [ "${curl_status}" -ne "${TRANSIENT_NETWORK_EXIT_STATUS}" ]; then
  echo "FAIL: exhausted curl returned ${curl_status}, expected ${TRANSIENT_NETWORK_EXIT_STATUS}" >&2
  exit 1
fi

if PATH="${fake_bin}:${PATH}" cleanup_nextest_postgres "test-cleanup-id"; then
  echo "cleanup tolerated a lost docker rm race"
else
  echo "FAIL: cleanup_nextest_postgres returned non-zero when docker rm lost a" >&2
  echo "      teardown race. Under set -e in run_test_checks this discards a" >&2
  echo "      passing nextest run and fails the whole build." >&2
  exit 1
fi

agent_calls="${tmp_dir}/buildkite-agent-calls"
agent_stdin="${tmp_dir}/buildkite-agent-stdin"
skip_log="${tmp_dir}/space-test-dep-skips.log"
export BUILDKITE_AGENT_CALLS_FILE="${agent_calls}"
export BUILDKITE_AGENT_STDIN_FILE="${agent_stdin}"
export SPACE_TEST_DEP_SKIP_LOG="${skip_log}"

printf '%s\n' \
  'SPACE-TEST-DEP-SKIP: postgres unavailable: first' \
  'SPACE-TEST-DEP-SKIP: redis unavailable: second' >"${skip_log}"
PATH="${fake_bin}:${PATH}" report_test_dep_skips >"${tmp_dir}/skip-report"
grep -Fxq 'annotate --style warning --context space-test-dep-skips' "${agent_calls}" \
  || { echo "FAIL: non-zero skip report did not publish its warning annotation" >&2; exit 1; }
grep -Fq '**2 test(s) skipped for missing test dependencies**' "${agent_stdin}" \
  || { echo "FAIL: warning annotation did not contain the skip count" >&2; exit 1; }

: >"${skip_log}"
: >"${agent_calls}"
PATH="${fake_bin}:${PATH}" report_test_dep_skips >"${tmp_dir}/clean-report"
grep -Fxq 'annotation remove --context space-test-dep-skips' "${agent_calls}" \
  || { echo "FAIL: clean retry did not remove a stale warning annotation" >&2; exit 1; }
grep -Fq 'test-dependency skip markers: 0' "${tmp_dir}/clean-report" \
  || { echo "FAIL: clean retry did not report zero skip markers" >&2; exit 1; }

echo "run-rust-checks bootstrap tests passed"
