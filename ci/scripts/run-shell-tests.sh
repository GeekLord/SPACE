#!/usr/bin/env bash
# Run every self-contained shell regression test discovered in the repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"

test_dirs=(ci/scripts scripts/tests)
if [ -d .buildkite/scripts ]; then
    test_dirs+=(.buildkite/scripts)
fi

mapfile -t tests < <(
    find "${test_dirs[@]}" \
        -maxdepth 1 \
        -type f \
        -name 'test-*.sh' \
        -print \
        | sed 's#^\./##' \
        | sort
)

if [ "${#tests[@]}" -eq 0 ]; then
    echo "No shell regression tests discovered." >&2
    exit 1
fi

printf '%s\n' "--- :shell: Running ${#tests[@]} discovered shell regression tests"
for test_file in "${tests[@]}"; do
    echo "+++ ${test_file}"
    bash "${test_file}"
done
