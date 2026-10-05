#!/usr/bin/env bash
# ensure-docker.sh — make Docker Desktop responsive on macOS.
#
# Probes the daemon, starts/restarts/force-restarts Docker Desktop as needed,
# and prints diagnostics on final failure. Exit 0 = daemon responsive.

set -uo pipefail

PROBE_TIMEOUT=5
WAIT_AFTER_RUNNING=30
WAIT_AFTER_LAUNCH=90
WAIT_AFTER_FORCE=120

is_responsive() {
  timeout "${PROBE_TIMEOUT}" docker info --format '{{.ServerVersion}}' >/dev/null 2>&1
}

is_app_running() {
  pgrep -f '/Applications/Docker.app/Contents/MacOS/com.docker.backend' >/dev/null 2>&1
}

wait_for_responsive() {
  local timeout=$1
  local elapsed=0
  while ! is_responsive; do
    if (( elapsed >= timeout )); then
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    printf '.'
  done
  printf '\n'
  return 0
}

start_docker() {
  echo "==> Launching Docker Desktop"
  open -ga Docker
}

stop_docker() {
  echo "==> Quitting Docker Desktop"
  osascript -e 'quit app "Docker"' 2>/dev/null || true
  local elapsed=0
  while is_app_running && (( elapsed < 30 )); do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if is_app_running; then
    echo "    graceful quit timed out, killing"
    pkill -9 -f '/Applications/Docker.app' 2>/dev/null || true
    sleep 2
  fi
}

dump_diagnostics() {
  echo "=========================================="
  echo "Docker Desktop diagnostics"
  echo "=========================================="
  echo "--- Docker processes ---"
  pgrep -fl 'Docker.app|com.docker' | head -20 || echo "(none)"
  echo
  echo "--- Sockets ---"
  ls -la "${HOME}/.docker/run/docker.sock" 2>&1 || true
  ls -la /var/run/docker.sock 2>&1 || true
  echo
  echo "--- docker context ---"
  docker context ls 2>&1 | head -20 || true
  echo
  echo "--- Last 30 log lines (com.docker.backend) ---"
  tail -30 "${HOME}/Library/Containers/com.docker.docker/Data/log/host/com.docker.backend.log" 2>/dev/null \
    || echo "(backend log not found)"
  echo
  echo "--- Last 30 log lines (dockerd) ---"
  tail -30 "${HOME}/Library/Containers/com.docker.docker/Data/log/vm/dockerd.log" 2>/dev/null \
    || echo "(dockerd log not found)"
}

main() {
  # 1. Already responsive?
  if is_responsive; then
    echo "✅ Docker daemon is responsive."
    docker version --format 'Server: {{.Server.Version}}' 2>/dev/null || true
    exit 0
  fi

  # 2. App running but daemon hung — give it a bit, then restart.
  if is_app_running; then
    echo "Docker Desktop process is up but daemon is unresponsive."
    echo "Waiting up to ${WAIT_AFTER_RUNNING}s for it to recover..."
    if wait_for_responsive "${WAIT_AFTER_RUNNING}"; then
      echo "✅ Daemon recovered."
      exit 0
    fi
    echo "Still hung. Restarting Docker Desktop."
    stop_docker
    sleep 2
    start_docker
  else
    echo "Docker Desktop is not running."
    start_docker
  fi

  # 3. Wait for daemon after launch.
  echo "Waiting up to ${WAIT_AFTER_LAUNCH}s for daemon to come up..."
  if wait_for_responsive "${WAIT_AFTER_LAUNCH}"; then
    echo "✅ Docker daemon is responsive."
    docker version --format 'Server: {{.Server.Version}}' 2>/dev/null || true
    exit 0
  fi

  # 4. Force-kill, relaunch, wait longer.
  echo "Daemon did not come up in ${WAIT_AFTER_LAUNCH}s. Force-restarting."
  pkill -9 -f '/Applications/Docker.app' 2>/dev/null || true
  sleep 3
  start_docker
  echo "Waiting up to ${WAIT_AFTER_FORCE}s for daemon after force-restart..."
  if wait_for_responsive "${WAIT_AFTER_FORCE}"; then
    echo "✅ Docker daemon is responsive after force-restart."
    exit 0
  fi

  # 5. Give up loud, with diagnostics.
  echo "❌ Docker daemon failed to become responsive after all attempts."
  dump_diagnostics
  exit 1
}

main "$@"
