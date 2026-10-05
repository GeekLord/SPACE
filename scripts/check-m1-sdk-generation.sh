#!/usr/bin/env bash
set -Eeuo pipefail

# v7.25.0: pin the generator so neither upstream nor build configuration can
# redefine conformance before the generated package is imported with a token.
GENERATOR_IMAGE="openapitools/openapi-generator-cli@sha256:2ab0a9680222de65dc9d3baf861aa02b99e1b80c211d8221ebf3ae8f8a102524"
# The index's linux/amd64 image. GitHub CI pulls it by this digest from its
# GHCR mirror (ci/mirrored-images.txt) and names that repository in
# SPACE_M1_GENERATOR_MIRROR.
GENERATOR_AMD64_DIGEST="sha256:d859876eefb0c9ac2b2aac9935a1ff775e6a8af0da175d2a159b05811deff32f"
SPEC_SOURCE="${1:-}"

if [[ -z "$SPEC_SOURCE" ]]; then
  echo "usage: $0 <openapi-json-path-or-url>" >&2
  exit 64
fi

for bin in curl docker python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $bin" >&2
    exit 1
  fi
done

# That copy cannot satisfy the index's reference, so name it directly when
# this daemon has it. Otherwise pull the index, as everywhere else.
if [[ -n "${SPACE_M1_GENERATOR_MIRROR:-}" ]]; then
  if docker image inspect "$SPACE_M1_GENERATOR_MIRROR@$GENERATOR_AMD64_DIGEST" >/dev/null 2>&1; then
    GENERATOR_IMAGE="$SPACE_M1_GENERATOR_MIRROR@$GENERATOR_AMD64_DIGEST"
  fi
  echo "Generating with $GENERATOR_IMAGE"
fi

work_dir="$(mktemp -d)"
container=""
cleanup() {
  if [[ -n "$container" ]]; then
    docker rm --force "$container" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

spec="$work_dir/openapi.json"
case "$SPEC_SOURCE" in
  http://*|https://*) curl -fsS "$SPEC_SOURCE" -o "$spec" ;;
  *) cp -- "$SPEC_SOURCE" "$spec" ;;
esac

container="$(docker create "$GENERATOR_IMAGE" generate \
  -g python \
  -i /opt/openapi-generator/openapi.json \
  -o /opt/openapi-generator/out \
  --global-property apiTests=false,modelTests=false,apiDocs=false,modelDocs=false)"
docker cp "$spec" "$container:/opt/openapi-generator/openapi.json"
docker start "$container" >/dev/null
status="$(docker wait "$container")"
docker logs "$container" >"$work_dir/generator.log" 2>&1
if [[ "$status" != "0" ]] || grep -q '^\[main\] ERROR ' "$work_dir/generator.log"; then
  cat "$work_dir/generator.log" >&2
  echo "ERROR: OpenAPI Generator rejected the M1 document" >&2
  exit 1
fi
docker cp "$container:/opt/openapi-generator/out/." "$work_dir/generated"
docker rm "$container" >/dev/null
container=""

python3 -m compileall -q "$work_dir/generated/openapi_client"
python3 - "$work_dir/generated/openapi_client/api/default_api.py" <<'PY'
import ast
import pathlib
import sys

expected = {
    "create_command",
    "create_sandbox",
    "delete_sandbox",
    "get_operation",
    "get_process",
    "get_sandbox",
    "kill_process",
    "list_processes",
    "list_sandboxes",
    "pause_sandbox",
    "signal_process",
    "stream_session_events",
    "suspend_sandbox",
    "wake_sandbox",
}
module = ast.parse(pathlib.Path(sys.argv[1]).read_text())
api = next(node for node in module.body if isinstance(node, ast.ClassDef) and node.name == "DefaultApi")
generated = {
    node.name
    for node in api.body
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    and not node.name.startswith("_")
    and not node.name.endswith(("_with_http_info", "_without_preload_content"))
}
if generated != expected:
    raise SystemExit(
        f"generated SDK operation mismatch: missing={sorted(expected - generated)}, "
        f"unexpected={sorted(generated - expected)}"
    )
PY

if [[ -n "${SPACE_M1_GENERATED_SDK_DIR:-}" ]]; then
  cp -R "$work_dir/generated/." "$SPACE_M1_GENERATED_SDK_DIR"
fi

echo "M1 OpenAPI generated a compilable Python SDK with all 14 release operations"
