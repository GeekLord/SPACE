#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
resolver="${repo_root}/ci/scripts/resolve-migration-base.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fixture="${tmp_dir}/repo"
git init -q -b main "${fixture}"
git -C "${fixture}" config user.name test
git -C "${fixture}" config user.email test@example.com
git -C "${fixture}" commit -q --allow-empty -m base
root="$(git -C "${fixture}" rev-parse HEAD)"

git -C "${fixture}" checkout -q --orphan unrelated
git -C "${fixture}" commit -q --allow-empty -m unrelated
unrelated_base="$(git -C "${fixture}" rev-parse HEAD)"
git -C "${fixture}" checkout -q main

assert_base() {
    local name="$1"
    local candidate="$2"
    local expected="$3"
    local actual

    actual="$(cd "${fixture}" && bash "${resolver}" "${candidate}" 2>"${tmp_dir}/${name}.stderr")"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "${name}: expected ${expected}, got ${actual}" >&2
        cat "${tmp_dir}/${name}.stderr" >&2
        exit 1
    fi
}

assert_rejected() {
    local name="$1"
    local candidate="$2"

    if (cd "${fixture}" && bash "${resolver}" "${candidate}" >"${tmp_dir}/${name}.stdout" 2>"${tmp_dir}/${name}.stderr"); then
        echo "${name}: expected migration base resolution to fail" >&2
        cat "${tmp_dir}/${name}.stdout" >&2
        cat "${tmp_dir}/${name}.stderr" >&2
        exit 1
    fi
}

assert_base root-empty "" HEAD
assert_base root-all-zero 0000000000000000000000000000000000000000 HEAD
assert_base root-missing 1111111111111111111111111111111111111111 HEAD
assert_base root-unrelated "${unrelated_base}" HEAD

git -C "${fixture}" commit -q --allow-empty -m head
head="$(git -C "${fixture}" rev-parse HEAD)"

assert_base normal "${root}" "${root}"
assert_rejected non-root-empty ""
assert_rejected non-root-all-zero 0000000000000000000000000000000000000000
assert_rejected non-root-missing 1111111111111111111111111111111111111111
assert_rejected non-root-unrelated "${unrelated_base}"
assert_rejected non-root-head "${head}"

if [[ "$(git -C "${fixture}" rev-parse HEAD)" != "${head}" ]]; then
    echo "migration base resolution changed the checked-out commit" >&2
    exit 1
fi

echo "Migration base resolution scenarios passed."
