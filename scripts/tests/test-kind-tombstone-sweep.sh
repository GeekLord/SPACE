#!/usr/bin/env bash
# A drain on the kind bench runs to termination, which deletes the kube Node and
# writes a `node_k8s_tombstones` row; restarting that worker's kubelet brings
# only the kube half back. The leftover row makes placement refuse that node
# forever, so the next create that lands there fails with `409 … is tombstoned`
# — in whichever suite runs next on a shared devbox.
#
# The properties that keep that fixed without weakening the production
# gate, exercised here against the real functions with kubectl and psql stubbed:
#
#   1. The sweep deletes a tombstone whose kube Node is back, and only that one.
#      A node that is genuinely gone keeps its tombstone, which is the gate
#      doing its job.
#   2. The sweep runs under SKIP_BOOTSTRAP=1. That is the mode every devbox run
#      uses once the stack is up, and therefore the only mode in which a
#      previous run's residue is ever encountered.
#   4. A query it cannot run is not an empty result, and a kube API it cannot
#      list is not a cluster without nodes: the sweep fails rather than
#      reporting a clean stack it never actually read.
#   5. A bound statement is fed on stdin, because psql ignores `:'var'` in `-c`.
#   6. The live-cluster mount check runs under SKIP_BOOTSTRAP=1 too. It answers
#      the same question the sweep does — is this cluster carrying a previous
#      run's residue — so it has to run in the mode where that residue is met.
#   7. …and it stands down, rather than failing the suite, when there is no
#      cluster to compare against. That mode read $HOME nowhere before this
#      check existed, and a root-owned ~/.space-devbox is a documented shape.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
stack_lib="${repo_root}/scripts/tests/lib/bootstrap-kind-stack.sh"

status=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@" >&2
    status=1
}

# Match a pattern against a string without a pipeline. `printf … | grep -q` is a
# race under `set -o pipefail`: grep -q exits at the first match, printf then dies
# of SIGPIPE, and pipefail reports the pipeline as failed — so a property that
# holds intermittently reads as broken. Here-strings have no such stage.
has_match() { # has_match <pattern> <string> [extra grep flags]
    local pattern="$1" subject="$2"
    shift 2
    grep -q "$@" -e "$pattern" <<<"$subject"
}

PRESENT_ID="11111111-1111-1111-1111-111111111111"
GONE_ID="22222222-2222-2222-2222-222222222222"

# The sweep sends its DELETE to /dev/null, so the stub records statements in a
# file rather than on stdout.
statements="$(mktemp)"
trap 'rm -f "$statements"' EXIT

# Property 1 + 2 run in subshells so the stubs cannot leak between them.
sweep_output="$(
    set -euo pipefail
    # Read by the sourced functions, not by this block.
    # shellcheck disable=SC2034
    KIND_CLUSTER="guard-test"
    # shellcheck source=lib/bootstrap-kind-stack.sh
    source "$stack_lib"

    # Only `present-node` is still in kube. `if` rather than `case`: a case
    # pattern's `)` confuses bash 3.2's parser inside a command substitution.
    kubectl() {
        if [[ "$*" == *"get secret space-postgres"* ]]; then
            printf 'spaceuser spacedb\n'
            return 0
        fi
        if [[ "$*" == *"get nodes"* ]]; then
            printf 'node/present-node\n'
            return 0
        fi
        return 1
    }
    kind_stack_psql() {
        if [[ "$*" == *SELECT* ]]; then
            printf '%s %s\n' "$PRESENT_ID" "present-node"
            printf '%s %s\n' "$GONE_ID" "gone-node"
            return 0
        fi
        {
            printf 'ARGS %s\n' "$*"
            printf 'STDIN '
            cat
        } >>"$statements"
    }
    kind_stack_sweep_stale_node_tombstones
)"

if ! grep -q "DELETE FROM node_k8s_tombstones" "$statements"; then
    fail "the sweep issued no DELETE for a tombstone whose kube Node is back." \
        "      A re-registered node keeps a tombstone placement will refuse forever." \
        "$(cat "$statements")" "$sweep_output"
elif ! grep -q "$PRESENT_ID" "$statements"; then
    fail "the sweep's DELETE does not name the re-registered node's tombstone." \
        "$(cat "$statements")"
elif grep -q "$GONE_ID" "$statements"; then
    fail "the sweep deleted the tombstone of a node that is NOT in kube." \
        "      That tombstone is the production gate working as intended: without it an" \
        "      inventory upsert resurrects a terminated node's row. The sweep must only" \
        "      clear rows kube itself contradicts." \
        "$(cat "$statements")"
fi

skip_bootstrap_output="$(
    set -euo pipefail
    # shellcheck disable=SC2034
    KIND_CLUSTER="guard-test"
    # shellcheck source=lib/bootstrap-kind-stack.sh
    source "$stack_lib"

    # The port-owner guard needs lsof and a real port owner, the prerequisite
    # assertion needs the box to have them, and the mount check needs a
    # rendered config and a docker daemon; none is the subject here.
    bootstrap_kind_stack__assert_port_owner() { :; }
    kind_stack_assert_smoke_prereqs() { :; }
    kind_stack_assert_cluster_mounts() { :; }
    kind_stack_sweep_stale_node_tombstones() { printf 'SWEEP_RAN\n'; }
    SKIP_BOOTSTRAP=1 bootstrap_kind_stack
)"

if ! has_match 'SWEEP_RAN' "$skip_bootstrap_output"; then
    fail "bootstrap_kind_stack did not sweep tombstones under SKIP_BOOTSTRAP=1." \
        "      Every devbox run uses that mode once the stack is up, so a sweep behind the" \
        "      bring-up's early return never runs where the residue actually is." \
        "$skip_bootstrap_output"
fi

# Property 6: the mount check reaches the same mode. A cluster whose bind
# mounts predate the rendered config is residue exactly like a stale
# tombstone, so a check sitting behind the bring-up's early return would never
# see it on a devbox.
mount_check_output="$(
    set -euo pipefail
    # shellcheck disable=SC2034
    KIND_CLUSTER="guard-test"
    # shellcheck source=lib/bootstrap-kind-stack.sh
    source "$stack_lib"

    bootstrap_kind_stack__assert_port_owner() { :; }
    kind_stack_assert_smoke_prereqs() { :; }
    kind_stack_sweep_stale_node_tombstones() { :; }
    kind_stack_assert_cluster_mounts() { printf 'MOUNTS_CHECKED\n'; }
    SKIP_BOOTSTRAP=1 bootstrap_kind_stack
)"

if ! has_match 'MOUNTS_CHECKED' "$mount_check_output"; then
    fail "bootstrap_kind_stack did not check the live cluster's mounts under SKIP_BOOTSTRAP=1." \
        "      A cluster created before the host paths were parameterised keeps the mounts" \
        "      it was built with, and that mode is where such a cluster is encountered." \
        "$mount_check_output"
fi

# Property 7: the mount check does not make every suite depend on a writable
# $HOME. It runs in SKIP_BOOTSTRAP=1 mode (property 6), and that mode read
# $HOME nowhere before it existed — so on a box with no cluster to compare
# against it has to stand down rather than fail the suite, and it must not
# write into ~/.space-devbox on the way past.
#
# The fixture keeps ~/.space-devbox **writable** on purpose. A mode-555
# directory accepts no entries at all, so "did it write?" would be answered by
# the fixture rather than by the code — an absence with no possible presence.
# Writable means a render into $SPACE_KIND_CONFIG would succeed and show up,
# so an empty listing is the code's choice.
#
# The exit status is captured explicitly rather than left to the assignment:
# `kind_host_paths__die` exits, which fails the command substitution, and
# under this script's `set -e` that aborts before any `fail` can print — the
# regression would be detected and undiagnosed.
mount_home_dir="$(mktemp -d)"
mkdir -p "$mount_home_dir/.space-devbox"
mount_home_rc=0
mount_home_output="$(
    set -uo pipefail
    # shellcheck disable=SC2034
    KIND_CLUSTER="guard-test-absent-cluster"
    # shellcheck source=lib/bootstrap-kind-stack.sh
    source "$stack_lib"

    bootstrap_kind_stack__assert_port_owner() { :; }
    kind_stack_assert_smoke_prereqs() { :; }
    kind_stack_sweep_stale_node_tombstones() { :; }
    HOME="$mount_home_dir" SKIP_BOOTSTRAP=1 bootstrap_kind_stack 2>&1
)" || mount_home_rc=$?

if [ "$mount_home_rc" -ne 0 ]; then
    fail "bootstrap_kind_stack exited $mount_home_rc under SKIP_BOOTSTRAP=1 with no cluster." \
        "      The mount check must stand down when there is nothing to compare, or every" \
        "      kind suite inherits a dependency on a writable ~/.space-devbox it never had." \
        "$mount_home_output"
fi

mount_home_wrote="$(ls -A "$mount_home_dir/.space-devbox" 2>/dev/null | tr '\n' ',')"
if [ -n "$mount_home_wrote" ]; then
    fail "the mount check wrote into ~/.space-devbox ($mount_home_wrote) with no cluster." \
        "      That directory is root-owned on some devboxes, so writing it unconditionally" \
        "      turns a documented shape into a hard failure for every kind suite." \
        "$mount_home_output"
fi
rm -rf "$mount_home_dir"

# Property 4: an unreadable table is not an empty one. Treating a failed query
# as "no rows" would report a clean sweep while the residue survives.
unreadable_rc=0
(
    set -uo pipefail
    # shellcheck disable=SC2034
    KIND_CLUSTER="guard-test"
    # shellcheck source=lib/bootstrap-kind-stack.sh
    source "$stack_lib"
    # Credentials resolve; the query itself is what fails.
    kubectl() { printf 'spaceuser spacedb\n'; }
    kind_stack_psql() { return 1; }
    kind_stack_sweep_stale_node_tombstones
) >/dev/null 2>&1 || unreadable_rc=$?
if [ "$unreadable_rc" -eq 0 ]; then
    fail "the sweep reported success when it could not read node_k8s_tombstones." \
        "      A leftover row then survives and the next create fails with 409."
fi

# Property 5: same rule on the other read. Judging a tombstone stale needs the
# kube node list, so a failed list cannot be treated as "no nodes".
unlistable_rc=0
(
    set -uo pipefail
    # shellcheck disable=SC2034
    KIND_CLUSTER="guard-test"
    # shellcheck source=lib/bootstrap-kind-stack.sh
    source "$stack_lib"
    kubectl() {
        if [[ "$*" == *"get secret space-postgres"* ]]; then
            printf 'spaceuser spacedb\n'
            return 0
        fi
        return 1
    }
    kind_stack_psql() {
        if [[ "$*" == *SELECT* ]]; then
            printf '%s %s\n' "$PRESENT_ID" "present-node"
            return 0
        fi
        {
            printf 'ARGS %s\n' "$*"
            printf 'STDIN '
            cat
        } >>"$statements"
    }
    kind_stack_sweep_stale_node_tombstones
) >/dev/null 2>&1 || unlistable_rc=$?
if [ "$unlistable_rc" -eq 0 ]; then
    fail "the sweep reported success when it could not list kube nodes." \
        "      Without them a tombstone cannot be judged stale, so a clean report is a guess."
fi

# Property 6: psql does not interpolate `:'var'` in a `-c` string — the two
# together fail with `syntax error at or near ":"`, and no stub can catch that
# because it never reaches a server. Any bound statement therefore goes on stdin.
if grep -n "kind_stack_psql .*-v .*-c " "$stack_lib" >/dev/null 2>&1; then
    fail "a kind_stack_psql call passes both -v and -c." \
        "      psql interpolates :'var' only for stdin/file input, so that statement" \
        "      reaches Postgres with a literal colon and fails. Use a heredoc."
fi

if [ "$status" -eq 0 ]; then
    echo "ok: the sweep clears only tombstones kube contradicts, runs under SKIP_BOOTSTRAP=1" \
        "as does the live-cluster mount check, fails on an unreadable table or an" \
        "unlistable kube"
fi
exit "$status"
