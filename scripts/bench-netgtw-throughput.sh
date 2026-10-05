#!/usr/bin/env bash
#
# Benchmark net-gateway throughput and latency impact on a live worker.
# Compares traffic with TPROXY (through gateway) vs direct (kernel NAT only).
#
# Usage:
#   bash scripts/bench-netgtw-throughput.sh [--host user@host] [sandbox-id-prefix]
#
# Examples:
#   bash scripts/bench-netgtw-throughput.sh                                    # run locally on worker
#   bash scripts/bench-netgtw-throughput.sh --host root@utm-space-worker       # run from Mac over SSH
#   bash scripts/bench-netgtw-throughput.sh --host root@utm-space-worker abc123
#
# If no sandbox ID is given, creates a new one.

set -euo pipefail

# ─── Parse args ──────────────────────────────────────────────────────────────

REMOTE=""
SBX_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) REMOTE="$2"; shift 2 ;;
        *)      SBX_ID="$1"; shift ;;
    esac
done

# If --host is given, copy this script to the remote and run it there
if [ -n "$REMOTE" ]; then
    echo "Sending script to $REMOTE..."
    scp -q "$0" "$REMOTE":/tmp/.netgtw-test.sh
    exec ssh -o ConnectTimeout=5 "$REMOTE" "bash /tmp/.netgtw-test.sh $SBX_ID; rm -f /tmp/.netgtw-test.sh"
fi

# ─── From here on, we are running on the worker node ─────────────────────────

BIN="${BIN_DIR:-/space/bin}"
SSH="$BIN/space-ssh"
SBXMGR="$BIN/space-sbxmgr"

# 100 MB test file
DOWNLOAD_URL="https://ash-speed.hetzner.com/100MB.bin"
LATENCY_URL="https://httpbin.org/get"

# ─── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

wait_for_ssh() {
    local id="$1" max=30
    echo -n "Waiting for SSH..."
    for i in $(seq 1 $max); do
        if $SSH "$id" --user root echo ok 2>/dev/null | grep -q ok; then
            echo " ready (${i}s)"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo " TIMEOUT"
    return 1
}

guest_run() {
    local id="$1"; shift
    $SSH "$id" --user root "$@" 2>/dev/null
}

get_namespace() {
    local id="$1"
    local compact="${id//-/}"
    local short="${compact: -8}"
    echo "sns-${short}"
}

# ─── Setup ────────────────────────────────────────────────────────────────────

SBX_ID="${1:-}"

if [ -z "$SBX_ID" ]; then
    echo "Creating sandbox..."
    SBX_ID=$($SBXMGR create --backend fc --template seed --autostart --blocking 2>&1 | awk '/^Sandbox:/{print $2}')
    [ -z "$SBX_ID" ] && die "Failed to create sandbox"
    echo "Created and started: $SBX_ID"
    CREATED=1
else
    CREATED=0
fi

SHORT="${SBX_ID:0:8}"
NS=$(get_namespace "$SBX_ID")
echo "Sandbox: $SHORT  Namespace: $NS"
echo

wait_for_ssh "$SHORT" || die "SSH not available"

echo "Checking guest tools..."
guest_run "$SHORT" curl --version >/dev/null || die "curl not available in guest"
echo "  curl: OK"

# ─── Test functions ───────────────────────────────────────────────────────────

test_download() {
    local label="$1"
    echo "  [$label] Download 100MB..."
    local result
    result=$(guest_run "$SHORT" "curl -o /dev/null -w 'SPEED=%{speed_download} TIME=%{time_total}' -s --connect-timeout 15 --max-time 120 $DOWNLOAD_URL" 2>&1)
    local speed=$(echo "$result" | sed -n 's/.*SPEED=\([0-9.]*\).*/\1/p' | tail -1)
    local time=$(echo "$result" | sed -n 's/.*TIME=\([0-9.]*\).*/\1/p' | tail -1)
    speed=$(echo "${speed:-0}" | awk '{printf "%.2f", $1/1048576}')
    time=$(echo "${time:-0}" | awk '{printf "%.2f", $1}')
    echo "    Speed: ${speed} MB/s  Time: ${time}s"
    eval "${label}_DL_SPEED=$speed"
    eval "${label}_DL_TIME=$time"
}

test_latency() {
    local label="$1"
    echo "  [$label] HTTP latency..."
    local result
    result=$(guest_run "$SHORT" "curl -o /dev/null -w 'CONN=%{time_connect} TTFB=%{time_starttransfer} TOTAL=%{time_total}' -s $LATENCY_URL" 2>&1)
    local connect=$(echo "$result" | sed -n 's/.*CONN=\([0-9.]*\).*/\1/p' | tail -1)
    local ttfb=$(echo "$result" | sed -n 's/.*TTFB=\([0-9.]*\).*/\1/p' | tail -1)
    local total=$(echo "$result" | sed -n 's/.*TOTAL=\([0-9.]*\).*/\1/p' | tail -1)
    connect=$(echo "${connect:-0}" | awk '{printf "%.0f", $1*1000}')
    ttfb=$(echo "${ttfb:-0}" | awk '{printf "%.0f", $1*1000}')
    total=$(echo "${total:-0}" | awk '{printf "%.0f", $1*1000}')
    echo "    Connect: ${connect}ms  TTFB: ${ttfb}ms  Total: ${total}ms"
    eval "${label}_CONNECT=$connect"
    eval "${label}_TTFB=$ttfb"
    eval "${label}_TOTAL=$total"
}

test_dns() {
    local label="$1"
    echo "  [$label] DNS lookup..."
    local result
    result=$(guest_run "$SHORT" "curl -o /dev/null -s -w 'DNS=%{time_namelookup}' https://github.com" 2>&1)
    local dns=$(echo "$result" | sed -n 's/.*DNS=\([0-9.]*\).*/\1/p' | tail -1)
    dns=$(echo "${dns:-0}" | awk '{printf "%.0f", $1*1000}')
    echo "    DNS resolve: ${dns}ms"
    eval "${label}_DNS=$dns"
}

# ─── Gateway stats before ────────────────────────────────────────────────────

echo
echo "=== Gateway stats (before tests) ==="
$SBXMGR stats "$SHORT" 2>&1 || echo "(stats unavailable)"

# ─── Test WITH gateway (TPROXY active) ────────────────────────────────────────

echo
echo "=== WITH net-gateway (TPROXY) ==="
test_download "WITH"
test_latency "WITH"
test_dns "WITH"

# ─── Gateway stats after WITH tests ──────────────────────────────────────────

echo
echo "=== Gateway stats (after WITH tests) ==="
$SBXMGR stats "$SHORT" 2>&1 || echo "(stats unavailable)"

# ─── Disable gateway (remove TPROXY rules) ────────────────────────────────────

echo
echo "=== Disabling net-gateway (removing TPROXY rules) ==="
ip netns exec "$NS" nft list table ip proxy > /tmp/netgtw-tproxy-rules.nft 2>/dev/null || true
ip netns exec "$NS" nft delete table ip proxy 2>/dev/null || echo "  (no proxy table to delete)"
ip netns exec "$NS" nft delete chain ip sandbox forward 2>/dev/null || echo "  (no forward chain)"
echo "  TPROXY rules removed, traffic bypasses gateway"

# ─── Test WITHOUT gateway (kernel NAT only) ───────────────────────────────────

echo
echo "=== WITHOUT net-gateway (kernel NAT) ==="
test_download "WITHOUT"
test_latency "WITHOUT"
test_dns "WITHOUT"

# ─── Restore gateway ──────────────────────────────────────────────────────────

echo
echo "=== Restoring TPROXY rules ==="
if [ -f /tmp/netgtw-tproxy-rules.nft ]; then
    ip netns exec "$NS" nft -f /tmp/netgtw-tproxy-rules.nft 2>/dev/null || echo "  (restore failed, sandbox may need restart)"
    ip netns exec "$NS" nft add chain ip sandbox forward '{ type filter hook forward priority 0; }' 2>/dev/null || true
    ip netns exec "$NS" nft add rule ip sandbox forward iifname tap0 drop 2>/dev/null || true
    echo "  TPROXY rules restored"
else
    echo "  (no saved rules to restore)"
fi
rm -f /tmp/netgtw-tproxy-rules.nft

# ─── Comparison ───────────────────────────────────────────────────────────────

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    RESULTS COMPARISON                       ║"
echo "╠══════════════════════╦═══════════════╦═══════════════╦══════╣"
echo "║ Metric               ║ With Gateway  ║ Without       ║ Δ    ║"
echo "╠══════════════════════╬═══════════════╬═══════════════╬══════╣"
printf "║ Download (MB/s)      ║ %13s ║ %13s ║      ║\n" "${WITH_DL_SPEED:-?}" "${WITHOUT_DL_SPEED:-?}"
printf "║ Download time (s)    ║ %13s ║ %13s ║      ║\n" "${WITH_DL_TIME:-?}" "${WITHOUT_DL_TIME:-?}"
printf "║ HTTP connect (ms)    ║ %13s ║ %13s ║      ║\n" "${WITH_CONNECT:-?}" "${WITHOUT_CONNECT:-?}"
printf "║ HTTP TTFB (ms)       ║ %13s ║ %13s ║      ║\n" "${WITH_TTFB:-?}" "${WITHOUT_TTFB:-?}"
printf "║ DNS resolve (ms)     ║ %13s ║ %13s ║      ║\n" "${WITH_DNS:-?}" "${WITHOUT_DNS:-?}"
echo "╚══════════════════════╩═══════════════╩═══════════════╩══════╝"

# ─── Cleanup ──────────────────────────────────────────────────────────────────

if [ "$CREATED" = "1" ]; then
    echo
    echo "Cleaning up sandbox..."
    $SBXMGR stop "$SHORT" >/dev/null 2>&1 || true
    $SBXMGR delete "$SHORT" >/dev/null 2>&1 || true
fi

echo
echo "Done."
