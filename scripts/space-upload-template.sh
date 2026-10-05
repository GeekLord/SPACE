#!/usr/bin/env bash
# Upload a local template build directory to S3 at the layout the
# template-manager auto-pull path expects.
#
# Computes the rootfs SHA-256 and uploads to:
#   s3://<BUCKET>/<KEY_PREFIX>/templates/<TEMPLATE>/sha256:<HASH>/<file>
#
# After uploading, register the release with the cluster service so
# `FindTemplateRelease` can resolve it. This script doesn't do that
# step. `space-buildmgr build` now does upload + registration by default;
# this script remains the low-level fallback path. See space-tmplmgr-cli or grpcurl against
# ClusterApi.RegisterTemplateRelease.
#
# Usage:
#   scripts/space-upload-template.sh <build-dir> <template-name>
#
# <build-dir> must contain:
#   rootfs.ext4, metadata.json, manifest.json
#
# The manifest must be the v2 shape carrying `execution`: registration is the
# canonical writer of a release's execution metadata (the node publish path no
# longer backfills it), so this script writes a ready-to-send
# register-release.json that includes the manifest's execution metadata in
# proto-JSON form. Requires python3.
#
# Required env:
#   SPACE_OBJECT_STORE_BUCKET   target bucket
#   SPACE_OBJECT_STORE_REGION   bucket region; baked into the printed
#                               connection_string so template-manager
#                               can resolve the bucket without env vars.
#   AWS_ACCESS_KEY_ID           creds for `aws s3 cp`
#   AWS_SECRET_ACCESS_KEY
#
# Optional env:
#   SPACE_OBJECT_STORE_ENDPOINT     custom S3-compatible endpoint;
#                                   baked into the printed
#                                   connection_string when set.
#   AWS_SESSION_TOKEN               when using STS
#   AWS_REGION / AWS_DEFAULT_REGION respected by `aws` CLI as usual

set -euo pipefail

usage() {
  echo "usage: $0 <build-dir> <template-name>" >&2
  echo "" >&2
  echo "  build-dir must contain rootfs.ext4, metadata.json, manifest.json" >&2
  exit 2
}

BUILD_DIR="${1:-}"
TEMPLATE="${2:-}"
[[ -n "$BUILD_DIR" && -n "$TEMPLATE" ]] || usage

: "${SPACE_OBJECT_STORE_BUCKET:?SPACE_OBJECT_STORE_BUCKET is required}"
: "${SPACE_OBJECT_STORE_REGION:?SPACE_OBJECT_STORE_REGION is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

ROOTFS="$BUILD_DIR/rootfs.ext4"
METADATA="$BUILD_DIR/metadata.json"
MANIFEST="$BUILD_DIR/manifest.json"

for f in "$ROOTFS" "$METADATA" "$MANIFEST"; do
  if [[ ! -f "$f" ]]; then
    echo "error: required file $f not found" >&2
    exit 2
  fi
done

ROOTFS_HASH="$(shasum -a 256 "$ROOTFS" | awk '{print $1}')"
CONTENT_HASH="sha256:$ROOTFS_HASH"

KEY_PREFIX_PATH=""

# Bare s3:// path for `aws s3 cp` (no query string).
S3_BASE="s3://${SPACE_OBJECT_STORE_BUCKET}/${KEY_PREFIX_PATH}templates/${TEMPLATE}/${CONTENT_HASH}"

# Self-describing connection_string for the cluster service. Region
# is required; endpoint is included when a custom S3-compatible
# endpoint is configured. Template-manager parses bucket / prefix /
# region / endpoint straight from this URI — it doesn't read object-
# store env vars on its own.
CONN_STRING_QUERY="region=${SPACE_OBJECT_STORE_REGION}"
if [[ -n "${SPACE_OBJECT_STORE_ENDPOINT:-}" ]]; then
  CONN_STRING_QUERY="${CONN_STRING_QUERY}&endpoint=${SPACE_OBJECT_STORE_ENDPOINT}"
fi
CONN_STRING="${S3_BASE}?${CONN_STRING_QUERY}"

echo "==> source"
echo "    build_dir    = $BUILD_DIR"
echo "    template     = $TEMPLATE"
echo "    content_hash = $CONTENT_HASH"
echo "    rootfs_size  = $(wc -c < "$ROOTFS" | tr -d ' ') bytes"

echo "==> uploading to $S3_BASE"
aws s3 cp --quiet "$ROOTFS"   "${S3_BASE}/rootfs.ext4"
aws s3 cp --quiet "$METADATA" "${S3_BASE}/metadata.json"
aws s3 cp --quiet "$MANIFEST" "${S3_BASE}/manifest.json"

echo "==> uploaded"

# Build the RegisterTemplateRelease request, including the manifest's
# execution metadata converted to proto JSON by the shared
# scripts/lib/manifest_execution_to_proto.py (schema gate matching
# `TemplateManifest::execution_metadata()` in Rust). Registration is the
# canonical writer of release execution metadata — a release registered
# without it keeps NULL metadata forever — so an unusable manifest fails
# the script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXECUTION_PROTO_JSON="$(python3 "$SCRIPT_DIR/lib/manifest_execution_to_proto.py" "$MANIFEST")"
REQUEST_FILE="$BUILD_DIR/register-release.json"
python3 - "$TEMPLATE" "$CONTENT_HASH" "$CONN_STRING" "$EXECUTION_PROTO_JSON" > "$REQUEST_FILE" <<'PY'
import json
import sys

template, content_hash, conn_string, execution_json = sys.argv[1:5]
print(json.dumps({
    "template_name": template,
    "runtime": "fc",
    "hash": content_hash,
    "tags": [content_hash],
    "storage_connection_strings": [conn_string],
    "execution": json.loads(execution_json),
}, indent=2))
PY

echo
echo "wrote $REQUEST_FILE"
echo
echo "next: register the release with the cluster service so"
echo "FindTemplateRelease can resolve it. e.g. via grpcurl:"
echo
echo "  grpcurl -H \"authorization: Bearer \$SPACE_INTERNAL_TOKEN\" \\"
echo "    -d @ < \"$REQUEST_FILE\" \\"
echo "    \$NODE_API_ENDPOINT space.node.api.v1.ClusterApi/RegisterTemplateRelease"
