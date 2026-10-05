#!/usr/bin/env bash
# Install an SSH public key for root, deploy, and dev users.
# The key is passed via the SSH_PUBLIC_KEY env var (set by packer HCL).
# If empty, this script is a no-op.
#
# Note: this script assumes root. On AWS, packer's execute_command wraps with sudo.
set -euo pipefail

if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
  echo "No SSH public key provided, skipping."
  exit 0
fi

for user_home in /root /home/deploy /home/dev; do
  user=$(basename "$user_home")

  ssh_dir="${user_home}/.ssh"
  mkdir -p "$ssh_dir"
  printf '%s\n' "$SSH_PUBLIC_KEY" >> "${ssh_dir}/authorized_keys"
  chmod 700 "$ssh_dir"
  chmod 600 "${ssh_dir}/authorized_keys"

  if [[ "$user_home" != "/root" ]]; then
    chown -R "${user}:${user}" "$ssh_dir"
  fi
done

echo "SSH public key installed for root, deploy, dev."
