#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
builder="${1:-${repo_root}/templates/firecracker/seed/rootfs-builder.sh}"
work="$(mktemp -d)"
trap 'gpgconf --homedir "$work/keys" --kill all; rm -rf "$work"' EXIT

mkdir -m 700 "$work/keys"
gpg --homedir "$work/keys" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Seed verification fixture' ed25519 sign 0 >/dev/null 2>&1
signer="$(gpg --homedir "$work/keys" --with-colons --list-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
gpg --homedir "$work/keys" --export > "$work/keyring.gpg"

mkdir "$work/source"
printf 'verified payload\n' > "$work/source/payload"
mksquashfs "$work/source" "$work/image.squashfs" -noappend -processors 1 >/dev/null
checksum="$(sha256sum "$work/image.squashfs" | cut -d ' ' -f 1)"
printf 'older release\n' > "$work/source/payload"
mksquashfs "$work/source" "$work/stale.squashfs" -noappend -processors 1 >/dev/null
printf 'verified payload\n' > "$work/source/payload"

for scenario in download cache stale-cache signature manifest signer checksum missing duplicate corrupt-download corrupt-cache corrupt-cache-and-download; do
  case_dir="$work/$scenario"
  mkdir -p "$case_dir/upstream" "$case_dir/cache"
  cp "$work/image.squashfs" "$case_dir/upstream/image.squashfs"
  printf '%s  %s\n' "$checksum" image.squashfs > "$case_dir/upstream/SHA256SUMS"
  expected_signer="$signer"
  expected_status=1
  case "$scenario" in
    download) expected_status=0 ;;
    cache)
      expected_status=0
      cp "$work/image.squashfs" "$case_dir/cache/image.squashfs"
      rm "$case_dir/upstream/image.squashfs"
      ;;
    stale-cache)
      expected_status=0
      cp "$work/stale.squashfs" "$case_dir/cache/image.squashfs"
      ;;
    signer) expected_signer=0000000000000000000000000000000000000000 ;;
    checksum) printf '%064d  image.squashfs\n' 0 > "$case_dir/upstream/SHA256SUMS" ;;
    missing) printf '%s  other.squashfs\n' "$checksum" > "$case_dir/upstream/SHA256SUMS" ;;
    duplicate) printf '%s  image.squashfs\n' "$checksum" >> "$case_dir/upstream/SHA256SUMS" ;;
    corrupt-download) printf tampered >> "$case_dir/upstream/image.squashfs" ;;
    corrupt-cache|corrupt-cache-and-download)
      cp "$work/image.squashfs" "$case_dir/cache/image.squashfs"
      printf tampered >> "$case_dir/cache/image.squashfs"
      if [[ "$scenario" == corrupt-cache ]]; then
        expected_status=0
      else
        cp "$case_dir/cache/image.squashfs" "$case_dir/original-cache"
        printf upstream-tampered >> "$case_dir/upstream/image.squashfs"
      fi
      ;;
  esac
  gpg --homedir "$work/keys" --batch --detach-sign "$case_dir/upstream/SHA256SUMS"
  mv "$case_dir/upstream/SHA256SUMS.sig" "$case_dir/upstream/SHA256SUMS.gpg"
  case "$scenario" in
    signature) printf invalid > "$case_dir/upstream/SHA256SUMS.gpg" ;;
    manifest) printf '\nchanged after signing\n' >> "$case_dir/upstream/SHA256SUMS" ;;
  esac

  # A child shell preserves errexit inside the production function.
  status=0
  bash -c 'source "$1"; shift; extract_verified_squashfs "$@"' bash \
    "$builder" "file://$case_dir/upstream" image.squashfs "$case_dir/cache" \
    "$case_dir/extracted" "$work/keyring.gpg" "$expected_signer" > "$case_dir/log" 2>&1 || status=$?

  if [[ "$expected_status" == 0 ]]; then
    if [[ "$status" != 0 ]]; then
      cat "$case_dir/log" >&2
      exit 1
    fi
    cmp "$work/source/payload" "$case_dir/extracted/squashfs-root/payload"
    cmp "$work/image.squashfs" "$case_dir/cache/image.squashfs"
  else
    if [[ "$status" == 0 || -e "$case_dir/extracted" ]]; then
      echo "$scenario: unverified image reached extraction" >&2
      cat "$case_dir/log" >&2
      exit 1
    fi
    if [[ "$scenario" != corrupt-cache-and-download && -e "$case_dir/cache/image.squashfs" ]]; then
      echo "$scenario: unverified image entered the cache" >&2
      exit 1
    fi
    if [[ "$scenario" == corrupt-cache-and-download ]]; then
      cmp "$case_dir/original-cache" "$case_dir/cache/image.squashfs"
    fi
  fi
  echo "PASS: $scenario"
done
