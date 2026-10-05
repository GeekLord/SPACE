#!/usr/bin/env bash
# Regression test for ci/scripts/background-step.sh: `wait` prints the
# command's output and returns its status, and fails rather than hangs or
# passes when the command dies without recording one.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/background-step.sh"
RUNNER_TEMP="$(mktemp -d)"
export RUNNER_TEMP
trap 'rm -rf "${RUNNER_TEMP}"' EXIT

FAILURES=0
fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

bash "${SCRIPT}" start passes bash -c 'sleep 0.5; echo "::warning::kept"'
bash "${SCRIPT}" start fails bash -c 'echo broken >&2; exit 7'
# The command records nothing when the whole background job is killed. The
# kill can land before the job has applied its own redirections, and `wait`
# must report the missing status either way.
bash "${SCRIPT}" start killed sleep 5
kill "$(cat "${RUNNER_TEMP}/background-steps/killed/pid")"

output="$(bash "${SCRIPT}" wait passes)" || fail "a passing command failed its wait"
[ "${output}" = "::warning::kept" ] || fail "wait printed '${output}' for the passing command"

status=0
output="$(bash "${SCRIPT}" wait fails 2>&1)" || status=$?
[ "${status}" -eq 7 ] || fail "wait returned ${status}, not the failing command's 7"
[ "${output}" = "broken" ] || fail "wait printed '${output}' for the failing command"

status=0
output="$(bash "${SCRIPT}" wait killed)" || status=$?
[ "${status}" -ne 0 ] || fail "wait passed for a command that recorded no status"
[[ "${output}" == *"::error::killed exited without recording its status"* ]] ||
    fail "wait printed '${output}' for the killed command"

if bash "${SCRIPT}" wait never-started 2>/dev/null; then
    fail "wait passed for a command that never started"
fi

[ "${FAILURES}" -eq 0 ] || exit 1
echo "background-step tests passed"
