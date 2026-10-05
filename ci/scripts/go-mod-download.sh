#!/usr/bin/env bash
# Download the dependencies of the Go module in the current directory into the
# module cache, retrying a failed download.
#
# A fresh CI runner fetches every shim dependency from the module proxy, and a
# single dropped stream fails the job, e.g. `read "https://proxy.golang.org/
# github.com/gogo/protobuf/@v/v1.3.2.zip": stream error: stream ID 81;
# INTERNAL_ERROR`. A build, vet or test cannot be retried blindly, since it also
# fails on the code. This command only downloads: it fails on the proxy or the
# network, or on a go.mod or go.sum entry the proxy cannot serve, which fails
# every attempt the same way and still ends the script with its error. Modules
# an earlier attempt downloaded stay in the cache. Once it succeeds, building,
# vetting and testing the module need no network.
#
# Usage: ci/scripts/go-mod-download.sh [go binary]   (default: go on PATH)
# Env: SPACE_GO_MOD_DOWNLOAD_ATTEMPTS (default 4) bounds the attempts;
#   SPACE_GO_MOD_DOWNLOAD_BACKOFF_SECONDS (default 5) is the first retry delay,
#   which doubles after each failure.
set -euo pipefail

go_bin="${1:-go}"
attempts="${SPACE_GO_MOD_DOWNLOAD_ATTEMPTS:-4}"
delay="${SPACE_GO_MOD_DOWNLOAD_BACKOFF_SECONDS:-5}"

for ((attempt = 1; ; attempt++)); do
    if "${go_bin}" mod download; then
        if ((attempt > 1)); then
            echo "[go-mod-download] downloaded on attempt ${attempt}/${attempts}" >&2
        fi
        exit 0
    fi
    if ((attempt >= attempts)); then
        echo "[go-mod-download] ERROR: go mod download failed after ${attempts} attempts" >&2
        exit 1
    fi
    echo "[go-mod-download] go mod download failed (attempt ${attempt}/${attempts}); retrying in ${delay}s" >&2
    sleep "${delay}"
    delay=$((delay * 2))
done
