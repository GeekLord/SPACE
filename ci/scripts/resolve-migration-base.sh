#!/usr/bin/env bash
set -euo pipefail

candidate="${1:-}"
pull_request_head="${2:-}"

# Pull CI tests GitHub's synthetic merge, whose base can be newer than the
# event's pull_request.base.sha. Comparing that merge with the stale event SHA
# counts already-landed base migrations as PR changes. Use the checked-out
# merge's base only after proving its second parent is this PR's exact head.
# Push and merge-group callers omit the head and keep their supplied baseline.
if [[ -n "${pull_request_head}" ]]; then
    read -r base_parent head_parent extra_parents < <(git show -s --format=%P HEAD)
    if ! resolved_head="$(git rev-parse --verify "${pull_request_head}^{commit}" 2>/dev/null)" \
        || [[ -z "${base_parent}" || -z "${head_parent}" || -n "${extra_parents}" ]] \
        || [[ "${head_parent}" != "${resolved_head}" ]]; then
        echo "Pull-request migration checks require the synthetic merge of the expected PR head." >&2
        exit 1
    fi
    candidate="${base_parent}"
fi

# A repository's first retained commit can arrive with an all-zero predecessor
# or one from discarded history. Only a root commit is allowed to use itself as
# the approved baseline; later commits must retain the guards' fail-closed
# behavior when their predecessor is unavailable.
if ! git rev-parse --verify HEAD^ >/dev/null 2>&1; then
    echo "Initial root commit has no migration base; using HEAD as the baseline." >&2
    printf '%s\n' HEAD
    exit 0
fi

if [[ -z "${candidate}" ]]; then
    echo "Migration base is required for a non-root commit." >&2
    exit 1
fi

if ! resolved_candidate="$(git rev-parse --verify "${candidate}^{commit}" 2>/dev/null)"; then
    echo "Migration base ${candidate} does not resolve to a commit." >&2
    exit 1
fi

head="$(git rev-parse HEAD)"
if [[ "${resolved_candidate}" == "${head}" ]] || ! git merge-base --is-ancestor "${resolved_candidate}" HEAD; then
    echo "Migration base ${candidate} must be a proper ancestor of HEAD." >&2
    exit 1
fi

printf '%s\n' "${resolved_candidate}"
