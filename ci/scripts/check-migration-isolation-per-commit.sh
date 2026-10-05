#!/usr/bin/env bash
# Run the Postgres migration isolation guard once per first-parent commit.
#
# One push to main can land a whole merge-queue batch, so the push's
# before..after range spans several PRs. The guard judges a single change;
# diffing the batch as a unit pairs one PR's migrations with another PR's
# runtime code. On a first-parent walk each commit is one landed change (a
# squash commit, or a merge commit whose first-parent diff is the whole merged
# branch), so each is checked against its first parent. The guard's exemptions
# read working-tree files, so each commit runs that commit's copy of the guard
# in its own detached worktree.
set -euo pipefail

if (($# != 1)); then
    echo "usage: $0 <base-commit>" >&2
    exit 2
fi

cd "$(git rev-parse --show-toplevel)"

base="$(git rev-parse --verify "$1^{commit}")"
mapfile -t commits < <(git rev-list --first-parent --reverse "${base}..HEAD")

if ((${#commits[@]} == 0)); then
    echo "No commits after ${base}; migration isolation check passed."
    exit 0
fi

worktree_root="$(mktemp -d)"
cleanup() {
    rm -rf -- "${worktree_root}"
    git worktree prune
}
trap cleanup EXIT

failed=()
for commit in "${commits[@]}"; do
    if ! parent="$(git rev-parse --verify --quiet "${commit}^1")"; then
        echo "ERROR: ${commit} has no parent to compare against." >&2
        exit 1
    fi

    echo "Checking $(git log -1 --format='%h %s' "${commit}")"
    worktree="${worktree_root}/${commit}"
    git worktree add --quiet --detach "${worktree}" "${commit}"
    if ! MIGRATION_ISOLATION_BASE_REF="${parent}" \
        bash "${worktree}/scripts/check-postgres-migrations-isolated.sh"; then
        failed+=("${commit}")
    fi
    git worktree remove --force "${worktree}"
done

if ((${#failed[@]} > 0)); then
    echo "ERROR: migration isolation failed for ${#failed[@]} of ${#commits[@]} commit(s):" >&2
    for commit in "${failed[@]}"; do
        echo "  $(git log -1 --format='%h %s' "${commit}")" >&2
    done
    exit 1
fi

echo "Migration isolation passed for each of ${#commits[@]} commit(s) after ${base}."
