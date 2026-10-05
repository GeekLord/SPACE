#!/usr/bin/env bash
# Checks that one add-on works, not merely that it's installed, on the cluster
# kubectl's current context points at. The scheduled workflow runs it once per
# add-on after an apply; run it the same way by hand, from this directory once
# `terraform init` has run (the PostgreSQL and Valkey checks read their names
# from this root's outputs):
#
#   ./verify.sh metrics-server   # the resource metrics API reports every Ready node
#   ./verify.sh postgresql       # a password login through the Service runs a query
#   ./verify.sh valkey           # an authenticated PING through the Service answers,
#                                # and an unauthenticated one is refused
#
# Each check retries until VERIFY_TIMEOUT seconds (default 300) have passed.
# The deadline is checked between attempts, so the last one can run past it:
# by the 10-second pause plus its kubectl calls (at most three, each capped at
# 30 seconds where coreutils `timeout` exists, as on the CI runners), rather
# than hanging the job on a stalled call.
set -euo pipefail

usage() {
  echo "usage: $0 metrics-server|postgresql|valkey" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
addon="$1"
case "${addon}" in
  metrics-server | postgresql | valkey) ;;
  *) usage ;;
esac
timeout="${VERIFY_TIMEOUT:-300}"
# No leading zeros: bash arithmetic would read them as octal.
if [[ ! "${timeout}" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "VERIFY_TIMEOUT must be a whole number of seconds, not '${timeout}'" >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --request-timeout bounds ordinary requests but not an exec stream once it's
# open; `timeout` bounds both. The execs' clients carry their own connect
# timeouts too.
if command -v timeout >/dev/null; then
  kubectl() { timeout 30 kubectl --request-timeout=20s "$@"; }
else
  kubectl() { command kubectl --request-timeout=20s "$@"; }
fi

# Read once, before retrying: the names don't change while the checks run. A
# missing one (no state, or an apply that failed before recording it) fails at
# once rather than being retried under the name "null".
read_outputs() {
  outputs="$(terraform -chdir="${root}" output -json)"
}
output() {
  if ! jq -er "$1 // empty" <<<"${outputs}"; then
    echo "::error::No '$1' in ${root}'s outputs: run terraform init, and apply this root, first" >&2
    exit 1
  fi
}

# Runs the named check until it passes or the deadline does. A failed attempt
# prints why, so the last reason is what a timed-out run reports.
retry() {
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    if ((SECONDS >= deadline)); then
      echo "::error::${addon} check failed after ${timeout} seconds" >&2
      return 1
    fi
    sleep 10
  done
}

check_metrics_server() {
  local ready reported missing
  ready="$(kubectl get nodes -o json |
    jq -c '[.items[] | select(any(.status.conditions // [] | .[]; .type == "Ready" and .status == "True")) | .metadata.name]')" || return 1
  if ! reported="$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | jq -c '[.items[].metadata.name]')"; then
    echo "metrics-server: the metrics API isn't serving yet" >&2
    return 1
  fi
  # By name, not count: metrics for a NotReady node that's leaving mustn't
  # stand in for a Ready one that has none yet.
  missing="$(jq -nr --argjson ready "${ready}" --argjson reported "${reported}" '$ready - $reported | join(" ")')"
  if [[ "${ready}" == "[]" || -n "${missing}" ]]; then
    echo "metrics-server: no metrics yet for Ready nodes: ${missing:-none are Ready}" >&2
    return 1
  fi
  kubectl top nodes || return 1
  echo "metrics-server: metrics for every Ready node ($(jq length <<<"${ready}"))"
}

check_postgresql() {
  local phase result
  phase="$(kubectl get pvc "data-${name}-0" -n "${namespace}" -o jsonpath='{.status.phase}')" || return 1
  if [[ "${phase}" != "Bound" ]]; then
    echo "postgresql: volume claim is ${phase:-missing}, not Bound" >&2
    return 1
  fi
  # Over TCP to the Service with the Secret's password, the path a client in
  # the cluster takes, rather than the pod's local socket, which skips both.
  # The variables expand in the container, from the Secret.
  # shellcheck disable=SC2016
  if ! result="$(kubectl exec -n "${namespace}" "statefulset/${name}" -c postgres -- \
    sh -c 'PGPASSWORD="${POSTGRES_PASSWORD}" PGCONNECT_TIMEOUT=10 psql -h "$1" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "select version()"' sh "${host}")"; then
    echo "postgresql: query through ${host} failed" >&2
    return 1
  fi
  echo "postgresql: ${result}"
}

check_valkey() {
  local pong refused
  if ! pong="$(kubectl exec -n "${namespace}" "deployment/${name}" -c valkey -- valkey-cli -t 10 -h "${host}" ping)" ||
    [[ "${pong}" != "PONG" ]]; then
    echo "valkey: PING through ${host} answered '${pong:-nothing}'" >&2
    return 1
  fi
  # valkey-cli prints a server error on stdout and still exits 0. Stdout only,
  # so a warning from kubectl can't stand in front of the answer.
  refused="$(kubectl exec -n "${namespace}" "deployment/${name}" -c valkey -- \
    env -u VALKEYCLI_AUTH valkey-cli -t 10 -h "${host}" ping 2>/dev/null)" || true
  # An answer is an open server, and no retry fixes that. Anything else
  # but a refusal (a restarting pod, a dropped exec) is worth another try.
  if [[ "${refused}" == "PONG" ]]; then
    echo "::error::valkey: an unauthenticated PING answered PONG" >&2
    exit 1
  fi
  if [[ "${refused}" != NOAUTH* ]]; then
    echo "valkey: unauthenticated PING answered '${refused}', not a refusal" >&2
    return 1
  fi
  echo "valkey: authenticated PING through ${host} answered PONG; unauthenticated refused"
}

# The checks read `name` and `host`, resolved here rather than inside them:
# errexit doesn't apply within the retry loop's condition.
case "${addon}" in
  metrics-server) retry check_metrics_server ;;
  postgresql | valkey)
    read_outputs
    namespace="$(output .namespace.value)"
    name="$(output ".${addon}.value.name")"
    host="$(output ".${addon}.value.host")"
    retry "check_${addon}"
    ;;
esac
