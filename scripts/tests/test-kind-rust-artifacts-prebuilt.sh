#!/usr/bin/env bash
# Exercise the CI handoff at the Docker boundary; never touch the host daemon.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "image inspect -f {{.Id}} space-rust-build-kind:local" ]] || {
  echo "unexpected Docker operation: $*" >&2
  exit 99
}
[[ -n "$STUB_IMAGE_ID" ]] || exit 1
echo "$STUB_IMAGE_ID"
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"
export SPACE_TILT_STATE_DIR="$work/state"
export SPACE_KIND_RUST_ARTIFACTS=prebuilt
export SPACE_KIND_PREBUILT_RUST_SHA="$(git -C "$repo_root" rev-parse HEAD)"
export SPACE_KIND_PREBUILT_RUST_IMAGE_ID=sha256:fixture-image
export STUB_IMAGE_ID="$SPACE_KIND_PREBUILT_RUST_IMAGE_ID"
script="$repo_root/infra/space/kind/scripts/build-rust-artifacts.sh"

# Tilt's repeated invocations must all reuse the image without building it.
bash "$script"
bash "$script"

reject() {
  local expected="$1"; shift
  if "$@" >"$work/output" 2>&1; then
    echo "FAIL: accepted invalid prebuilt artifact" >&2
    exit 1
  fi
  grep -q "$expected" "$work/output" || { cat "$work/output" >&2; exit 1; }
}
reject 'requires an image ID and source SHA' \
  env -u SPACE_KIND_PREBUILT_RUST_IMAGE_ID bash "$script"
reject 'source SHA does not match' \
  env SPACE_KIND_PREBUILT_RUST_SHA=another-commit bash "$script"
reject 'missing or does not match' \
  env STUB_IMAGE_ID=sha256:another-image bash "$script"
reject 'missing or does not match' \
  env STUB_IMAGE_ID= bash "$script"
echo 'PASS: prebuilt Rust artifact reuse and fail-closed identity checks'
