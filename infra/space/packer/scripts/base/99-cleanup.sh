#!/usr/bin/env bash
# Final cleanup before image ships. Runs as root.
#
# Environment:
#   DISABLE_ROOT_SSH — "true" to fully disable root SSH, "false" for key-only break-glass
set -euo pipefail

# DHCP on all interfaces; the VPC assigns the address.
if [[ -d /etc/netplan ]]; then
  tee /etc/netplan/99-space.yaml > /dev/null <<'EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
EOF
  rm -f /etc/netplan/50-cloud-init.yaml
fi

# SSH: key-only, no passwords.
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
if [[ "${DISABLE_ROOT_SSH:-false}" == "true" ]]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  echo "Root SSH: disabled"
else
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  echo "Root SSH: key-only (break-glass)"
fi
passwd -l root

# Remove cloud-init sudo rules (if any)
rm -f /etc/sudoers.d/90-cloud-init-users

cloud-init clean --logs --seed
truncate -s 0 /etc/machine-id
rm -rf /tmp/* /var/tmp/*
sync
