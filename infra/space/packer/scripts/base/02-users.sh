#!/usr/bin/env bash
# Create SPACE system users. Runs early, before other provisioning scripts.
#
# Users:
#   deploy — local operator and machine-to-machine automation, gets scoped sudo
#   dev    — local observer/debug access, no sudo
#   space-sbxmgr — sandbox manager service account used on worker nodes
#
# Note: this script assumes root. On AWS, packer's execute_command wraps with sudo.
set -euxo pipefail

# deploy user — local operator + automation account
if ! id -u deploy 2>/dev/null; then
  useradd -m -s /bin/bash deploy
fi
passwd -l deploy

# dev user — observer/debug access
if ! id -u dev 2>/dev/null; then
  useradd -m -s /bin/bash dev
fi
passwd -l dev

# Note: space-sbxmgr is created later in 07-sysctl.sh after the shared SPACE
# groups exist. It gets a self-group (space-sbxmgr) as primary, used by
# systemd Group= for DB file ownership. Socket access is controlled by
# explicit chown in service code, not by the process primary group.
