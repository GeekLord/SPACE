#!/usr/bin/env bash
# Exercise pull-base-images.sh at the Docker boundary; never touch the host daemon.
#   1. Only registry bases are pulled: FROM lines directly or through an ARG
#      default, and `# syntax=`; stages, scratch, `:local` images, and partly
#      expanded references are left to the build.
#   2. An image already present is not pulled.
#   3. A failed pull is retried whatever its message, and one that keeps
#      failing ends the script nonzero after its attempts, with the error.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/infra/space/kind/scripts/pull-base-images.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
    "image inspect")
        grep -qxF "$3" "$STUB_PRESENT" 2>/dev/null ;;
    "pull --quiet")
        echo "$3" >>"$STUB_PULLS"
        failures="$(grep -cxF "$3" "$STUB_PULLS")"
        if (( failures <= ${STUB_PULL_FAILURES:-0} )); then
            echo "Error response from daemon: unexpected status 503 Service Unavailable" >&2
            exit 1
        fi ;;
    *) echo "unexpected Docker operation: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"
export STUB_PRESENT="$work/present" STUB_PULLS="$work/pulls"
export SPACE_KIND_PULL_BACKOFF_SECONDS=0

status=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@" >&2
    status=1
}

cat >"$work/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE="public.ecr.aws/example/base:1"
ARG RUST_IMAGE=space-rust-build-example:local
ARG TAG=2
FROM ${RUST_IMAGE} AS rust-build
FROM --platform=$BUILDPLATFORM public.ecr.aws/example/tool:3 AS tool
FROM tool AS tool-again
FROM public.ecr.aws/example/partial:${TAG}
FROM scratch AS empty
FROM $BASE_IMAGE
EOF
expected=$'docker/dockerfile:1.7\npublic.ecr.aws/example/base:1\npublic.ecr.aws/example/tool:3'

# Case 1: exactly the registry bases, once each.
: >"$STUB_PULLS"
bash "$script" "$work/Dockerfile" >"$work/output" 2>&1 \
    || fail "pulling reachable bases must succeed" "$(cat "$work/output")"
[[ "$(sort "$STUB_PULLS")" == "$expected" ]] \
    || fail "only the registry bases must be pulled" "$(cat "$STUB_PULLS")"

# Case 2: a base already in the local store is not pulled again.
: >"$STUB_PULLS"
printf '%s\n' public.ecr.aws/example/base:1 docker/dockerfile:1.7 >"$STUB_PRESENT"
bash "$script" "$work/Dockerfile" >"$work/output" 2>&1 \
    || fail "a partly present set must still succeed" "$(cat "$work/output")"
[[ "$(cat "$STUB_PULLS")" == public.ecr.aws/example/tool:3 ]] \
    || fail "present images must not be pulled" "$(cat "$STUB_PULLS")"
rm -f "$STUB_PRESENT"

# Case 3a: failures that clear within the attempts are retried to success.
: >"$STUB_PULLS"
printf 'FROM public.ecr.aws/example/flaky:1\n' >"$work/Dockerfile.flaky"
STUB_PULL_FAILURES=2 SPACE_KIND_PULL_ATTEMPTS=3 \
    bash "$script" "$work/Dockerfile.flaky" >"$work/output" 2>&1 \
    || fail "a pull that succeeds on its last attempt must succeed" "$(cat "$work/output")"
[[ "$(grep -c . "$STUB_PULLS")" == 3 ]] \
    || fail "two failures must be followed by exactly one more attempt" "$(cat "$STUB_PULLS")"
grep -q "attempt 2/3" "$work/output" \
    || fail "each retry must be reported" "$(cat "$work/output")"

# Case 3b: a pull that keeps failing ends the script after its attempts.
: >"$STUB_PULLS"
if STUB_PULL_FAILURES=99 SPACE_KIND_PULL_ATTEMPTS=3 \
        bash "$script" "$work/Dockerfile.flaky" >"$work/output" 2>&1; then
    fail "a pull that never succeeds must fail the script" "$(cat "$work/output")"
fi
[[ "$(grep -c . "$STUB_PULLS")" == 3 ]] \
    || fail "an exhausted pull must stop at its attempt budget" "$(cat "$STUB_PULLS")"
grep -q "could not pull public.ecr.aws/example/flaky:1 after 3 attempts" "$work/output" \
    && grep -q "503 Service Unavailable" "$work/output" \
    || fail "an exhausted pull must report the image and the last error" "$(cat "$work/output")"

[ "$status" -eq 0 ] && echo 'PASS: base-image pulls cover registry bases only, skip present images, and retry to a bound'
exit "$status"
