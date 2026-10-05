#!/usr/bin/env bash
# Build the bench harness against one git rev of the gateway library.
#
# The harness links `pplx-space-net-gateway`, so "before" and "after" are two
# builds of the same harness source over two revs of that library. The crate did
# not exist at older revs, so a detached worktree is checked out and today's
# crate is copied into it. Only the library differs between the two binaries;
# the workloads, the upstream, and the sampler are identical by construction.
#
# Usage: build-rev.sh <git-rev> <out-dir>
# Writes: <out-dir>/netgtw-bench-<short-sha>-<harness-hash>, reused if present.
#
# The name carries both halves of what the binary is built from. Keying the cache
# on the gateway rev alone would hand back a stale binary after an edit to the
# harness, so a comparison would silently mix two harness versions.
set -euo pipefail

REV=${1:?usage: build-rev.sh <git-rev> <out-dir>}
OUT_DIR=${2:?usage: build-rev.sh <git-rev> <out-dir>}

REPO=$(git rev-parse --show-toplevel)
CRATE=crates/apps/net/gateway/bench
MEMBER_ANCHOR='"crates/apps/net/gateway/svc",'

die() { echo "ERROR: $*" >&2; exit 1; }

SHA=$(git -C "$REPO" rev-parse "$REV") || die "unknown rev: $REV"
SHORT=$(git -C "$REPO" rev-parse --short "$SHA")

# Working-tree contents, not a git tree hash: uncommitted harness edits must
# invalidate the cache too.
HARNESS_HASH=$(cd "$REPO" && find "$CRATE" -type f \( -name '*.rs' -o -name 'Cargo.toml' \) \
  -print0 | sort -z | xargs -0 cat | sha256sum | cut -c1-8)

mkdir -p "$OUT_DIR"
BINARY="$OUT_DIR/netgtw-bench-$SHORT-$HARNESS_HASH"

# Stdout carries the path and nothing else; callers capture it.
if [[ -x "$BINARY" ]]; then
  echo "reusing the cached build of $SHORT (harness $HARNESS_HASH)" >&2
  echo "$BINARY"
  exit 0
fi

# Dependency artifacts are shared across revs; only the workspace crates rebuild.
export CARGO_TARGET_DIR="$OUT_DIR/target"

WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/netgtw-bench-$SHORT.XXXXXX")
cleanup() { git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"; }
trap cleanup EXIT

git -C "$REPO" worktree add --detach --quiet "$WORKTREE" "$SHA"

if [[ ! -d "$WORKTREE/$CRATE" ]]; then
  cp -R "$REPO/$CRATE" "$WORKTREE/$CRATE"
  grep -q "$MEMBER_ANCHOR" "$WORKTREE/Cargo.toml" ||
    die "cannot add the bench crate to $SHORT: workspace members do not list $MEMBER_ANCHOR"
  sed -i "s|$MEMBER_ANCHOR|\"$CRATE\",\n    $MEMBER_ANCHOR|" "$WORKTREE/Cargo.toml"
fi

echo "building $SHORT ($(git -C "$REPO" log -1 --format=%s "$SHA" | cut -c1-60))" >&2
cargo build --manifest-path "$WORKTREE/Cargo.toml" --release -p pplx-space-netgtw-bench >&2
cp "$CARGO_TARGET_DIR/release/netgtw-bench" "$BINARY"
echo "$BINARY"
