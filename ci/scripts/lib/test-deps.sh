#!/usr/bin/env bash

# Match pplx_space_db_test_fixtures::require_test_deps(): unset, empty, and
# literal 0 are off; every other non-empty value is on.
space_test_deps_required() {
    case "${SPACE_CI_REQUIRE_TEST_DEPS:-}" in
        "" | 0) return 1 ;;
        *) return 0 ;;
    esac
}

space_test_dependency_postgres_image() {
    printf '%s\n' "${TESTCONTAINERS_POSTGRES_IMAGE:-public.ecr.aws/docker/library/postgres:16-alpine}"
}

space_test_dependency_redis_image() {
    printf '%s\n' "${TESTCONTAINERS_REDIS_IMAGE:-public.ecr.aws/docker/library/redis:5.0}"
}

# Registry throttling is transient and a failed pull may still cache completed
# layers. Retry the explicit pull before starting a container so callers never
# trigger a second, implicit registry request through `docker run`.
space_pull_docker_image() {
    local image="$1"
    local max_attempts="${SPACE_DOCKER_PULL_ATTEMPTS:-5}"
    local delay_seconds="${SPACE_DOCKER_PULL_RETRY_DELAY_SECONDS:-2}"
    local attempt=1

    if docker image inspect "${image}" >/dev/null 2>&1; then
        return 0
    fi

    while ! docker pull "${image}"; do
        if [ "${attempt}" -ge "${max_attempts}" ]; then
            echo "Failed to pull ${image} after ${attempt} attempts." >&2
            return 1
        fi

        echo "Pull of ${image} failed (attempt ${attempt}/${max_attempts}); retrying in ${delay_seconds}s." >&2
        sleep "${delay_seconds}"
        attempt=$((attempt + 1))
        delay_seconds=$((delay_seconds * 2))
    done
}
