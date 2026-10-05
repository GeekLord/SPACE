#!/bin/bash
set -euo pipefail

binary="$1"
compatibility="$2"
shift 2

compatibility_tmp="$(mktemp "${compatibility}.XXXXXX")"
trap 'rm -f "$compatibility_tmp"' EXIT

"$@"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$binary" | awk '{print $1}' >"$compatibility_tmp"
else
  shasum -a 256 "$binary" | awk '{print $1}' >"$compatibility_tmp"
fi

chmod 0644 "$compatibility_tmp"
mv "$compatibility_tmp" "$compatibility"

trap - EXIT
