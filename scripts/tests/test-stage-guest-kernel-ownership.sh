#!/usr/bin/env bash
# stage-guest-kernel.sh must leave the staged kernel trees writable by their
# owner only, and must refuse a tree another account wrote into. Runs
# unprivileged, so the test user stands in for root; a different trusted uid,
# through SPACE_STAGED_KERNEL_OWNER_UID, makes the user's own tree foreign.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/k8s/stage-guest-kernel.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

vendor="$tmp/vendor"
cache="$tmp/cache"
mkdir -p "$vendor/kernels/6.1.155" "$cache/firecracker"
printf 'kernel' >"$vendor/kernels/6.1.155/vmlinux.bin"
ln -s 6.1.155 "$vendor/kernels/default"

stage() {
  SPACE_VENDOR_ROOT="$vendor" SPACE_CACHE_ROOT="$cache" \
    SPACE_STAGED_KERNEL_OWNER_UID="${1:-$(id -u)}" \
    bash "$script" >"$tmp/stage.log" 2>&1
}

stage || fail "initial staging failed: $(cat "$tmp/stage.log")"

# The boot scripts' skeleton step applies this to the whole cache.
chmod -R 2775 "$cache"
stage || fail "restaging after chmod -R 2775 failed: $(cat "$tmp/stage.log")"
for path in "$cache/firecracker/kernels" "$cache/firecracker/kernels/6.1.155"; do
  [ "$(mode_of "$path")" = 755 ] || fail "$path has mode $(mode_of "$path"), want 755"
done
kernel="$cache/firecracker/kernels/6.1.155/vmlinux.bin"
[ "$(mode_of "$kernel")" = 644 ] || fail "$kernel has mode $(mode_of "$kernel"), want 644"
[ -L "$cache/firecracker/kernels/default" ] || fail "the default alias is no longer a symlink"

inode_of() {
  stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"
}

# An image any account could write may still be open for writing, and no chmod
# revokes that: staging renames a fresh copy over it, so a descriptor opened
# while it was exposed no longer reaches the path.
chmod 0666 "$kernel"
before="$(inode_of "$kernel")"
exec 3<>"$kernel"
stage || fail "restaging an exposed kernel failed: $(cat "$tmp/stage.log")"
printf 'ROOTKIT' >&3
exec 3>&-
[ "$(cat "$kernel")" = kernel ] || fail "a descriptor retained from before staging still writes $kernel"
[ "$(inode_of "$kernel")" != "$before" ] || fail "$kernel was kept in place although it was exposed"
[ "$(mode_of "$kernel")" = 644 ] || fail "the replacement $kernel has mode $(mode_of "$kernel")"

# A release's kernel alias shares the cache kernel's inode; replacing the
# kernel links the alias to the copy too.
alias_path="$cache/firecracker/assets/v1.15.1/kernel/vmlinux.bin"
mkdir -p "$(dirname "$alias_path")"
ln "$kernel" "$alias_path"
chmod 0664 "$kernel"
before="$(inode_of "$kernel")"
stage || fail "restaging an exposed kernel with an alias failed: $(cat "$tmp/stage.log")"
[ "$(inode_of "$kernel")" != "$before" ] || fail "$kernel was kept in place although it was exposed"
[ "$(inode_of "$alias_path")" = "$(inode_of "$kernel")" ] \
  || fail "the alias $alias_path was not linked to the replacement"
rm -rf "$cache/firecracker/assets"

# A promoted legacy kernel names its own digest: an exposed one is replaced by
# a copy checked against that name.
digest="$(printf 'legacy' | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
legacy="$cache/firecracker/kernels/legacy-${digest:0:12}/vmlinux.bin"
mkdir -p "$(dirname "$legacy")"
printf 'legacy' >"$legacy"
chmod 0666 "$legacy"
before="$(inode_of "$legacy")"
stage || fail "restaging an exposed legacy kernel failed: $(cat "$tmp/stage.log")"
[ "$(inode_of "$legacy")" != "$before" ] || fail "$legacy was kept in place although it was exposed"
[ "$(cat "$legacy")" = legacy ] || fail "$legacy lost its bytes"
# One with nothing to verify it against is reported.
unverifiable="$cache/firecracker/kernels/legacy-000000000000/vmlinux.bin"
mkdir -p "$(dirname "$unverifiable")"
printf 'unknown' >"$unverifiable"
chmod 0666 "$unverifiable"
stage || fail "restaging over an unverifiable exposed kernel failed: $(cat "$tmp/stage.log")"
grep -q "WARNING: ${unverifiable} was writable by other accounts and has nothing to verify it against" "$tmp/stage.log" \
  || fail "no warning for $unverifiable: $(cat "$tmp/stage.log")"
rm -rf "$(dirname "$legacy")" "$(dirname "$unverifiable")"

# Everything the test user created is "foreign" to a different trusted uid.
if stage "$(($(id -u) + 1))"; then
  fail "staging accepted a kernel tree owned by another account"
elif ! grep -q "refusing to stage kernels into a tree another account wrote" "$tmp/stage.log"; then
  fail "foreign-owned tree was rejected for the wrong reason: $(cat "$tmp/stage.log")"
fi

# Jail setup's chown used to hand the shared kernel inode to a sandbox uid,
# which could then rewrite it. Only root can create these fixtures, so CI's
# unprivileged run skips this block; run the test as root in a container to
# cover it.
uid_of() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"
}
if [ "$(id -u)" = 0 ]; then
  # Identical to its vendor copy: verified, so replaced by a root-owned copy.
  chown 10005:10005 "$kernel"
  before="$(inode_of "$kernel")"
  stage || fail "restaging refused a kernel file a sandbox uid owns: $(cat "$tmp/stage.log")"
  [ "$(uid_of "$kernel")" = 0 ] || fail "$kernel is still owned by a sandbox uid after staging"
  [ "$(inode_of "$kernel")" != "$before" ] || fail "$kernel was re-owned in place, not replaced"

  # Rewritten by the sandbox uid: replaced with a fresh copy of the vendor kernel.
  printf 'tampered' >"$kernel"
  chown 10005:10005 "$kernel"
  stage || fail "restaging refused a rewritten kernel: $(cat "$tmp/stage.log")"
  [ "$(cat "$kernel")" = kernel ] || fail "$kernel still holds the rewritten bytes"
  [ "$(uid_of "$kernel")" = 0 ] || fail "the restaged $kernel is not root-owned"

  # A promoted legacy kernel names its own digest: replaced when it matches.
  digest="$(printf 'legacy' | sha256sum | awk '{print $1}')"
  legacy="$cache/firecracker/kernels/legacy-${digest:0:12}/vmlinux.bin"
  mkdir -p "$(dirname "$legacy")"
  printf 'legacy' >"$legacy"
  chown 10005:10005 "$legacy"
  # ...and set aside when it does not, as is anything staging cannot verify.
  forged="$cache/firecracker/kernels/legacy-000000000000/vmlinux.bin"
  mkdir -p "$(dirname "$forged")"
  printf 'forged' >"$forged"
  chown 10005:10005 "$forged"
  stray="$cache/firecracker/assets/default/kernel/vmlinux.bin"
  mkdir -p "$(dirname "$stray")"
  printf 'stray' >"$stray"
  chown 10005:10005 "$stray"
  stage || fail "staging failed over unverifiable kernels: $(cat "$tmp/stage.log")"
  [ "$(uid_of "$legacy")" = 0 ] || fail "$legacy matches its digest but was not replaced"
  grep -q "WARNING: ${legacy} was exposed (owner uid 10005); replaced" "$tmp/stage.log" \
    || fail "no warning for the replaced $legacy: $(cat "$tmp/stage.log")"
  for path in "$forged" "$stray"; do
    [ ! -e "$path" ] || fail "$path could not be verified but was left in place"
    grep -q "WARNING: ${path} is owned by uid 10005 and could not be verified" "$tmp/stage.log" \
      || fail "no warning for $path: $(cat "$tmp/stage.log")"
  done
  quarantined="$(find "$cache/firecracker/.untrusted" -path '*/kernels/legacy-000000000000/vmlinux.bin')"
  [ -n "$quarantined" ] && [ "$(cat "$quarantined")" = forged ] \
    || fail "the forged kernel was not preserved under .untrusted"
  [ "$(mode_of "$cache/firecracker/.untrusted")" = 700 ] || fail ".untrusted is not root-only"
  rm -rf "$cache/firecracker/.untrusted"

  # A planted .untrusted is refused rather than moved into.
  printf 'forged' >"$forged"
  chown 10005:10005 "$forged"
  mkdir -p "$tmp/elsewhere"
  ln -s "$tmp/elsewhere" "$cache/firecracker/.untrusted"
  if stage; then
    fail "staging quarantined through a symlinked .untrusted"
  fi
  rm -f "$cache/firecracker/.untrusted" "$forged"
fi

rm -rf "$cache/firecracker/kernels"
mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$cache/firecracker/kernels"
if stage; then
  fail "staging followed a symlinked kernel tree"
fi

if [ "$status" -eq 0 ]; then
  echo "ok: staged kernel trees stay owner-writable only and foreign-owned trees are refused"
fi
exit "$status"
