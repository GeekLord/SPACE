#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_script="${repo_root}/scripts/build-runtime-supervisor.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
binary="${tmp_dir}/space-runtime-supervisor-svc"
compatibility="${tmp_dir}/space-runtime-supervisor-compatibility"
calls="${tmp_dir}/build-calls"
fake_build="${tmp_dir}/fake-build"

cat >"$fake_build" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'called\n' >>"$BUILD_CALLS"
printf 'stable-runtime-supervisor-binary\n' >"$BUILD_BINARY"
EOF
chmod +x "$fake_build"

BUILD_CALLS="$calls" BUILD_BINARY="$binary" \
  bash "$build_script" "$binary" "$compatibility" "$fake_build"

if [[ "$(wc -l <"$calls" | tr -d ' ')" != "1" ]]; then
  echo "runtime-supervisor build command must run exactly once" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  expected_hash="$(sha256sum "$binary" | awk '{print $1}')"
else
  expected_hash="$(shasum -a 256 "$binary" | awk '{print $1}')"
fi
if [[ "$(tr -d '\n' <"$compatibility")" != "$expected_hash" ]]; then
  echo "runtime-supervisor compatibility is not the built binary hash" >&2
  exit 1
fi
