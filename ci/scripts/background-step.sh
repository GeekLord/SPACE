#!/usr/bin/env bash
# Run a GitHub Actions setup command in the background, so the steps after it
# overlap it, and wait for it in a later step.
#
# `start` returns at once. `wait` blocks until the command exits, prints its
# output, and exits with its status, so the waiting step fails exactly where
# the command's own step would have. A command that dies without recording a
# status, for example because it was killed, fails the wait as well.
#
# Usage: ci/scripts/background-step.sh start <name> <command>...
#        ci/scripts/background-step.sh wait <name>
#
# The state lives in ${RUNNER_TEMP}/background-steps/<name>. The runner kills
# anything still running when the job ends.
set -euo pipefail

state_dir() {
    printf '%s/background-steps/%s\n' "${RUNNER_TEMP:?}" "$1"
}

start() {
    local dir
    dir="$(state_dir "$1")"
    shift
    mkdir -p "${dir}"
    rm -f "${dir}/status"
    # The job applies its own redirections after the fork. Create its output
    # first, so a job killed before then still leaves `wait` a file to print,
    # and `wait` reports the missing status instead of failing to read it.
    : >"${dir}/output"
    # Every stream is redirected, so the starting step does not wait for the
    # command's output. The status is renamed into place, so `wait` never reads
    # a partly written one.
    (
        status=0
        "$@" || status=$?
        echo "${status}" >"${dir}/status.tmp"
        mv "${dir}/status.tmp" "${dir}/status"
    ) </dev/null >"${dir}/output" 2>&1 &
    echo "$!" >"${dir}/pid"
}

wait_for() {
    local dir pid
    dir="$(state_dir "$1")"
    pid="$(cat "${dir}/pid")"
    while [ ! -e "${dir}/status" ] && kill -0 "${pid}" 2>/dev/null; do
        sleep 0.2
    done
    cat "${dir}/output"
    if [ ! -e "${dir}/status" ]; then
        echo "::error::$1 exited without recording its status"
        return 1
    fi
    return "$(cat "${dir}/status")"
}

case "${1:-}" in
    start)
        [ $# -ge 3 ] || { echo "usage: $0 start <name> <command>..." >&2; exit 2; }
        shift
        start "$@"
        ;;
    wait)
        [ $# -eq 2 ] || { echo "usage: $0 wait <name>" >&2; exit 2; }
        wait_for "$2"
        ;;
    *)
        echo "usage: $0 start <name> <command>...|wait <name>" >&2
        exit 2
        ;;
esac
