#!/usr/bin/env bash
# DEV-ONLY, DO NOT COMMIT THE RESULT.
#
# The local node-stack image is built k8s-free on purpose (the `build-node-stack`
# lane omits the `k8s` Cargo feature, so the kube client isn't pulled into the
# dev image). To exercise the TokenReview path locally, node-api must be compiled
# WITH the feature. This helper adds `-F pplx-space-{node-api,internal-api}-svc/k8s`
# to that build lane so a subsequent `tilt up` produces a k8s-capable node-stack.
#
# This edits a tracked file (docker/Dockerfile.rust-build-common). Revert it
# (git checkout) before committing anything — we do NOT ship k8s in the local
# node-stack image.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCKERFILE="${REPO_ROOT}/docker/Dockerfile.rust-build-common"

[[ -f "$DOCKERFILE" ]] || die "not found: $DOCKERFILE"

if grep -qE 'build-node-stack.*\n.*pplx-space-node-api-svc/k8s' "$DOCKERFILE" 2>/dev/null \
   || awk '/AS build-node-stack/{f=1} f&&/pplx-space-node-api-svc\/k8s/{print "yes"; exit}' "$DOCKERFILE" | grep -q yes; then
  log "node-stack lane already enables the k8s feature — nothing to do."
  exit 0
fi

log "patching the build-node-stack cargo build to add the k8s feature"
# Insert the two -F lines right after the build-node-stack stage's `cargo build`.
perl -0pi -e 's{(FROM build-context AS build-node-stack\n\nRUN cargo build --locked --release \\\n)}{$1      -F pplx-space-node-api-svc/k8s \\\n      -F pplx-space-internal-api-svc/k8s \\\n}' "$DOCKERFILE"

if awk '/AS build-node-stack/{f=1} f&&/pplx-space-node-api-svc\/k8s/{print "yes"; exit}' "$DOCKERFILE" | grep -q yes; then
  log "done. Now rebuild: SPACE_KIND_CLUSTER=space-local tilt up   (then ./01-apply-auth.sh)"
  warn "remember to 'git checkout ${DOCKERFILE#"$REPO_ROOT"/}' before committing."
else
  die "patch did not apply — the build-node-stack lane may have changed; add the -F lines by hand."
fi
