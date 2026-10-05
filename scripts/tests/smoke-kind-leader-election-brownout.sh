#!/usr/bin/env bash
#
# Leader-election brownout smoke for the local KinD SPACE stack.
#
# Every other assertion about the cluster-controller's leader election is a unit
# test against a fake lease store. That covers the state machine and none of the
# environment: whether a real apiserver's 403 arrives as the category the policy
# expects, whether kubelet's readiness probe actually observes the marker
# clearing, whether a holder that loses the apiserver resigns before its Lease
# can expire, and whether a replica that spends its liveness budget is genuinely
# restarted by kubelet rather than merely returning a value nobody acts on. Those
# only exist against a live control plane.
#
# What is asserted, in order:
#
#   1. Two replicas, one leader. The `coordination.k8s.io` Lease names one of the
#      two pods, exactly one pod reports winning it, and exactly one pod starts
#      the reconciler set. The last is the safety property the whole mechanism
#      exists for: two concurrent reconciler runners double-drive every CAS loop.
#
#   2. A refused lease call is not a restart. A third contender runs the same
#      image with the `space-api` ServiceAccount, which carries the substrate's
#      pod and node RBAC but no `leases` grant — so its substrate builds and
#      every lease call is a 403. It must be NotReady, report the refusal on
#      sight, and *not* restart for twice its liveness budget, while the two
#      healthy replicas keep their leader. This is the behaviour a naive
#      consecutive-failure budget gets wrong: it crash-loops against a
#      misconfiguration no restart can fix, adding a re-LIST of every Node to
#      each attempt. The NotReady half is an outcome check only — see the note at
#      that assertion for why it cannot evidence the clearing path.
#
#   3. An apiserver outage. The control-plane apiserver's static-pod manifest is
#      moved aside, so every replica loses the Lease at once. The holder must
#      resign inside the lease TTL (a standby may take over after it, and the
#      whole cooperative-exclusion argument rests on the holder stopping first),
#      the readiness marker must disappear from a container that demonstrably had
#      one before the outage, and a replica must spend its liveness budget and be
#      restarted by kubelet. After the manifest is restored, exactly one leader
#      and exactly one reconciler runner must come back.
#
# Why the logs are read off the node rather than through kubectl:
#   Scenario 3 takes the apiserver away, so `kubectl logs` is unavailable for the
#   whole window that matters, and the pods restart inside it — which rotates
#   `--previous` past the evidence. kubelet writes each container generation to
#   `/var/log/pods/<ns>_<pod>_<uid>/<container>/N.log` on the node, so the suite
#   reads those through `docker exec`. The pod-to-UID and pod-to-node mapping is
#   captured *before* the outage, while the apiserver can still answer.
#
#   Node-side logs are more durable than `--previous`, but they are NOT a
#   complete history, and the first version of this suite assumed they were.
#   kubelet's container GC keeps only `MaxPerPodContainer` dead containers per
#   container (1 by default), and removing a dead container removes its log file.
#   A run that restarts twice therefore loses generation 0 — which is exactly the
#   generation holding the holder's resignation. So anything that happens to the
#   *first* generation has to be observed while the outage is in progress, not
#   reconstructed afterwards. That is why the resignation assertion polls during
#   the outage instead of reading back at the end.
#
# What this suite does not cover:
#   * The `overloaded` category (429/5xx). Nothing in kind sheds load on demand,
#     and forging a 429 would mean standing up a proxy in front of the apiserver
#     — a different harness, and one whose fidelity claim would be about the
#     proxy. The category's *policy* is unit-tested; its classification is a
#     status-code table.
#   * A partial wedge that spares the substrate but breaks only the lease path's
#     transport. The two share one `kube::Client`, so there is no injection that
#     separates them, and scenario 3's cluster-wide outage is the closest
#     available approximation.
#
#     Observed while building this, because it is the opposite of what `main.rs`'s
#     comment about the substrate reads like: a replica restarted *during* the
#     outage does NOT die at substrate init. `Substrate::from_env` returns before
#     its reflectors have listed anything, so the initial-list failures arrive as
#     `watcher error` warnings on a retrying background task and the process goes
#     on to contend normally. That is why a replica restarted 9s into the outage
#     still spent a full liveness budget and exited on it. Do not write an
#     assertion that depends on the other behaviour.
#
# Env knobs:
#   KIND_CONTEXT        kube context (default kind-space-local)
#   NAMESPACE           SPACE namespace (default space)
#   DEPLOYMENT          controller Deployment (default space-cluster-controller)
#   READY_TIMEOUT       seconds to wait for replicas to go Ready (default 180)
#   SKIP_APISERVER_OUTAGE  set to 1 to run scenarios 1-2 only
#   SKIP_BOOTSTRAP      accepted for symmetry with the sibling suites and
#                       ignored: this suite requires a running stack.
set -Eeuo pipefail

# Opt-in. Scenario 3 waits out a liveness budget with the apiserver down, which
# is upwards of two minutes of deliberate control-plane downtime — too slow and
# too invasive for the per-merge set.
if [[ "${SPACE_SMOKE_LEADER_ELECTION:-0}" != "1" ]]; then
  echo "SKIPPED: smoke-kind-leader-election-brownout is opt-in and takes several minutes."
  echo "         Set SPACE_SMOKE_LEADER_ELECTION=1 to run it."
  exit 0
fi

KIND_CONTEXT="${KIND_CONTEXT:-kind-space-local}"
NAMESPACE="${NAMESPACE:-space}"
DEPLOYMENT="${DEPLOYMENT:-space-cluster-controller}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
SKIP_APISERVER_OUTAGE="${SKIP_APISERVER_OUTAGE:-0}"

CONTAINER="cluster-controller"
LEASE_NAME="cluster-controller"
WEDGED_DEPLOYMENT="${DEPLOYMENT}-wedged"
# The ServiceAccount that has the substrate's RBAC and no `leases` grant. Both
# the api-server and the cluster-controller build the same read-only substrate,
# so this is the one identity in the namespace that can do everything the
# controller needs *except* participate in the election.
WEDGED_SERVICE_ACCOUNT="space-api"
# The contender gets its own `app.kubernetes.io/name` rather than only an extra
# label. Sharing the healthy Deployment's selector labels would make two
# Deployments' selectors overlap, which is a configuration kubectl warns about
# and whose consequences depend on ownerReference races.
WEDGED_NAME_LABEL="space-cluster-controller-wedged"
HEALTHY_SELECTOR="app.kubernetes.io/name=space-cluster-controller"
WEDGED_SELECTOR="app.kubernetes.io/name=${WEDGED_NAME_LABEL}"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
APISERVER_PARKED="/etc/kubernetes/kube-apiserver.yaml.brownout"

# Log fragments this suite greps for. Named here so a rename in the source shows
# up as one edit rather than five, and so the assertions below read as prose.
LOG_WON="won cluster-controller leadership lease"
LOG_RESIGNED="resigning cluster-controller leadership"
LOG_RECONCILERS="resolved node-census residency evidence"
LOG_TIMINGS="contending for cluster-controller leadership with resolved lease timings"
LOG_BUDGET_SPENT="whole liveness budget"
LOG_UNFIXABLE="leader-election lease failure needs an operator"

for bin in kubectl docker python3 jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $bin" >&2
    exit 1
  }
done

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
  echo "FAIL: $*" >&2
  exit 1
}

k() { kubectl "$@" -n "$NAMESPACE" --context "$KIND_CONTEXT"; }

# ---------------------------------------------------------------------------
# Teardown. Registered before the first mutation so an interrupt anywhere below
# still restores the apiserver and removes the wedged contender. Every step is
# idempotent and none of them may fail the trap, or a failure in one would hide
# the rest — including putting the apiserver back.
# ---------------------------------------------------------------------------
ORIGINAL_REPLICAS=""
CONTROL_PLANE_NODE=""
APISERVER_PARKED_NOW=0

cleanup() {
  local rc=$?
  set +e
  if [[ "$APISERVER_PARKED_NOW" == "1" && -n "$CONTROL_PLANE_NODE" ]]; then
    log "cleanup: restoring the apiserver manifest"
    restore_apiserver
  fi
  if [[ -n "$WEDGED_DEPLOYMENT" ]]; then
    k delete deployment "$WEDGED_DEPLOYMENT" --ignore-not-found --wait=false >/dev/null 2>&1
  fi
  if [[ -n "$ORIGINAL_REPLICAS" ]]; then
    log "cleanup: scaling $DEPLOYMENT back to $ORIGINAL_REPLICAS"
    k scale deployment "$DEPLOYMENT" --replicas="$ORIGINAL_REPLICAS" >/dev/null 2>&1
  fi
  exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Pod names matching a label selector, one per line, sorted so callers can
# compare sets. Selected by label rather than by owner: the contender's
# ReplicaSet name also starts with the main Deployment's name, so a name-prefix
# match would fold the contender into the healthy set and make every
# "exactly one" assertion below unfailable.
pods_matching() {
  k get pods -l "$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
    grep -v '^$' | sort
}

# The two replicas under test, excluding the deliberately-wedged contender.
healthy_pods() { pods_matching "$HEALTHY_SELECTOR"; }

# Read a pod's controller-container logs off the node. `which` is `all` for every
# generation concatenated oldest-first, or `current` for only the newest.
#
# Both callers need the same directory and the same guard, so the path is built
# once here. `ls -v` orders 0.log, 1.log, 10.log numerically, so generations stay
# in order past the tenth restart. A missing directory is not an error: it means
# the pod never started on this node, which the caller's assertion is better
# placed to report than a raw `cat` failure.
#
# Requires the pod's node and UID to have been captured while the apiserver was
# answering; see POD_NODE / POD_UID.
node_log_read() {
  local pod="$1" which="$2" node="${POD_NODE[$1]:-}" uid="${POD_UID[$1]:-}"
  [[ -n "$node" && -n "$uid" ]] || die "no captured node/uid for pod $pod"
  local pick='for f in $(ls -v "$d"); do cat "$d/$f"; done'
  if [[ "$which" == "current" ]]; then
    pick='cat "$d/$(ls -v "$d" | tail -1)"'
  fi
  docker exec "$node" sh -c \
    "d=/var/log/pods/${NAMESPACE}_${pod}_${uid}/${CONTAINER}; [ -d \"\$d\" ] && $pick" \
    2>/dev/null || true
}

# Every generation, concatenated oldest first.
node_log() { node_log_read "$1" all; }

# Only the newest generation — i.e. what the *currently running* process has said.
# Used wherever the assertion is about the live process rather than the pod's
# history: "logged once per process" lines like winning the lease or starting the
# reconcilers mean nothing summed across generations, and an earlier generation of
# a surviving pod carries whatever a previous run of this suite provoked.
node_log_current() { node_log_read "$1" current; }

# Lines on stdin containing `pattern` whose kubelet timestamp is at or after the
# given epoch. This is what keeps a previous run's evidence out of this run's
# assertions — the failure that motivated it ended an outage after four seconds
# because a surviving pod's older generation already held the line being waited
# for. Scoping by timestamp rather than by generation is deliberate: the
# scenario-3 evidence legitimately lives in a *previous* generation of a pod that
# has since restarted, so "current generation only" would discard it.
# One program, two modes, because the two things this suite needs from a log are
# the same parse: `lines` emits every matching line at or after `since`, and
# `last-epoch` emits the kubelet timestamp of the last such line. They were
# separate programs whose bodies were identical but for the final statement, and
# the one call site that wanted an epoch *chained* them — parsing the same log
# twice, in two interpreters, on every iteration of a poll that runs while the
# apiserver is down.
#
# The `since` filter is what keeps a previous run's evidence out of this run's
# assertions: the failure that motivated it ended an outage after four seconds
# because a surviving pod's older generation already held the line being waited
# for. Filtering by timestamp rather than by generation is deliberate — the
# scenario-3 evidence legitimately lives in a *previous* generation of a pod that
# has since restarted, so "current generation only" would discard it.
#
# The timestamp read is kubelet's, not the application's. Every line in a CRI log
# file is prefixed `<RFC3339> <stream> <F|P> <content>`, which makes this
# independent of whether the service logs text or JSON. It measures when kubelet
# saw the line rather than when the process emitted it; the two differ by
# buffering, which is orders of magnitude below the windows asserted here.
#
# Passed with `-c` rather than on stdin, because stdin is the log.
LOG_SCAN_PY='
import datetime, re, sys
pattern, since, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
stamp = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)")
last = None
for line in sys.stdin:
    if pattern not in line:
        continue
    m = stamp.match(line)
    if not m:
        continue
    try:
        parsed = datetime.datetime.fromisoformat(m.group(1))
    except ValueError:
        continue
    epoch = int(parsed.replace(tzinfo=datetime.timezone.utc).timestamp())
    if epoch < since:
        continue
    if mode == "lines":
        sys.stdout.write(line)
    else:
        last = epoch
if mode == "last-epoch" and last is not None:
    print(last)
'

# Matching lines stamped at or after `since`.
log_since() { python3 -c "$LOG_SCAN_PY" "$1" "$2" lines; }

# Epoch of the LAST matching line stamped at or after `since`, or nothing when
# there is none — so callers test for emptiness rather than trusting a 0. Last,
# not first: these logs span every container generation, and an event from before
# the window under test would otherwise be the one measured.
log_epoch_since() { python3 -c "$LOG_SCAN_PY" "$1" "$2" last-epoch; }

lease_holder() {
  k get lease "$LEASE_NAME" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true
}

restart_count() {
  k get pod "$1" -o jsonpath="{.status.containerStatuses[?(@.name=='$CONTAINER')].restartCount}" 2>/dev/null || true
}

pod_ready() {
  [[ "$(k get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

# Wait until the named Deployment reports `want` ready replicas.
wait_ready_replicas() {
  local deployment="$1" want="$2" deadline=$((SECONDS + READY_TIMEOUT)) have
  while ((SECONDS < deadline)); do
    have="$(k get deployment "$deployment" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    [[ "${have:-0}" == "$want" ]] && return 0
    sleep 2
  done
  k get pods -l "app.kubernetes.io/name=space-cluster-controller" -o wide || true
  die "$deployment did not reach $want ready replicas within ${READY_TIMEOUT}s"
}

apiserver_answers() {
  k get --raw /healthz >/dev/null 2>&1
}

restore_apiserver() {
  # `|| true`: already-restored is the expected case on the second call (main
  # flow, then the EXIT trap), and a non-zero return there would abort the
  # caller mid-cleanup.
  docker exec "$CONTROL_PLANE_NODE" sh -c \
    "[ -f $APISERVER_PARKED ] && mv $APISERVER_PARKED $APISERVER_MANIFEST" >/dev/null 2>&1 || true
  APISERVER_PARKED_NOW=0
}

# Value of a numeric tracing field on stdin, truncated to whole seconds. Handles
# both formatter shapes — `"key":12.5` when the service logs JSON (which it does
# in this stack) and `key=12.5` when it logs text — because which one is active
# is a subscriber setting this suite has no business depending on.
LOG_FIELD_PY='
import re, sys
key = re.escape(sys.argv[1])
text = sys.stdin.read()
m = re.search(rf"\"{key}\"\s*:\s*([0-9]+(?:\.[0-9]+)?)", text) or \
    re.search(rf"\b{key}=([0-9]+(?:\.[0-9]+)?)", text)
if m:
    print(int(float(m.group(1))))
'
log_field() { python3 -c "$LOG_FIELD_PY" "$1"; }

count_matching() { grep -c -- "$1" || true; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
log "preflight: checking the stack"
apiserver_answers || die "apiserver at context $KIND_CONTEXT is not answering"
k get deployment "$DEPLOYMENT" >/dev/null 2>&1 || die "no $DEPLOYMENT in namespace $NAMESPACE"

# Kubernetes deployments always run leader election with a 60-second lease.
# The resolved value (`RESOLVED_TTL`, parsed from the pod's own log) is only
# available after scenario 1, while the holder wait below needs a bound first.
RESOLVED_TTL_HINT=60

ORIGINAL_REPLICAS="$(k get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
log "preflight: $DEPLOYMENT currently at $ORIGINAL_REPLICAS replica(s), election active"

# Captured here, not where it is used: scenario 3 needs it while the apiserver is
# down. Kubernetes readiness always uses this marker.
MARKER_PATH=/tmp/space-cluster-controller-ready

CONTROL_PLANE_NODE="$(k get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$CONTROL_PLANE_NODE" ]] || die "could not identify the control-plane node"
docker inspect "$CONTROL_PLANE_NODE" >/dev/null 2>&1 ||
  die "control-plane node $CONTROL_PLANE_NODE is not a local docker container; this suite is kind-only"

# ---------------------------------------------------------------------------
# Scenario 1 — two replicas, exactly one leader, exactly one reconciler runner
# ---------------------------------------------------------------------------
log "scenario 1: scaling $DEPLOYMENT to 2 replicas"
k scale deployment "$DEPLOYMENT" --replicas=2 >/dev/null
wait_ready_replicas "$DEPLOYMENT" 2

# Name, node, uid and restart count for every replica in one query. Restart
# counts are recorded as a baseline rather than asserted to be zero: a pod that
# survives an earlier run of this suite legitimately carries restarts, and a
# suite that only passes on a pristine stack is one nobody re-runs.
declare -A POD_NODE=()
declare -A POD_UID=()
declare -A POD_RESTARTS_AT_START=()
CC_PODS=()
while read -r pod node uid restarts; do
  [[ -n "$pod" && -n "$node" && -n "$uid" ]] || continue
  CC_PODS+=("$pod")
  POD_NODE["$pod"]="$node"
  POD_UID["$pod"]="$uid"
  POD_RESTARTS_AT_START["$pod"]="${restarts:-0}"
  log "scenario 1: $pod on $node (restarts so far: ${restarts:-0})"
done < <(k get pods -l "$HEALTHY_SELECTOR" -o jsonpath="{range .items[*]}\
{.metadata.name}{\" \"}{.spec.nodeName}{\" \"}{.metadata.uid}{\" \"}\
{.status.containerStatuses[?(@.name=='$CONTAINER')].restartCount}{\"\n\"}{end}" | sort)
((${#CC_PODS[@]} == 2)) || die "expected 2 controller pods, found ${#CC_PODS[@]}: ${CC_PODS[*]}"

# Polled, not sampled. A `Lease` legitimately names a holder that no longer
# exists: a pod that dies without releasing leaves its `holderIdentity` in place
# until the TTL lapses and a live replica takes it over. So "the holder is not one
# of these pods" is the *expected* reading for up to one TTL after any pod
# replacement — including the rollout this suite's own preflight may have just
# caused. Sampling once made the suite fail against a stack that was converging
# normally.
log "scenario 1: waiting for a live replica to hold the lease (up to ${RESOLVED_TTL_HINT}s + margin)"
holder=""
deadline=$((SECONDS + RESOLVED_TTL_HINT + 60))
while ((SECONDS < deadline)); do
  holder="$(lease_holder)"
  if [[ -n "$holder" ]] && printf '%s\n' "${CC_PODS[@]}" | grep -qx -- "$holder"; then
    break
  fi
  sleep 3
done
[[ -n "$holder" ]] || die "no Lease/$LEASE_NAME holder at all after both replicas went Ready"
printf '%s\n' "${CC_PODS[@]}" | grep -qx -- "$holder" ||
  die "the lease is still held by '$holder', which is not one of the live controller pods (${CC_PODS[*]}), after $((RESOLVED_TTL_HINT + 60))s — a departed holder's lease should have lapsed by now"
log "scenario 1: lease held by $holder"

# One pass per pod. Everything below comes out of the same log text — an earlier
# version read each pod's log twice, once for the counts and again for the
# timings, which is a second full `docker exec` per replica for a line the first
# read already had.
#
# The resolved budget is the clamped value plus a per-identity spread of up to a
# quarter, so it cannot be read off the Deployment; the largest across the
# replicas is the bound that matters, because scenario 3 waits for *a* replica to
# spend its budget.
leaders=0
runners=0
RESOLVED_GRACE=0
RESOLVED_TTL=0
for pod in "${CC_PODS[@]}"; do
  text="$(node_log_current "$pod")"
  [[ -n "$text" ]] || die "no node-side log for $pod; the log path assumption is wrong"
  timings="$(grep -- "$LOG_TIMINGS" <<<"$text" | tail -1)"
  [[ -n "$timings" ]] ||
    die "$pod never logged its resolved lease timings; is this build older than the change under test?"

  won="$(count_matching "$LOG_WON" <<<"$text")"
  ran="$(count_matching "$LOG_RECONCILERS" <<<"$text")"
  # `if` rather than `((x += ...))` as a statement: an arithmetic command whose
  # result is 0 exits 1, so incrementing by zero under `set -e` kills the script
  # silently. Assignment through `$(( ))` has no such status.
  if ((won > 0)); then leaders=$((leaders + 1)); fi
  if ((ran > 0)); then runners=$((runners + 1)); fi

  grace="$(log_field "lease_failure_grace_secs" <<<"$timings")"
  ttl="$(log_field "lease_ttl_secs" <<<"$timings")"
  [[ -n "$grace" && -n "$ttl" ]] ||
    die "could not parse resolved timings out of $pod's log line: $timings"
  if ((grace > RESOLVED_GRACE)); then RESOLVED_GRACE="$grace"; fi
  if ((ttl > RESOLVED_TTL)); then RESOLVED_TTL="$ttl"; fi
done
((leaders == 1)) || die "expected exactly 1 pod to report winning the lease, got $leaders"
((runners == 1)) || die "expected exactly 1 pod to start the reconciler set, got $runners"
((RESOLVED_GRACE > 0)) ||
  die "the liveness budget resolved to 0 (kill-switched); this suite cannot assert a restart"
log "scenario 1: PASS — one leader, one reconciler runner; resolved grace ${RESOLVED_GRACE}s, TTL ${RESOLVED_TTL}s"

# ---------------------------------------------------------------------------
# Scenario 2 — a refused lease call is not a restart
# ---------------------------------------------------------------------------
log "scenario 2: starting a contender with no leases RBAC"

# Derived from the live Deployment rather than hand-written, so the wedged pod
# runs the same image and the same env as the replicas it is being compared
# against. Only the identity, name, and replica count change.
k get deployment "$DEPLOYMENT" -o json | jq \
  --arg name "$WEDGED_DEPLOYMENT" \
  --arg sa "$WEDGED_SERVICE_ACCOUNT" \
  --arg label "$WEDGED_NAME_LABEL" '
  .metadata = {name: $name, namespace: .metadata.namespace, labels: .metadata.labels}
  | .metadata.labels["app.kubernetes.io/name"] = $label
  | .spec.replicas = 1
  | .spec.strategy = {type: "Recreate"}
  | .spec.selector.matchLabels = {"app.kubernetes.io/name": $label}
  | .spec.template.metadata.labels["app.kubernetes.io/name"] = $label
  | .spec.template.spec.serviceAccountName = $sa
  | del(.status, .metadata.annotations, .metadata.resourceVersion, .metadata.uid,
        .metadata.creationTimestamp, .metadata.generation)
' | k apply -f - >/dev/null

wedged_pod=""
deadline=$((SECONDS + READY_TIMEOUT))
while ((SECONDS < deadline)); do
  wedged_pod="$(pods_matching "$WEDGED_SELECTOR" | head -1)"
  [[ -n "$wedged_pod" ]] && break
  sleep 2
done
[[ -n "$wedged_pod" ]] || die "the wedged contender never produced a pod"
POD_NODE["$wedged_pod"]="$(k get pod "$wedged_pod" -o jsonpath='{.spec.nodeName}')"
POD_UID["$wedged_pod"]="$(k get pod "$wedged_pod" -o jsonpath='{.metadata.uid}')"
log "scenario 2: contender $wedged_pod running as $WEDGED_SERVICE_ACCOUNT"

# It has to reach the lease path at all: if the substrate can't build with this
# ServiceAccount, the pod dies at init and proves nothing about refusals.
deadline=$((SECONDS + READY_TIMEOUT))
refusal_seen=0
wedged_text=""
while ((SECONDS < deadline)); do
  # Keep the text that satisfied the poll and assert on *that*, rather than
  # re-reading afterwards: a second read is another `docker exec`, and it is not
  # guaranteed to be the same bytes the poll matched.
  wedged_text="$(node_log_current "$wedged_pod")"
  if grep -q -- "$LOG_UNFIXABLE" <<<"$wedged_text"; then
    refusal_seen=1
    break
  fi
  sleep 3
done
((refusal_seen == 1)) || {
  echo "--- contender log tail ---" >&2
  tail -30 <<<"$wedged_text" >&2
  die "the contender never reported an unfixable lease refusal"
}
# Scoped to the on-sight line itself. Over the whole log, "refused" matches an
# unrelated `connection refused` from anything else in the container, so a
# regression that reported the wrong category — or dropped the field — would pass.
grep -- "$LOG_UNFIXABLE" <<<"$wedged_text" | grep -q "refused" ||
  die "the on-sight refusal line does not carry the 'refused' reason"
if grep -q -- "$LOG_RECONCILERS" <<<"$wedged_text"; then
  die "the contender started the reconciler set despite never holding the lease"
fi
log "scenario 2: contender reported the refusal on sight and ran no reconcilers"

# NotReady, because it cannot take over — but note what this can and cannot
# prove. The contender never has a successful lease call, so it never writes the
# marker in the first place: `test -f` fails from container start, and the pod
# would be NotReady even against a build that never clears the marker on failure.
# So this is a statement about the *outcome* (a refused replica is out of service,
# which is what `maxUnavailable: 0` depends on), not evidence that the clearing
# logic works.
#
# The transition — Ready, then a refusal, then NotReady — needs a presence to
# remove, and it is covered where a presence can be arranged: the unit tests
# `a_refused_lease_call_still_clears_readiness` and
# `a_resigning_holder_stops_reporting_ready`, both of which wait for the marker to
# appear before asserting it goes. Scenario 3 covers it against a live cluster by
# recording the marker as present before the outage. Do not restate this check as
# proof of the clearing path.
if pod_ready "$wedged_pod"; then die "the contender is Ready despite being refused the lease"; fi

# The policy: no restart, for twice the budget. A consecutive-failure budget
# that charged refusals would have exited at one budget.
wait_for=$((RESOLVED_GRACE * 2))
log "scenario 2: watching for ${wait_for}s (2x the budget) — the contender must not restart"
deadline=$((SECONDS + wait_for))
while ((SECONDS < deadline)); do
  restarts="$(restart_count "$wedged_pod")"
  [[ "${restarts:-0}" == "0" ]] ||
    die "the contender restarted ($restarts) on a refusal a restart cannot fix"
  sleep 5
done
if grep -q -- "$LOG_BUDGET_SPENT" <<<"$(node_log_current "$wedged_pod")"; then
  die "a refusal spent the liveness budget"
fi

# ...and the healthy replicas were undisturbed throughout.
# Sampled once. Calling `lease_holder` again inside the message would print a
# *different* sample than the one that failed the comparison.
holder_now="$(lease_holder)"
[[ "$holder_now" == "$holder" ]] ||
  die "the leader changed from $holder to $holder_now while a third contender was refused"
for pod in "${CC_PODS[@]}"; do
  pod_ready "$pod" || die "$pod went NotReady while an unrelated contender was refused"
  now="$(restart_count "$pod")"
  [[ "${now:-0}" == "${POD_RESTARTS_AT_START[$pod]:-0}" ]] ||
    die "$pod restarted (${POD_RESTARTS_AT_START[$pod]:-0} -> ${now:-0}) while an unrelated contender was refused"
done
log "scenario 2: PASS — refused, NotReady, no restart, leader undisturbed"

k delete deployment "$WEDGED_DEPLOYMENT" --ignore-not-found --wait=false >/dev/null
WEDGED_DEPLOYMENT=""

# ---------------------------------------------------------------------------
# Scenario 3 — apiserver outage
# ---------------------------------------------------------------------------
if [[ "$SKIP_APISERVER_OUTAGE" == "1" ]]; then
  log "scenario 3: SKIPPED (SKIP_APISERVER_OUTAGE=1)"
  log "ALL RUN SCENARIOS PASSED"
  exit 0
fi

# Snapshot again rather than reusing scenario 1's: scenario 2 asserted no change,
# but re-reading keeps this scenario's own assertion honest if that ever loosens.
pre_restarts=()
for pod in "${CC_PODS[@]}"; do
  pre_restarts+=("$(restart_count "$pod")")
done
holder_before="$(lease_holder)"

# Record, per container, that the marker is present *now* — while the apiserver
# is still up and the replicas are Ready. The mid-outage check below only accepts
# absence on one of these ids, which is what turns it from "some container has no
# marker" into "a container that had one lost it".
MARKER_PRESENT_IDS=()
for pod in "${CC_PODS[@]}"; do
  node="${POD_NODE[$pod]}"
  # `crictl ps` filtered by the pod's own label, not by container name: every
  # controller container in this namespace shares the name `cluster-controller`.
  ids="$(docker exec "$node" crictl ps --label "io.kubernetes.pod.name=$pod" \
    --name "$CONTAINER" -q 2>/dev/null || true)"
  for id in $ids; do
    if docker exec "$node" crictl exec "$id" test -f "$MARKER_PATH" >/dev/null 2>&1; then
      MARKER_PRESENT_IDS+=("$node:$id")
      log "scenario 3: $pod has its readiness marker before the outage"
    fi
  done
done
((${#MARKER_PRESENT_IDS[@]} >= 1)) ||
  die "no controller container has a readiness marker before the outage, so its removal cannot be observed"

log "scenario 3: parking the apiserver manifest on $CONTROL_PLANE_NODE"
docker exec "$CONTROL_PLANE_NODE" mv "$APISERVER_MANIFEST" "$APISERVER_PARKED"
APISERVER_PARKED_NOW=1
OUTAGE_STARTED_AT="$(date -u +%s)"

# Confirm it is actually gone. Asserting on an outage that never happened is the
# failure mode this check exists for: kubelet takes a few seconds to notice the
# manifest is missing, and a suite that slept through that window would "prove"
# resilience against nothing.
deadline=$((SECONDS + 60))
while ((SECONDS < deadline)); do
  apiserver_answers || break
  sleep 2
done
if apiserver_answers; then die "the apiserver still answers after its manifest was parked"; fi
log "scenario 3: apiserver is down"

# Mid-outage, with no apiserver to ask: read the readiness marker straight out of
# the containers under test, through the node's CRI. This is the only point at
# which "readiness tracks lease reachability" is observable — after recovery the
# pods are Ready again and the window is gone. MARKER_PATH was captured in
# preflight, because reading it now would need the apiserver that is deliberately
# down.
#
# Two things make this a real assertion rather than a coincidence, and the first
# version of it had neither:
#
#   * The marker is confirmed *present* on a specific container id BEFORE the
#     outage (see MARKER_PRESENT_IDS, captured above). Without that, "test -f
#     fails" is satisfied by any container that never wrote a marker — including
#     a freshly restarted replica, which is guaranteed to appear during this
#     window because the liveness budget restarts one. Deleting the readiness
#     clearing entirely would still have passed.
#   * The scan is restricted to those recorded ids. `crictl ps --name` filters on
#     container *name*, and every controller container in this stack is named
#     `cluster-controller` — including scenario 2's contender, which is deleted
#     with `--wait=false` and never wrote a marker at all.
marker_cleared=0
deadline=$((SECONDS + 90))
while ((SECONDS < deadline)); do
  for entry in "${MARKER_PRESENT_IDS[@]}"; do
    node="${entry%%:*}"
    id="${entry#*:}"
    # A control probe first. `crictl exec` against a container that has since
    # exited also fails, and that failure says nothing about the marker.
    docker exec "$node" crictl exec "$id" test -d / >/dev/null 2>&1 || continue
    if ! docker exec "$node" crictl exec "$id" test -f "$MARKER_PATH" >/dev/null 2>&1; then
      marker_cleared=1
      break 2
    fi
  done
  sleep 3
done
((marker_cleared == 1)) ||
  die "no container that had a readiness marker before the outage cleared it during the outage"
log "scenario 3: readiness marker cleared on a container that demonstrably had one"

# The holder must stop acting before its Lease could expire — the cooperative
# exclusion contract, since a standby is entitled to take the Lease one TTL after
# the holder's last renewal, and a holder resigning later than that is a window
# with two reconciler runners.
#
# Polled here, mid-outage, rather than read back at the end: the resignation is
# written by the *first* container generation, and by the time this scenario
# finishes kubelet's container GC has usually removed that generation's log. The
# first version of this suite read it back afterwards and failed with "never
# logged a resignation" against a holder that had resigned in 8s.
log "scenario 3: watching for the holder to resign inside its ${RESOLVED_TTL}s lease TTL"
resign_epoch=""
deadline=$((SECONDS + RESOLVED_TTL + 30))
while ((SECONDS < deadline)); do
  resign_epoch="$(node_log "$holder_before" | log_epoch_since "$LOG_RESIGNED" "$OUTAGE_STARTED_AT")"
  [[ -n "$resign_epoch" ]] && break
  sleep 2
done
[[ -n "$resign_epoch" ]] || {
  echo "--- holder log tail ---" >&2
  node_log "$holder_before" | tail -30 >&2
  die "the holder $holder_before did not resign within $((RESOLVED_TTL + 30))s of losing the apiserver"
}
# No lower-bound guard here: `log_since` already dropped every line stamped
# before the outage began, so a pre-outage resignation cannot reach this
# subtraction. An earlier version checked `>= 0` as well, which could not fire.
resign_after=$((resign_epoch - OUTAGE_STARTED_AT))
((resign_after <= RESOLVED_TTL)) ||
  die "the holder resigned ${resign_after}s into the outage, past its ${RESOLVED_TTL}s lease TTL"
log "scenario 3: holder resigned ${resign_after}s into the outage (TTL ${RESOLVED_TTL}s)"

# Wait for a replica to spend its budget, rather than sleeping a fixed span. The
# margin over the resolved budget has to cover more than the retry cadence: a
# replica that restarts early in the outage restarts its own budget clock from
# scratch, so the exit can land a restart-delay later than the outage's own
# elapsed time.
budget_wait_started=$SECONDS
budget_wait_limit=$((RESOLVED_GRACE + 120))
log "scenario 3: waiting up to ${budget_wait_limit}s for a replica to spend its liveness budget"
budget_seen=0
while ((SECONDS - budget_wait_started < budget_wait_limit)); do
  for pod in "${CC_PODS[@]}"; do
    if [[ -n "$(node_log "$pod" | log_since "$LOG_BUDGET_SPENT" "$OUTAGE_STARTED_AT")" ]]; then
      budget_seen=1
      break 2
    fi
  done
  sleep 5
done
if ((budget_seen == 1)); then
  log "scenario 3: a replica spent its budget $((SECONDS - budget_wait_started))s into the wait"
else
  # Dump before restoring: the diagnostic is only readable while these
  # generations still exist, and recovery restarts the pods again.
  for pod in "${CC_PODS[@]}"; do
    echo "--- $pod log tail ---" >&2
    node_log "$pod" | tail -30 >&2
  done
fi

log "scenario 3: restoring the apiserver manifest"
restore_apiserver
deadline=$((SECONDS + READY_TIMEOUT))
while ((SECONDS < deadline)); do
  apiserver_answers && break
  sleep 3
done
apiserver_answers || die "the apiserver did not come back within ${READY_TIMEOUT}s"
log "scenario 3: apiserver is back"

# --- assertions on what the outage produced, read from the node-side logs ---

# A replica must have spent its budget and been restarted by kubelet. Both halves
# matter: the log line alone proves the decision, the restart count proves
# kubelet acted on the non-zero exit.
budget_spenders=0
for pod in "${CC_PODS[@]}"; do
  spent="$(node_log "$pod" | log_since "$LOG_BUDGET_SPENT" "$OUTAGE_STARTED_AT")"
  [[ -n "$spent" ]] || continue
  budget_spenders=$((budget_spenders + 1))
  grep -q "unreachable" <<<"$spent" ||
    die "$pod spent its budget without recording the 'unreachable' reason"
done
((budget_spenders >= 1)) ||
  die "no replica spent its liveness budget during the outage (budget was ${RESOLVED_GRACE}s)"

# Polled, not sampled once. The restart happened on the node, but this reads it
# back through the apiserver, which only learns about it when kubelet next
# reports pod status — and the apiserver came back seconds ago. Reading once here
# failed against a run whose replica had demonstrably already restarted.
restarted=0
deadline=$((SECONDS + 120))
while ((SECONDS < deadline)); do
  restarted=0
  for i in "${!CC_PODS[@]}"; do
    pod="${CC_PODS[$i]}"
    now="$(restart_count "$pod")"
    # A pod deleted and replaced during the outage reports no count; the log-side
    # assertion above already covers that case, so absence here is not a failure.
    [[ -n "$now" ]] || continue
    if ((now > ${pre_restarts[$i]})); then restarted=$((restarted + 1)); fi
  done
  ((restarted >= 1)) && break
  sleep 5
done
((restarted >= 1)) ||
  die "kubelet never reported a restart for any controller container, though a replica logged spending its budget"
log "scenario 3: $budget_spenders replica(s) spent the budget, $restarted restarted"

# --- and the cluster converged back to exactly one leader and one runner ---
#
# Polled on the invariant itself, not built out of separate waits. Recovery is
# eventually consistent in three places at once and every one of them will hand
# back a pre-outage answer if asked too early: the Deployment's `readyReplicas`
# is whatever kubelet last reported, the `Lease` still names the holder that
# resigned (with a stale `renewTime`), and a replica that has only just restarted
# has not reached the reconcilers yet. An earlier version of this waited on the
# first two and then asserted the third once — both waits returned immediately on
# stale state and it failed with "got 0" five seconds after the apiserver came
# back, against a cluster that converged fine moments later.
#
# The bound is generous because these replicas have restarted more than once, so
# kubelet's crash-loop backoff is in play.
log "scenario 3: waiting for the cluster to converge back to one leader and one reconciler runner"
converge_deadline=$((SECONDS + 300))
holder_after=""
runners_after=0
while ((SECONDS < converge_deadline)); do
  # Name, node and uid in one query rather than three per pod. This loop runs
  # every 5s for up to five minutes against a control plane that has just come
  # back and is itself the thing under observation, so the round-trip count is
  # worth minding: the per-pod form made five calls an iteration where this makes
  # two.
  CC_PODS_AFTER=()
  runners_after=0
  while read -r pod node uid; do
    [[ -n "$pod" && -n "$node" && -n "$uid" ]] || continue
    CC_PODS_AFTER+=("$pod")
    # Current generation only: an earlier generation of this pod legitimately ran
    # the reconcilers before the outage, and counting it would make the
    # single-runner assertion unfailable. Recovery can also have produced pods
    # that did not exist before it, hence refreshing the mapping here.
    POD_NODE["$pod"]="$node"
    POD_UID["$pod"]="$uid"
    if grep -q -- "$LOG_RECONCILERS" <<<"$(node_log_current "$pod")"; then
      runners_after=$((runners_after + 1))
    fi
  done < <(k get pods -l "$HEALTHY_SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{" "}{.metadata.uid}{"\n"}{end}' \
    2>/dev/null || true)

  holder_after="$(lease_holder)"
  if ((runners_after == 1)) && [[ -n "$holder_after" ]] &&
    printf '%s\n' "${CC_PODS_AFTER[@]}" | grep -qx -- "$holder_after"; then
    break
  fi
  sleep 5
done

[[ -n "$holder_after" ]] || die "no Lease holder after the apiserver came back"
printf '%s\n' "${CC_PODS_AFTER[@]}" | grep -qx -- "$holder_after" ||
  die "post-recovery holder '$holder_after' is not a live controller pod: ${CC_PODS_AFTER[*]}"
((runners_after == 1)) ||
  die "expected exactly 1 reconciler runner after recovery, got $runners_after"

# Only now is `readyReplicas` worth reading: the runner assertion above already
# proves a replica got through the lease path, so a stale status can no longer
# make this pass for the wrong reason.
wait_ready_replicas "$DEPLOYMENT" 2
log "scenario 3: PASS — one leader ($holder_after), one reconciler runner, both replicas Ready"

log "ALL SCENARIOS PASSED"
