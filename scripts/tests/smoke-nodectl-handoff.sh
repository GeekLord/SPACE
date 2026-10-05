#!/usr/bin/env bash
set -Eeuo pipefail

# Live two-process handoff smoke for space-nodectl-svc: real binaries
# contending on the real flock service mutex, taking over the production
# socket by atomic rename, probed over gRPC. Runs on macOS or Linux dev
# machines with the /space tree present; it is
# not a substitute for cluster behavior (kubelet ordering, probes, the
# bundled-pod sidecar chain), only for the binary-level handoff contract.
#
# Scenarios:
#   1 cooperative-handoff  SIGTERM the active instance; the passive one
#                          (health SERVING while passive, shared db)
#                          takes over; measures the unavailability window
#                          with a continuous probe loop.
#   2 crash-handoff        SIGKILL the active instance; the kernel
#                          releases the flock; the successor takes over.
#   3 contender-race       two passive instances; exactly one activates
#                          when the holder exits.
#   4 passive-exit         SIGTERM a passive instance; exits 0 cleanly.
#   5 stuck-predecessor    SIGSTOP the holder; a successor with a short
#                          --service-mutex-timeout-secs exits non-zero —
#                          the visible-failure alarm.

NODECTL_BIN="${NODECTL_BIN:-target/debug/space-nodectl-svc}"
SIM_DIR="${SIM_DIR:-/space/run/node-ctl}"
PROBE_INTERVAL_S="${PROBE_INTERVAL_S:-0.02}"

for bin in grpcurl jq mktemp python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $bin" >&2
    exit 1
  fi
done
if [[ ! -x "$NODECTL_BIN" ]]; then
  echo "ERROR: $NODECTL_BIN not built (cargo build -p pplx-space-node-ctl-svc)" >&2
  exit 1
fi
if [[ ! -d "$SIM_DIR" ]]; then
  echo "ERROR: $SIM_DIR missing — set up the /space tree first" >&2
  exit 1
fi

export SPACE_NODE_ID="${SPACE_NODE_ID:-smoke-node}"
export SPACE_INTERNAL_TOKEN="${SPACE_INTERNAL_TOKEN:-smoke-dummy}"
export SPACE_INTERNAL_RPC_INSECURE_DEV="${SPACE_INTERNAL_RPC_INSECURE_DEV:-true}"
# Facet syncs fail against this endpoint and retry; the handoff contract
# under test does not need a live cluster-api.
export SPACE_INTERNAL_API_ENDPOINT="${SPACE_INTERNAL_API_ENDPOINT:-http://127.0.0.1:9}"

if pgrep -f "smoke-handoff.sock" >/dev/null 2>&1; then
  echo "ERROR: stale smoke instances still running (pgrep -f smoke-handoff.sock); kill them first" >&2
  exit 1
fi

TMP="$(mktemp -d /tmp/nodectl-handoff.XXXXXX)"
SOCK="$SIM_DIR/smoke-handoff.sock"
DB="$SIM_DIR/smoke-handoff.db"
PIDS=()
FAILURES=0

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill -CONT "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.5
  for pid in "${PIDS[@]:-}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -f "$SIM_DIR"/smoke-handoff.* "$SOCK"
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/health.proto" <<'EOF'
syntax = "proto3";
package grpc.health.v1;
message HealthCheckRequest { string service = 1; }
message HealthCheckResponse {
  enum ServingStatus { UNKNOWN = 0; SERVING = 1; NOT_SERVING = 2; }
  ServingStatus status = 1;
}
service Health { rpc Check(HealthCheckRequest) returns (HealthCheckResponse); }
EOF

now() { python3 -c 'import time; print(time.time())'; }

probe() {
  grpcurl -plaintext -import-path "$TMP" -proto health.proto -d '{}' \
    "unix://$1" grpc.health.v1.Health/Check 2>/dev/null | jq -r .status
}

# Sets STARTED_PID; spawning must happen in this shell (not a command
# substitution subshell) so `wait` can reap the instance for exit codes.
start_instance() { # name, extra args...
  local name="$1"; shift
  "$NODECTL_BIN" --socket "$SOCK" --db "$DB" --poll-interval-secs 60 "$@" \
    > "$TMP/$name.log" 2>&1 &
  STARTED_PID=$!
  PIDS+=("$STARTED_PID")
}

wait_for() { # timeout_s, description, predicate...
  local timeout_s="$1" what="$2"; shift 2
  local deadline
  deadline=$(python3 -c "import time; print(time.time() + $timeout_s)")
  while ! "$@" >/dev/null 2>&1; do
    if python3 -c "import time,sys; sys.exit(0 if time.time() > $deadline else 1)"; then
      echo "TIMEOUT waiting for: $what" >&2
      return 1
    fi
    sleep 0.05
  done
}

serving() { [[ "$(probe "$1")" == "SERVING" ]]; }
log_has() { grep -q "$2" "$TMP/$1.log"; }

result() { # name, ok
  if [[ "$2" == ok ]]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------- scenario 1
scenario_cooperative() {
  local ok=ok
  local a b
  start_instance a; a=$STARTED_PID
  wait_for 10 "A serving" serving "$SOCK" || ok=fail
  start_instance b --health-socket "$TMP/b-health.sock"; b=$STARTED_PID
  wait_for 10 "B passive" log_has b "passive; waiting for service mutex" || ok=fail
  sleep 0.5
  serving "$TMP/b-health.sock" || { echo "  B health socket not SERVING while passive" >&2; ok=fail; }
  log_has b "transitioning to active" && { echo "  B activated while A held the mutex" >&2; ok=fail; }

  # Continuous probe loop across the handoff to measure the visible gap.
  : > "$TMP/probe-trace"
  (
    while true; do
      printf '%s %s\n' "$(now)" "$(probe "$SOCK")" >> "$TMP/probe-trace"
      sleep "$PROBE_INTERVAL_S"
    done
  ) &
  local prober=$!
  sleep 0.3
  local t0 t1
  t0=$(now)
  kill -TERM "$a"
  wait_for 15 "B active and serving" bash -c \
    "grep -q 'transitioning to active' '$TMP/b.log' && [[ \"\$(grpcurl -plaintext -import-path '$TMP' -proto health.proto -d '{}' 'unix://$SOCK' grpc.health.v1.Health/Check 2>/dev/null | jq -r .status)\" == SERVING ]]" || ok=fail
  t1=$(now)
  { kill "$prober" 2>/dev/null; wait "$prober"; } 2>/dev/null || true
  wait "$a" 2>/dev/null && true
  local a_exit=$?
  [[ "$a_exit" == 0 ]] || { echo "  A exited $a_exit on SIGTERM" >&2; ok=fail; }

  local gap
  gap=$(python3 - "$TMP/probe-trace" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
bad = [float(t) for t, *s in rows if not s or s[0] != "SERVING"]
print(f"{(max(bad) - min(bad)):.3f}s over {len(bad)} probes" if bad else "0 failed probes")
PY
)
  echo "  handoff $(python3 -c "print(f'{$t1-$t0:.2f}s')") SIGTERM-to-serving; probe-visible gap: $gap"
  kill -TERM "$b" 2>/dev/null; wait "$b" 2>/dev/null || true
  rm -f "$DB"* "$TMP/b-health.sock"
  result cooperative-handoff "$ok"
}

# ---------------------------------------------------------------- scenario 2
scenario_crash() {
  local ok=ok
  local a b t0 t1
  start_instance crash-a; a=$STARTED_PID
  wait_for 10 "A serving" serving "$SOCK" || ok=fail
  start_instance crash-b --health-socket "$TMP/crash-b-health.sock"; b=$STARTED_PID
  wait_for 10 "B passive" log_has crash-b "passive; waiting for service mutex" || ok=fail
  t0=$(now)
  disown "$a"
  kill -KILL "$a"
  wait_for 15 "B active after SIGKILL" bash -c \
    "grep -q 'transitioning to active' '$TMP/crash-b.log' && [[ \"\$(grpcurl -plaintext -import-path '$TMP' -proto health.proto -d '{}' 'unix://$SOCK' grpc.health.v1.Health/Check 2>/dev/null | jq -r .status)\" == SERVING ]]" || ok=fail
  t1=$(now)
  echo "  crash handoff $(python3 -c "print(f'{$t1-$t0:.2f}s')") SIGKILL-to-serving (kernel flock release)"
  kill -TERM "$b" 2>/dev/null; wait "$b" 2>/dev/null || true
  rm -f "$DB"* "$TMP/crash-b-health.sock"
  result crash-handoff "$ok"
}

# ---------------------------------------------------------------- scenario 3
scenario_race() {
  local ok=ok
  local a b c
  start_instance race-a; a=$STARTED_PID
  wait_for 10 "A serving" serving "$SOCK" || ok=fail
  start_instance race-b --health-socket "$TMP/race-b-health.sock"; b=$STARTED_PID
  start_instance race-c --health-socket "$TMP/race-c-health.sock"; c=$STARTED_PID
  wait_for 10 "B passive" log_has race-b "passive; waiting" || ok=fail
  wait_for 10 "C passive" log_has race-c "passive; waiting" || ok=fail
  kill -TERM "$a"
  wait_for 15 "one contender active" bash -c \
    "grep -q 'transitioning to active' '$TMP/race-b.log' || grep -q 'transitioning to active' '$TMP/race-c.log'" || ok=fail
  sleep 1
  local active=0
  log_has race-b "transitioning to active" && active=$((active + 1))
  log_has race-c "transitioning to active" && active=$((active + 1))
  [[ "$active" == 1 ]] || { echo "  expected exactly one active contender, saw $active" >&2; ok=fail; }
  serving "$SOCK" || ok=fail
  echo "  exactly one of two contenders activated; the other stayed passive"
  kill -TERM "$b" "$c" 2>/dev/null; wait "$b" "$c" 2>/dev/null || true
  rm -f "$DB"* "$TMP"/race-*-health.sock
  result contender-race "$ok"
}

# ---------------------------------------------------------------- scenario 4
scenario_passive_exit() {
  local ok=ok
  local a b
  start_instance pe-a; a=$STARTED_PID
  wait_for 10 "A serving" serving "$SOCK" || ok=fail
  start_instance pe-b --health-socket "$TMP/pe-b-health.sock"; b=$STARTED_PID
  wait_for 10 "B passive" log_has pe-b "passive; waiting" || ok=fail
  kill -TERM "$b"
  wait "$b" 2>/dev/null && true
  local b_exit=$?
  [[ "$b_exit" == 0 ]] || { echo "  passive instance exited $b_exit on SIGTERM, want 0" >&2; ok=fail; }
  log_has pe-b "terminated while passive" || { echo "  missing passive-exit log line" >&2; ok=fail; }
  echo "  passive instance exits 0 without ever touching the socket or db"
  kill -TERM "$a" 2>/dev/null; wait "$a" 2>/dev/null || true
  rm -f "$DB"* "$TMP/pe-b-health.sock"
  result passive-exit "$ok"
}

# ---------------------------------------------------------------- scenario 5
scenario_stuck_predecessor() {
  local ok=ok
  local a b
  start_instance stuck-a; a=$STARTED_PID
  wait_for 10 "A serving" serving "$SOCK" || ok=fail
  kill -STOP "$a"
  start_instance stuck-b --health-socket "$TMP/stuck-b-health.sock" --service-mutex-timeout-secs 2; b=$STARTED_PID
  wait "$b" 2>/dev/null && true
  local b_exit=$?
  [[ "$b_exit" != 0 ]] || { echo "  successor exited 0 against a stuck predecessor, want non-zero" >&2; ok=fail; }
  echo "  successor exited $b_exit after its 2s mutex budget — the stuck-predecessor alarm"
  kill -CONT "$a"; kill -TERM "$a" 2>/dev/null; wait "$a" 2>/dev/null || true
  rm -f "$DB"* "$TMP/stuck-b-health.sock"
  result stuck-predecessor "$ok"
}

scenario_cooperative
scenario_crash
scenario_race
scenario_passive_exit
scenario_stuck_predecessor

echo
if [[ "$FAILURES" == 0 ]]; then
  echo "all handoff scenarios passed"
else
  echo "$FAILURES scenario(s) FAILED"
  exit 1
fi
