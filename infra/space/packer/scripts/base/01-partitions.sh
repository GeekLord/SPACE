#!/usr/bin/env bash
# Set up /space, /space/cache, and swap.
#
# Two modes:
#   SIMPLE_LAYOUT=true  — no repartitioning; /space is a directory on root, swap is a file.
#                         Used on AWS where root partition fills the disk.
#   SIMPLE_LAYOUT=false — repartition the disk: root + /space (ext4) + swap + /space/cache (btrfs).
#                         Used on UTM/QEMU where root starts small and can be resized.
#
# Required env vars (when SIMPLE_LAYOUT=false):
#   PART_ROOT_END   — end of root partition in GiB (e.g. 20)
#   PART_SPACE_END  — end of /space partition in GiB (e.g. 30)
#   PART_SWAP_END   — end of swap partition in GiB (e.g. 32)
#
# Optional:
#   SIMPLE_LAYOUT   — if "true", skip repartitioning (default: false)
#   EXTERNAL_CACHE  — if "true", skip btrfs /space/cache partition (api, ui nodes)
#   SWAP_GB         — swap file size in GB for simple layout (default: 2)
#   DISK_DEVICE     — override disk device (default: auto-detect)
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    if printf '%s\n' "$@" | grep -qx 'btrfs-progs'; then
      # Amazon Linux 2023 requires SPAL for btrfs-progs.
      sudo dnf --releasever="${AL2023_RELEASEVER:-latest}" install -y spal-release
    fi
    sudo dnf --releasever="${AL2023_RELEASEVER:-latest}" install -y "$@"
  else
    echo "No supported package manager found" >&2
    exit 1
  fi
}

SIMPLE_LAYOUT="${SIMPLE_LAYOUT:-false}"
EXTERNAL_CACHE="${EXTERNAL_CACHE:-false}"
SWAP_GB="${SWAP_GB:-2}"

# ── Simple layout (AWS) ─────────────────────────────────────────────────────
# No repartitioning. /space is a directory on the root filesystem.
# Swap is a file. /space/cache is a btrfs loopback or directory.

if [[ "$SIMPLE_LAYOUT" == "true" ]]; then
  echo "=== Simple layout (no repartitioning) ==="

  # Install btrfs if we need a cache partition
  if [[ "$EXTERNAL_CACHE" != "true" ]]; then
    install_packages btrfs-progs
  fi

  # /space as directory on root
  sudo mkdir -p /space

  # Swap file
  SWAP_FILE="/swapfile"
  if [[ ! -f "$SWAP_FILE" ]]; then
    sudo fallocate -l "${SWAP_GB}G" "$SWAP_FILE"
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE"
    echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab
    sudo swapon "$SWAP_FILE"
  fi

  # /space/cache — btrfs on a loopback image for CoW support
  if [[ "$EXTERNAL_CACHE" != "true" ]]; then
    CACHE_IMG="/space/cache.img"
    # Use ~80% of remaining free space for cache
    AVAIL_KB=$(df --output=avail / | tail -1 | tr -d ' ')
    CACHE_KB=$(( AVAIL_KB * 80 / 100 ))
    echo "Allocating ~$(( CACHE_KB / 1024 / 1024 ))GB for /space/cache loopback"
    sudo truncate -s "${CACHE_KB}K" "$CACHE_IMG"
    sudo mkfs.btrfs -f "$CACHE_IMG"
    sudo mkdir -p /space/cache
    echo "${CACHE_IMG} /space/cache btrfs loop,defaults,noatime 0 0" | sudo tee -a /etc/fstab
    sudo mount /space/cache
  fi

  echo "=== Layout complete ==="
  df -Th / /space
  if [[ "$EXTERNAL_CACHE" != "true" ]]; then
    df -Th /space/cache
  fi
  free -h
  exit 0
fi

# ── Partitioned layout (UTM/QEMU) ───────────────────────────────────────────
# Repartition the disk: shrink/grow root, add /space, swap, and /space/cache.

: "${PART_ROOT_END:?must be set}"
: "${PART_SPACE_END:?must be set}"
: "${PART_SWAP_END:?must be set}"

# Auto-detect disk device: NVMe (AWS), Xen (legacy AWS), virtio (UTM/QEMU)
if [[ -n "${DISK_DEVICE:-}" ]]; then
  DISK="$DISK_DEVICE"
elif [[ -b /dev/nvme0n1 ]]; then
  DISK="/dev/nvme0n1"
elif [[ -b /dev/xvda ]]; then
  DISK="/dev/xvda"
else
  DISK="/dev/vda"
fi

# NVMe partitions use 'p' separator: /dev/nvme0n1p1 vs /dev/vda1
if [[ "$DISK" == *nvme* ]]; then
  ROOT_PART="${DISK}p1"
else
  ROOT_PART="${DISK}1"
fi

echo "Disk: $DISK, root partition: $ROOT_PART"

# Ensure partition tools are available
if [[ "$EXTERNAL_CACHE" != "true" ]]; then
  install_packages btrfs-progs gdisk
else
  install_packages gdisk
fi

echo "=== Before ==="
lsblk -f
sudo parted "$DISK" print || true

# Fix GPT backup header to match the resized disk
sudo sgdisk -e "$DISK"

# Grow root partition to ${PART_ROOT_END}GiB
echo Yes | sudo parted ---pretend-input-tty "$DISK" resizepart 1 "${PART_ROOT_END}GiB" 2>&1 | grep -v "^Warning:"
sudo resize2fs "$ROOT_PART"

# Create /space partition (ext4)
sudo parted -s "$DISK" mkpart space ext4 "${PART_ROOT_END}GiB" "${PART_SPACE_END}GiB"

# Create swap partition
if [[ "$EXTERNAL_CACHE" == "true" ]]; then
  sudo parted -s "$DISK" mkpart swap linux-swap "${PART_SPACE_END}GiB" 100%
else
  sudo parted -s "$DISK" mkpart swap linux-swap "${PART_SPACE_END}GiB" "${PART_SWAP_END}GiB"
  sudo parted -s "$DISK" mkpart cache btrfs "${PART_SWAP_END}GiB" 100%
fi

sudo partprobe "$DISK"
sleep 2

# Find new partitions by label
SPACE_DEV=$(lsblk -rpno NAME,PARTLABEL "$DISK" | awk '/space/{print $1}')
SWAP_DEV=$(lsblk -rpno NAME,PARTLABEL "$DISK" | awk '/swap/{print $1}')
echo "Partitions: space=$SPACE_DEV swap=$SWAP_DEV"

sudo mkfs.ext4 -L space "$SPACE_DEV"
sudo mkswap -L swap "$SWAP_DEV"

# Mount /space
sudo mkdir -p /space
SPACE_UUID=$(sudo blkid -s UUID -o value "$SPACE_DEV")
echo "UUID=$SPACE_UUID /space ext4 defaults,noatime 0 0" | sudo tee -a /etc/fstab
sudo mount /space

# Cache partition (btrfs)
if [[ "$EXTERNAL_CACHE" != "true" ]]; then
  CACHE_DEV=$(lsblk -rpno NAME,PARTLABEL "$DISK" | awk '/cache/{print $1}')
  echo "Cache partition: $CACHE_DEV"
  sudo mkfs.btrfs -f -L cache "$CACHE_DEV"
  sudo mkdir -p /space/cache
  CACHE_UUID=$(sudo blkid -s UUID -o value "$CACHE_DEV")
  echo "UUID=$CACHE_UUID /space/cache btrfs defaults,noatime 0 0" | sudo tee -a /etc/fstab
  sudo mount /space/cache
fi

# Enable swap
SWAP_UUID=$(sudo blkid -s UUID -o value "$SWAP_DEV")
echo "UUID=$SWAP_UUID none swap sw 0 0" | sudo tee -a /etc/fstab
sudo swapon "$SWAP_DEV"

echo "=== After ==="
lsblk -f
df -Th / /space
if [[ "$EXTERNAL_CACHE" != "true" ]]; then
  df -Th /space/cache
fi
free -h
