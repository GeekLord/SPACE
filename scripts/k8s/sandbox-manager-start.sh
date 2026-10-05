#!/bin/bash
# sandbox-manager-start.sh — Start sandbox-manager.
#
# Absolute path, not PATH lookup: credmgr's peer binary allowlist compares
# /proc/<pid>/exe against /opt/space/bin/space-sbxmgr-svc, and a PATH-mediated
# launch would couple that guarantee to the image's ENV PATH ordering.
set -euo pipefail

exec /opt/space/bin/space-sbxmgr-svc "$@"
