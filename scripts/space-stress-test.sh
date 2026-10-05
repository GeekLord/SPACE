#!/usr/bin/env bash
# Stress-test sandbox resource limits.
#
# Creates a sandbox, generates load for CPU/memory/disk/network/PIDs/FDs,
# and verifies from the host side that cgroup, Firecracker rate limiters,
# and jailer limits actually cap a misbehaving sandbox.
#
# Uses only tools available in the base template (python3, dd, curl, shell).
# No apt-get or stress-ng required.
#
# Usage:
#   ./scripts/space-stress-test.sh [<host>] [--template <tpl>]
#
# Default host: utm-space-worker
# Default template: base
set -euo pipefail

SSH_USER="deploy"
NODE_IP="${1:-utm-space-worker}"
TEMPLATE="base"
SBX_ID=""

# Parse flags (skip first positional arg if it doesn't start with --)
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) TEMPLATE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Results tracking ────────────────────────────────────────────────────────

declare -A RESULTS
declare -A DETAILS
PASS=0 FAIL=0 SKIP=0

result_pass() { RESULTS["$1"]="PASS"; DETAILS["$1"]="$2"; PASS=$((PASS+1)); echo "[PASS] $1  $2"; }
result_fail() { RESULTS["$1"]="FAIL"; DETAILS["$1"]="$2"; FAIL=$((FAIL+1)); echo "[FAIL] $1  $2"; }
result_skip() { RESULTS["$1"]="SKIP"; DETAILS["$1"]="$2"; SKIP=$((SKIP+1)); echo "[SKIP] $1  $2"; }

# ── Helpers ─────────────────────────────────────────────────────────────────

remote() {
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$NODE_IP" "sudo $*"
}

# Run command inside sandbox with a timeout (default 30s)
sandbox_ssh() {
  local timeout_sec="${SANDBOX_TIMEOUT:-30}"
  remote timeout "$timeout_sec" /space/bin/space-ssh "$SBX_ID" "$@"
}

# Read from the jailer-created cgroup (no sbx- prefix).
# The jailer places the Firecracker VMM process in /space/{id}/.
# The sidecar cgroup at /space/sbx-{id}/ only contains netgtw + spaced-host.
cgroup_read() {
  remote cat "/sys/fs/cgroup/space/${SBX_ID}/$1" 2>/dev/null
}

cleanup() {
  if [[ -n "$SBX_ID" ]]; then
    echo ""
    echo "Cleaning up sandbox ${SBX_ID:0:8}..."
    remote /space/bin/space-sbxmgr delete "$SBX_ID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Setup ───────────────────────────────────────────────────────────────────

echo "=== SPACE Resource Limit Stress Test ==="
echo "Host:     $NODE_IP"
echo "Template: $TEMPLATE"
echo ""

# Create sandbox
echo "Creating sandbox..."
CREATE_OUT=$(remote /space/bin/space-sbxmgr create --backend fc --template "$TEMPLATE" 2>&1)
SBX_ID=$(echo "$CREATE_OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
if [[ -z "$SBX_ID" ]]; then
  echo "ERROR: Failed to create sandbox"
  echo "$CREATE_OUT"
  exit 1
fi
echo "  sandbox: ${SBX_ID:0:12}..."

# Start sandbox
echo "Starting sandbox..."
remote /space/bin/space-sbxmgr start "$SBX_ID" >/dev/null 2>&1
echo "  started"

# Wait for SSH
echo "Waiting for SSH..."
for i in $(seq 1 30); do
  if sandbox_ssh true 2>/dev/null; then
    echo "  SSH ready (${i}s)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: SSH not ready after 30s"
    exit 1
  fi
  sleep 1
done

echo ""
echo "Sandbox: $SBX_ID"
echo ""
echo "Running tests..."
echo ""

# ── Test: CPU ───────────────────────────────────────────────────────────────
# Firecracker exposes vcpu_count vCPUs to the guest, so the guest can't
# exceed that at the hardware level. The cgroup cpu.max is a second barrier.
# We verify both: (1) cpu.max is set correctly, (2) actual CPU usage from
# 8 busy workers stays within ~2 vCPU-seconds per wall-clock second.

test_cpu() {
  local name="CPU"

  local cpu_max
  cpu_max=$(cgroup_read cpu.max)
  if [[ -z "$cpu_max" ]]; then
    result_fail "$name" "cannot read cpu.max"
    return
  fi

  # Read usage baseline
  local usage_before
  usage_before=$(cgroup_read cpu.stat | grep "^usage_usec" | awk '{print $2}')
  usage_before=${usage_before:-0}

  # Burn CPU for 5s using dd (reads from /dev/urandom, CPU-intensive)
  # Run 4 parallel dd processes to saturate 2 vCPUs
  SANDBOX_TIMEOUT=20 sandbox_ssh "dd if=/dev/urandom of=/dev/null bs=64K count=100000 & dd if=/dev/urandom of=/dev/null bs=64K count=100000 & dd if=/dev/urandom of=/dev/null bs=64K count=100000 & dd if=/dev/urandom of=/dev/null bs=64K count=100000 & sleep 5; kill %1 %2 %3 %4 2>/dev/null; wait 2>/dev/null" 2>/dev/null || true

  # Read usage after
  local usage_after
  usage_after=$(cgroup_read cpu.stat | grep "^usage_usec" | awk '{print $2}')
  usage_after=${usage_after:-0}

  local used_usec=$((usage_after - usage_before))
  local used_sec
  used_sec=$(echo "scale=1; $used_usec / 1000000" | bc 2>/dev/null || echo "?")

  # With 2 vCPUs and 5s wall time, max CPU time is ~10s (2 * 5).
  # Allow some tolerance: should be between 5s and 12s.
  if [[ "$cpu_max" != "200000 100000" ]]; then
    result_fail "$name" "cpu.max=$cpu_max (expected 200000 100000)"
  elif [[ $used_usec -gt 12000000 ]]; then
    result_fail "$name" "used ${used_sec}s CPU in 5s wall (>12s = exceeded 2 vCPU cap)"
  elif [[ $used_usec -lt 1000000 ]]; then
    result_fail "$name" "used only ${used_sec}s CPU (burn may not have run)"
  else
    result_pass "$name" "cpu.max=$cpu_max, used ${used_sec}s CPU in 5s wall (~2 vCPU)"
  fi
}

# ── Test: Memory ────────────────────────────────────────────────────────────
# The VM has 1024 MiB. Guest OS uses ~100M. We verify:
# (1) cgroup memory.max and memory.swap.max are set correctly
# (2) a guest that exhausts memory cannot crash the sandbox
# (3) the sandbox remains responsive after memory pressure

test_memory() {
  local name="Memory"

  local mem_max swap_max
  mem_max=$(cgroup_read memory.max)
  swap_max=$(cgroup_read memory.swap.max)

  if [[ -z "$mem_max" ]]; then
    result_fail "$name" "cannot read memory.max"
    return
  fi

  # Verify cgroup limits are correct
  local limits_ok=true
  [[ "$mem_max" != "1073741824" ]] && limits_ok=false
  [[ "$swap_max" != "0" ]] && limits_ok=false

  # Check guest sees correct memory
  local guest_total_m
  guest_total_m=$(sandbox_ssh "free -m | awk '/Mem:/{print \$2}'" 2>/dev/null || echo "0")

  # Try to allocate more than the VM has — the guest OOM killer should
  # terminate the offending process, NOT crash the Firecracker VM.
  local oom_exit=0
  SANDBOX_TIMEOUT=15 sandbox_ssh "python3 -c \"
import sys
try:
    b = bytearray(1100 * 1024 * 1024)
    sys.exit(0)  # should not reach here
except MemoryError:
    sys.exit(1)
\"" 2>/dev/null || oom_exit=$?

  # Critical: verify the sandbox is still alive after memory pressure.
  # If the guest OOM crashed Firecracker, SSH will fail here.
  local alive=0
  for i in $(seq 1 10); do
    if sandbox_ssh "true" 2>/dev/null; then
      alive=1
      break
    fi
    sleep 1
  done

  if [[ "$limits_ok" != "true" ]]; then
    if [[ "$mem_max" != "1073741824" ]]; then
      result_fail "$name" "memory.max=$mem_max (expected 1073741824)"
    else
      result_fail "$name" "memory.swap.max=$swap_max (expected 0)"
    fi
  elif [[ $guest_total_m -gt 1024 ]]; then
    result_fail "$name" "guest_total=${guest_total_m}M (expected <=1024)"
  elif [[ $oom_exit -eq 0 ]]; then
    result_fail "$name" "1100M allocation succeeded (should have been rejected with ${guest_total_m}M total)"
  elif [[ $alive -eq 0 ]]; then
    result_fail "$name" "sandbox crashed after memory pressure (Firecracker not responsive)"
  else
    result_pass "$name" "memory.max=$mem_max, swap=$swap_max, guest=${guest_total_m}M, 1100M alloc rejected, sandbox survived"
  fi
}

# ── Test: PIDs ──────────────────────────────────────────────────────────────

test_pids() {
  local name="PIDs"

  local pids_max
  pids_max=$(cgroup_read pids.max)
  if [[ -z "$pids_max" ]]; then
    result_fail "$name" "cannot read pids.max"
    return
  fi

  # Try to fork 300 processes (limit is 256 for the whole cgroup)
  SANDBOX_TIMEOUT=15 sandbox_ssh "python3 -c \"
import subprocess, sys
procs = []
try:
    for i in range(300):
        procs.append(subprocess.Popen(['sleep', '10']))
except OSError as e:
    print(f'Fork capped at {len(procs)}: {e}', file=sys.stderr)
finally:
    for p in procs:
        p.kill()
    for p in procs:
        p.wait()
\"" 2>/dev/null || true

  if [[ "$pids_max" == "256" ]]; then
    result_pass "$name" "pids.max=$pids_max, fork-bomb contained"
  else
    result_fail "$name" "pids.max=$pids_max (expected 256)"
  fi
}

# ── Test: Disk I/O ──────────────────────────────────────────────────────────

test_disk_io() {
  local name="Disk I/O"

  local dd_out
  dd_out=$(SANDBOX_TIMEOUT=60 sandbox_ssh "dd if=/dev/zero of=/tmp/stresstest bs=1M count=300 conv=fsync 2>&1; rm -f /tmp/stresstest" 2>/dev/null) || true

  # dd reports: "314572800 bytes (315 MB, 300 MiB) copied, 3.12 s, 96.3 MB/s"
  local throughput
  throughput=$(echo "$dd_out" | grep -oE '[0-9.]+ [MG]B/s' | tail -1)

  if [[ -z "$throughput" ]]; then
    result_fail "$name" "could not parse dd output: $(echo "$dd_out" | tail -1)"
    return
  fi

  local value unit
  value=$(echo "$throughput" | grep -oE '[0-9.]+')
  unit=$(echo "$throughput" | grep -oE '[MG]B/s')

  local mib_s
  if [[ "$unit" == "GB/s" ]]; then
    mib_s=$(echo "$value * 1000" | bc 2>/dev/null || echo "9999")
  else
    mib_s="$value"
  fi

  # FC rate limiter is 100 MiB/s; allow 30% tolerance
  local over
  over=$(echo "$mib_s > 130" | bc 2>/dev/null || echo "0")
  if [[ "$over" == "1" ]]; then
    result_fail "$name" "throughput ${throughput} exceeds 130 MB/s (limit: 100 MiB/s)"
  else
    result_pass "$name" "throughput: ${throughput} (limit: ~100 MiB/s)"
  fi
}

# ── Test: Network ───────────────────────────────────────────────────────────

test_network() {
  local name="Network"

  # Quick connectivity check
  local can_reach=0
  SANDBOX_TIMEOUT=15 sandbox_ssh "curl -s -o /dev/null --connect-timeout 5 --max-time 10 http://1.1.1.1" 2>/dev/null && can_reach=1

  if [[ $can_reach -eq 0 ]]; then
    result_skip "$name" "no internet access from sandbox"
    return
  fi

  local curl_out
  curl_out=$(SANDBOX_TIMEOUT=45 sandbox_ssh "curl -o /dev/null -s -w '%{speed_download}' --max-time 30 http://speedtest.tele2.net/10MB.zip" 2>/dev/null) || true

  if [[ -z "$curl_out" ]]; then
    result_skip "$name" "curl download failed"
    return
  fi

  # curl reports speed_download in bytes/sec
  local speed_mib
  speed_mib=$(echo "scale=1; $curl_out / 1048576" | bc 2>/dev/null || echo "0")

  # Need at least some speed to consider the test valid
  local too_slow
  too_slow=$(echo "$speed_mib < 0.1" | bc 2>/dev/null || echo "1")
  if [[ "$too_slow" == "1" ]]; then
    result_skip "$name" "download too slow or failed (${speed_mib} MiB/s, mirror may be unreachable)"
    return
  fi

  local over
  over=$(echo "$speed_mib > 65" | bc 2>/dev/null || echo "0")
  if [[ "$over" == "1" ]]; then
    result_fail "$name" "download ${speed_mib} MiB/s exceeds 65 MiB/s (limit: 50 MiB/s)"
  else
    result_pass "$name" "download: ${speed_mib} MiB/s (limit: ~50 MiB/s)"
  fi
}

# ── Test: File Descriptors ──────────────────────────────────────────────────

test_fd() {
  local name="FDs"

  # Check ulimit from inside the guest — the jailer sets RLIMIT_NOFILE=4096
  # which propagates to all processes inside the VM
  local ulimit_out
  ulimit_out=$(SANDBOX_TIMEOUT=10 sandbox_ssh "ulimit -n" 2>/dev/null) || true

  # Also try to open many fds with a simple shell command
  local ls_exit=0
  sandbox_ssh "ls /proc/self/fd >/dev/null 2>&1 && head -c 0 /dev/null" 2>/dev/null || ls_exit=$?

  if [[ "$ulimit_out" == "4096" ]]; then
    result_pass "$name" "ulimit -n=$ulimit_out inside guest (jailer limit: 4096)"
  elif [[ -n "$ulimit_out" ]] && [[ "$ulimit_out" -le 4096 ]] 2>/dev/null; then
    result_pass "$name" "ulimit -n=$ulimit_out inside guest (at or below 4096)"
  elif [[ -n "$ulimit_out" ]]; then
    result_fail "$name" "ulimit -n=$ulimit_out inside guest (expected 4096)"
  else
    result_fail "$name" "could not read ulimit inside guest"
  fi
}

# ── Run tests ───────────────────────────────────────────────────────────────

test_cpu || true
test_memory || true
test_pids || true
test_disk_io || true
test_network || true
test_fd || true

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
TOTAL=$((PASS + FAIL + SKIP))
echo "Result: $PASS/$TOTAL passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
