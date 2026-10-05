#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = run ]; then
    echo "simulated unavailable Docker daemon" >&2
    exit 1
fi
echo "unexpected docker command: $*" >&2
exit 99
SH
chmod +x "${fake_bin}/docker"

run_setup() {
    local env_file="$1"
    PATH="${fake_bin}:${PATH}" \
        NEXTEST_ENV="${env_file}" \
        NEXTEST_RUN_ID="review-test" \
        bash ci/scripts/setup-nextest-postgres.sh
}

env_file="${tmp_dir}/nextest.env"
: >"${env_file}"
if run_setup "${env_file}"; then
    echo "FAIL: setup succeeded with unavailable Docker" >&2
    exit 1
fi
if [ -s "${env_file}" ]; then
    echo "FAIL: failed setup wrote a partial nextest environment" >&2
    exit 1
fi

echo "nextest Postgres setup failure test passed"
