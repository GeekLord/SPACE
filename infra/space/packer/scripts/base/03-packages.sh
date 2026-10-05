#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
SKIP_SYSTEM_UPGRADE="${SKIP_SYSTEM_UPGRADE:-false}"
EXTERNAL_CACHE="${EXTERNAL_CACHE:-false}"
AL2023_RELEASEVER="${AL2023_RELEASEVER:-latest}"

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -qq

  if [[ "$SKIP_SYSTEM_UPGRADE" != "true" ]]; then
    sudo apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  fi

  sudo apt-get install -y \
    curl \
    htop \
    jq \
    lsof \
    openssh-server \
    psmisc

  # Images are patched during the bake. Runtime package updates are managed by
  # image replacement, not unattended package mutation on the node.
  sudo systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

  sudo systemctl enable ssh
  sudo apt-get autoremove -y
  sudo apt-get clean
elif command -v dnf >/dev/null 2>&1; then
  if [[ "$SKIP_SYSTEM_UPGRADE" != "true" ]]; then
    sudo dnf --releasever="$AL2023_RELEASEVER" upgrade -y
  fi

  # Amazon Linux 2023 does not ship btrfs-progs in the default repos.
  # Use AWS's Supplementary Packages for Amazon Linux (SPAL) when the worker
  # cache path needs mkfs.btrfs. Support tradeoff:
  # - AL2023 docs say to prefer AL2023/SPAL repos over EPEL
  # - SPAL packages are not covered by standard AWS Support Plans
  # Refs:
  # - https://docs.aws.amazon.com/linux/al2023/ug/epel.html
  # - https://docs.aws.amazon.com/linux/al2023/ug/spal.html
  # - https://docs.aws.amazon.com/linux/al2023/ug/configure-spal-repository.html
  # - https://docs.aws.amazon.com/linux/al2023/release-notes/al-2023-spal-packages.html
  DNF_PACKAGES=(
    htop \
    jq \
    lsof \
    openssh-server \
    psmisc
  )

  if [[ "$EXTERNAL_CACHE" != "true" ]]; then
    sudo dnf --releasever="$AL2023_RELEASEVER" install -y spal-release
    DNF_PACKAGES+=(btrfs-progs)
  fi

  sudo dnf --releasever="$AL2023_RELEASEVER" install -y "${DNF_PACKAGES[@]}"

  # Images are patched during the bake. Runtime package updates are managed by
  # image replacement, not unattended package mutation on the node.
  sudo systemctl disable --now dnf-automatic.timer dnf-automatic-install.timer 2>/dev/null || true
  sudo systemctl enable sshd
  sudo dnf --releasever="$AL2023_RELEASEVER" clean all
else
  echo "No supported package manager found" >&2
  exit 1
fi
