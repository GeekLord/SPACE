#!/usr/bin/env bash
# Ensure uv is available in ci/bin so Buildkite steps and bash helpers
# can run the Python CI helpers directly via `uv run --script`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCAL_BIN_DIR="${REPO_ROOT}/ci/bin"
LOCAL_UV_BIN="${LOCAL_BIN_DIR}/uv"

mkdir -p "${LOCAL_BIN_DIR}"

if [ -x "${LOCAL_UV_BIN}" ]; then
    printf '%s\n' "${LOCAL_UV_BIN}"
    exit 0
fi

if command -v uv >/dev/null 2>&1; then
    printf '%s\n' "$(command -v uv)"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required to install uv." >&2
    exit 1
fi

echo "Installing uv..." >&2
tmp_dir="$(mktemp -d)"
installer="${tmp_dir}/install-uv.sh"
trap 'rm -rf "${tmp_dir}"' EXIT

# The installer's fetch has no retry, and the installer tries each of its
# download URLs once, so one reset connection can fail the job. Each attempt
# starts over.
attempts=3
delay=5
for ((attempt = 1; ; attempt++)); do
    if curl -LsSf https://astral.sh/uv/install.sh -o "${installer}" &&
        env UV_UNMANAGED_INSTALL="${LOCAL_BIN_DIR}" sh "${installer}" >&2; then
        break
    fi
    if ((attempt >= attempts)); then
        echo "Error: could not install uv after ${attempts} attempts." >&2
        exit 1
    fi
    echo "uv install failed (attempt ${attempt}/${attempts}); retrying in ${delay}s." >&2
    sleep "${delay}"
    delay=$((delay * 2))
done

if [ -x "${LOCAL_UV_BIN}" ]; then
    printf '%s\n' "${LOCAL_UV_BIN}"
    exit 0
fi

for candidate in "${HOME}/.local/bin/uv" "${HOME}/.cargo/bin/uv"; do
    if [ -x "${candidate}" ]; then
        printf '%s\n' "${candidate}"
        exit 0
    fi
done

if command -v uv >/dev/null 2>&1; then
    printf '%s\n' "$(command -v uv)"
    exit 0
fi

echo "Error: uv is unavailable after installation." >&2
exit 1
