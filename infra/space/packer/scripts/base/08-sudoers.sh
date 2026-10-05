#!/usr/bin/env bash
# Install targeted sudoers rules. Runs as root during Packer build.
#
# sudo-rs (Ubuntu 25.10+) does not support wildcard command specs.
# - deploy: blanket NOPASSWD (machine-to-machine account)
# - space-sbxmgr: NO sudo (pure orchestrator, all privileged ops via node-manager)
# - dev: NO sudo (group access only)
set -euxo pipefail

tee /etc/sudoers.d/space > /dev/null <<'EOF'
# SPACE platform sudoers.
# Only deploy needs sudo. All other privilege goes through node-manager (root).
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:/space/bin"
deploy ALL=(ALL) NOPASSWD: ALL
EOF

chmod 0440 /etc/sudoers.d/space
visudo -cf /etc/sudoers.d/space

echo "=== Sudoers rules installed ==="
echo "  deploy: ALL NOPASSWD (deploy account)"
echo "  space-sbxmgr: NO sudo (uses node-manager RPCs)"
echo "  dev: NO sudo (group access only)"
