#!/usr/bin/env bash
# Grow the root partition/filesystem to fill the Packer root EBS volume.
set -euo pipefail

MIN_ROOT_GB="${MIN_ROOT_GB:-}"
AL2023_RELEASEVER="${AL2023_RELEASEVER:-latest}"

root_source="$(findmnt -n -o SOURCE /)"
resolved_root_source="$(readlink -f "$root_source" 2>/dev/null || true)"
if [[ -n "$resolved_root_source" ]]; then
  root_source="$resolved_root_source"
fi
root_fstype="$(findmnt -n -o FSTYPE /)"

if [[ "$root_source" != /dev/* ]]; then
  echo "Root source is not a block device: $root_source" >&2
  exit 1
fi

root_block="$(basename "$root_source")"
root_sys="/sys/class/block/$root_block"

if [[ ! -e "$root_sys" ]]; then
  echo "Could not resolve sysfs block device for root source: $root_source" >&2
  lsblk -f >&2
  exit 1
fi

if [[ -f "$root_sys/partition" ]]; then
  part_num="$(<"$root_sys/partition")"
  root_pkname="$(basename "$(dirname "$(readlink -f "$root_sys")")")"
else
  part_num=""
  root_pkname="$root_block"
fi

if [[ -z "$root_pkname" ]]; then
  echo "Could not resolve parent disk/partition for root source: $root_source" >&2
  lsblk -f >&2
  exit 1
fi

root_disk="/dev/$root_pkname"

echo "Root source: $root_source"
echo "Root disk:   $root_disk"
echo "Root fs:     $root_fstype"
if [[ -n "$part_num" ]]; then
  echo "Root part:   $part_num"
else
  echo "Root source is not partitioned; skipping partition growth"
fi

if ! command -v growpart >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf --releasever="$AL2023_RELEASEVER" install -y cloud-utils-growpart
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y cloud-guest-utils
  else
    echo "No supported package manager found for growpart" >&2
    exit 1
  fi
fi

if [[ -n "$part_num" ]]; then
  sudo growpart "$root_disk" "$part_num" || true
fi

case "$root_fstype" in
  xfs)
    sudo xfs_growfs /
    ;;
  ext2 | ext3 | ext4)
    sudo resize2fs "$root_source"
    ;;
  *)
    echo "Unsupported root filesystem for grow: $root_fstype" >&2
    exit 1
    ;;
esac

df -h /

if [[ -n "$MIN_ROOT_GB" ]]; then
  root_size_gb="$(df -BG --output=size / | tail -n1 | tr -dc '0-9')"
  if (( root_size_gb < MIN_ROOT_GB )); then
    echo "Root filesystem is ${root_size_gb}G, expected at least ${MIN_ROOT_GB}G" >&2
    lsblk -f >&2
    exit 1
  fi
fi
