#!/usr/bin/env bash
# Start one shared Redis for all Redis-fixture-backed tests in a nextest run.
#
# Unlike setup-nextest-postgres.sh, this script is fail-OPEN: if Docker or the
# container can't be made ready, it exits 0 without publishing
# SPACE_TEST_REDIS_URL. Every Redis-backed test already has its own graceful
# path (skip without Docker, or fall back to starting its own throwaway
# container) via pplx_space_db_test_fixtures::require_test_deps(), so this
# script failing hard would take down the whole api package over an
# optimization, not a real missing dependency. The run-scoped Postgres setup
# stays fail-closed deliberately (see AGENTS.md); Redis does not need the same
# policy because nothing downstream of this script treats its absence as fatal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-deps.sh
source "${SCRIPT_DIR}/lib/test-deps.sh"

cleanup_when_nextest_exits() {
    local nextest_pid="$1"
    local container_id="$2"

    while kill -0 "${nextest_pid}" 2>/dev/null; do
        sleep 1
    done
    docker rm --force "${container_id}" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--cleanup-when-nextest-exits" ]; then
    cleanup_when_nextest_exits "$2" "$3"
    exit 0
fi

if [ -z "${NEXTEST_ENV:-}" ] || [ -z "${NEXTEST_RUN_ID:-}" ]; then
    echo "This script must be run as a nextest setup script" >&2
    exit 1
fi

nextest_pid="${PPID}"
redis_image="$(space_test_dependency_redis_image)"
container_id=""

fail_open() {
    echo "$1" >&2
    if [ -n "${container_id}" ]; then
        docker rm --force "${container_id}" >/dev/null 2>&1 || true
    fi
    # No SPACE_TEST_REDIS_URL is written: tests fall back to their own
    # graceful per-test container/skip behavior.
    exit 0
}

space_pull_docker_image "${redis_image}" || fail_open "failed to pull Redis image"
container_id="$(docker run --detach --rm \
    --pull=never \
    --label "space.nextest.run-id=${NEXTEST_RUN_ID}" \
    --label "space.nextest.redis-cleanup-id=${SPACE_NEXTEST_REDIS_CLEANUP_ID:-${NEXTEST_RUN_ID}}" \
    --publish 127.0.0.1::6379 \
    "${redis_image}")" || fail_open "failed to start Redis container"

for _ in $(seq 1 30); do
    if [ "$(docker exec "${container_id}" redis-cli ping 2>/dev/null)" = "PONG" ]; then
        break
    fi
    sleep 1
done
if [ "$(docker exec "${container_id}" redis-cli ping 2>/dev/null)" != "PONG" ]; then
    docker logs "${container_id}" >&2 || true
    fail_open "Redis did not become ready within 30 seconds"
fi

if ! redis_port="$(docker inspect \
    --format '{{(index (index .NetworkSettings.Ports "6379/tcp") 0).HostPort}}' \
    "${container_id}")"; then
    fail_open "could not inspect the Redis container for its host port"
fi
if [ -z "${redis_port}" ]; then
    fail_open "Redis container exposed no host port for 6379/tcp"
fi
redis_host="${TESTCONTAINERS_HOST_OVERRIDE:-127.0.0.1}"

printf 'SPACE_TEST_REDIS_URL=redis://%s:%s\n' "${redis_host}" "${redis_port}" >>"${NEXTEST_ENV}"

# Setup scripts finish before tests begin. A detached watcher provides the
# missing teardown hook without holding nextest's stdout/stderr pipes open.
nohup bash "$0" --cleanup-when-nextest-exits "${nextest_pid}" "${container_id}" \
    </dev/null >/dev/null 2>&1 &
