#!/usr/bin/env bash
# Start one migrated Postgres template for all fixture-backed tests in a
# nextest run. Each test still clones its own isolated database from it.
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
postgres_image="$(space_test_dependency_postgres_image)"
container_id=""

cleanup_on_error() {
    if [ -n "${container_id}" ]; then
        docker rm --force "${container_id}" >/dev/null 2>&1 || true
    fi
}
trap cleanup_on_error EXIT

# The server lives for one nextest run and is deleted with its data, so it
# gives up crash durability: every DROP DATABASE forces a checkpoint, and with
# fsync on each one flushed and fsynced the dirty pages of every concurrently
# running test's database. The testcontainers module this replaces already
# starts Postgres with fsync=off; synchronous_commit and full_page_writes only
# matter for surviving a crash as well. For the same reason the data directory
# is a tmpfs: each test's database is a copy of the template's files, created
# and deleted a file at a time, and that is cheaper in memory than on the
# runner's disk. CI runs 30 tests at once. Most hold two or three connections,
# but a few hold eight or ten, so the default limit of 100 is raised.
space_pull_docker_image "${postgres_image}"
container_id="$(docker run --detach --rm \
    --pull=never \
    --label "space.nextest.run-id=${NEXTEST_RUN_ID}" \
    --label "space.nextest.cleanup-id=${SPACE_NEXTEST_POSTGRES_CLEANUP_ID:-${NEXTEST_RUN_ID}}" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --env PGDATA=/var/lib/postgresql/data \
    --tmpfs /var/lib/postgresql/data \
    --publish 127.0.0.1::5432 \
    "${postgres_image}" \
    -c fsync=off \
    -c synchronous_commit=off \
    -c full_page_writes=off \
    -c max_connections=200)"

# The image's entrypoint first runs initdb under a temporary server that
# listens only on the Unix socket, then stops it and starts the real one. A
# socket probe can therefore succeed against the temporary server and the
# next one fail while it shuts down. Probe over TCP, which only the real
# server answers, and poll finely: the server is usually up in about a second.
ready_deadline=$((SECONDS + 30))
until docker exec "${container_id}" pg_isready --host 127.0.0.1 --username postgres >/dev/null 2>&1; do
    if [ "${SECONDS}" -ge "${ready_deadline}" ]; then
        echo "Postgres did not become ready within 30 seconds" >&2
        docker logs "${container_id}" >&2 || true
        exit 1
    fi
    sleep 0.1
done

postgres_port="$(docker inspect \
    --format '{{(index (index .NetworkSettings.Ports "5432/tcp") 0).HostPort}}' \
    "${container_id}")"
postgres_host="${TESTCONTAINERS_HOST_OVERRIDE:-127.0.0.1}"
admin_database_url="postgres://postgres@${postgres_host}:${postgres_port}/postgres?sslmode=disable"

# A published port is served by docker-proxy, a userspace process that copies
# every byte of every test's connection. Where this host can route to the
# container's bridge address, as on Linux and in CI, connect there instead.
# Anywhere it cannot, such as Docker Desktop, the probe fails within a second
# and the published port stays. An explicit host override always wins.
if [ -z "${TESTCONTAINERS_HOST_OVERRIDE:-}" ] && command -v timeout >/dev/null 2>&1; then
    container_ip="$(docker inspect \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
        "${container_id}")"
    if [ -n "${container_ip}" ] &&
        timeout 1 bash -c "exec 3<>/dev/tcp/${container_ip}/5432" 2>/dev/null; then
        admin_database_url="postgres://postgres@${container_ip}:5432/postgres?sslmode=disable"
    fi
fi

setup_binary="${CARGO_TARGET_DIR:-target}/debug/space-nextest-postgres-setup"
if [ ! -x "${setup_binary}" ]; then
    echo "Nextest did not build ${setup_binary}" >&2
    exit 1
fi
"${setup_binary}" "${admin_database_url}"

printf 'SPACE_TEST_POSTGRES_ADMIN_URL=%s\n' "${admin_database_url}" >>"${NEXTEST_ENV}"

# Setup scripts finish before tests begin. A detached watcher provides the
# missing teardown hook without holding nextest's stdout/stderr pipes open.
nohup bash "$0" --cleanup-when-nextest-exits "${nextest_pid}" "${container_id}" \
    </dev/null >/dev/null 2>&1 &

trap - EXIT
