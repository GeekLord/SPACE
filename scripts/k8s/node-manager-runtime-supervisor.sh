#!/bin/bash

node_manager_wait_for_runtime_supervisor_health() {
  local health_socket="$1"
  local health_probe="$2"
  local health_deadline=$((SECONDS + 30))

  until "$health_probe" \
    -addr="unix://${health_socket}" \
    -connect-timeout=1s \
    -rpc-timeout=1s >/dev/null 2>&1; do
    if (( SECONDS >= health_deadline )); then
      echo "ERROR: runtime-supervisor did not become healthy within 30s" >&2
      return 1
    fi
    sleep 0.1
  done
}

node_manager_activate_runtime_supervisor() {
  local restart_required="$1"
  local work_gate="$2"
  local health_socket="$3"
  local health_probe="$4"

  RUNTIME_SUPERVISOR_ACTION=none
  if [[ ! -e "$restart_required" ]]; then
    log_init "runtime-supervisor has no staged replacement"
    return
  fi

  # The predecessor has released the node-manager service mutex before this
  # function runs. Prefer a quiet instant, but never close writer admission or
  # fail because a long transition outlives this courtesy wait.
  exec 10>"$work_gate"
  if ! flock -w 5 10; then
    log_init "runtime-supervisor restart proceeding with sandbox-manager writers in flight"
  fi
  RUNTIME_SUPERVISOR_ACTION=restart
  nsenter --target 1 --mount --uts --ipc --net --pid -- systemctl restart space-runtime-supervisor.service
  exec 10>&-

  node_manager_wait_for_runtime_supervisor_health "$health_socket" "$health_probe"
  rm -f "$restart_required"
  log_init "runtime-supervisor staged replacement activated"
}

node_manager_ensure_runtime_supervisor() {
  local was_active="$1"
  local restart_required="$2"
  local work_gate="$3"
  local health_socket="$4"
  local health_probe="$5"

  RUNTIME_SUPERVISOR_ACTION=none
  if [[ "$was_active" != "true" ]]; then
    RUNTIME_SUPERVISOR_ACTION=enable-now
    nsenter --target 1 --mount --uts --ipc --net --pid -- systemctl enable --now space-runtime-supervisor.service
    if ! nsenter --target 1 --mount --uts --ipc --net --pid -- systemctl is-active --quiet space-runtime-supervisor.service; then
      RUNTIME_SUPERVISOR_ACTION=enable-now-start
      nsenter --target 1 --mount --uts --ipc --net --pid -- systemctl start space-runtime-supervisor.service
    fi
  elif [[ -e "$restart_required" ]]; then
    nsenter --target 1 --mount --uts --ipc --net --pid -- systemctl enable space-runtime-supervisor.service
    RUNTIME_SUPERVISOR_ACTION=deferred
    log_init "runtime-supervisor restart deferred to successor node-manager activation"
  else
    log_init "runtime-supervisor already active; leaving running"
  fi

  node_manager_wait_for_runtime_supervisor_health "$health_socket" "$health_probe"
  if [[ "$RUNTIME_SUPERVISOR_ACTION" != "deferred" ]]; then
    rm -f "$restart_required"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  log_init() {
    echo "node-manager-runtime-supervisor: $*"
  }

  case "${1:-}" in
    activate)
      shift
      if [[ "$#" -ne 4 ]]; then
        echo "usage: $0 activate RESTART_REQUIRED WORK_GATE HEALTH_SOCKET HEALTH_PROBE" >&2
        exit 2
      fi
      node_manager_activate_runtime_supervisor "$@"
      ;;
    *)
      echo "usage: $0 activate RESTART_REQUIRED WORK_GATE HEALTH_SOCKET HEALTH_PROBE" >&2
      exit 2
      ;;
  esac
fi
