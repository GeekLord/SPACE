#!/usr/bin/env bash
set -euo pipefail

echo "Waiting for cloud-init to finish..."
while [ ! -f /var/lib/cloud/instance/boot-finished ]; do
  sleep 2
done
echo "cloud-init complete."
