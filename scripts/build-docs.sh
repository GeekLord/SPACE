#!/usr/bin/env bash
# Build both standalone outputs before assembling the documentation site.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "Build the combined docs from a clean checkout so both sections share a source revision." >&2
  exit 1
fi
commit="$(git rev-parse HEAD)"
bash scripts/build-guide-docs.sh
SPACE_DOCS_NPM_CI_DONE=1 bash scripts/build-api-docs.sh
python3 docs/site/build.py "$commit"
