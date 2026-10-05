#!/usr/bin/env bash
# Reproduce the reconcile-index bloat mechanism against the real schema.
#
# Reconcile queue indexes can retain storage after their rows are removed.
# This script derives the index-inventory, reachability, HOT, churn-growth
# and rebuild figures from a throwaway PostgreSQL 17 container with all `db/postgres` migrations
# applied, by replaying the deployed statement sequence (enqueue upsert, claim,
# complete, release) rather than a synthetic write pattern.
#
# This harness covers only the checks below; it does not establish deployment
# privileges, operational lock-holder safety, or readings from another database.
#
# It answers four questions:
#
#   1. Which columns make an update non-HOT, per table. A one-column-at-a-time
#      update matrix against a freshly vacuumed table.
#   2. Does the churn shape bloat on its own? Same workload with vacuum
#      unobstructed (footprint stays flat) and with one open REPEATABLE READ
#      snapshot (footprint grows linearly).
#   3. Does VACUUM give the space back? It truncates the heap and never shrinks
#      an index.
#   4. What does REINDEX INDEX CONCURRENTLY cost and leave behind? Reclaim,
#      duration, concurrent-DML survival, and the invalid `_ccnew` index a
#      cancelled rebuild strands.
#
# Read-only with respect to every real environment: it talks to a container it
# creates and removes, never to a cluster. Needs Docker and about four minutes.
#
# Usage: scripts/repro-reconcile-index-bloat.sh [--keep]
#   --keep   leave the container running for follow-up queries

set -euo pipefail

CONTAINER="${CONTAINER:-repro-reconcile-index-bloat}"
IMAGE="${IMAGE:-public.ecr.aws/docker/library/postgres:17-alpine}"
NODES="${NODES:-30}"
KEEP=0
case "${1:-}" in
  "") ;;
  --keep) KEEP=1 ;;
  *) echo "usage: $(basename "$0") [--keep]" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL=(docker exec -i "$CONTAINER" psql -U postgres -d space -v ON_ERROR_STOP=1)

die() { echo "error: $*" >&2; exit 1; }
# Wall-clock milliseconds, portably. GNU date and current macOS both honour
# %N, but older BSD date emits a literal 'N' and the arithmetic below would
# then abort the run under `set -e`, so fall back rather than assume.
now_ms() {
  local n; n=$(date +%s%N)
  case "$n" in
    ''|*[!0-9]*) python3 -c 'import time; print(int(time.time()*1000))' ;;
    *) echo $(( n / 1000000 )) ;;
  esac
}
step() { printf '\n=== %s ===\n' "$*"; }
q() { "${PSQL[@]}" -tA -F'|' -c "$1"; }
qq() { "${PSQL[@]}" -q -c "$1"; }

COMPLETED=0
# Set only once `docker run` has succeeded. Cleanup must never remove a
# container this invocation didn't create: the pre-flight refusal below exits
# through this same trap, so an unconditional `docker rm -f` here would destroy
# the very container the refusal promises to leave alone -- including one
# another session is holding with --keep.
CREATED=0
cleanup() {
  status=$?
  if (( KEEP && CREATED )); then
    # Quiesce the background probes before handing the container over. An abort
    # after Q2b leaves an hour-long pg_sleep holding the xmin horizon, and one
    # after Q4a leaves the DML writer and the lock sampler looping until the
    # container dies -- so a --keep container would go on mutating the very
    # state it was retained for someone to inspect. Best-effort: this runs on
    # the abort path, where the database may already be unreachable.
    docker exec "$CONTAINER" touch /stop-dml >/dev/null 2>&1 || true
    docker exec "$CONTAINER" psql -U postgres -d space -tAc \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
       WHERE pid <> pg_backend_pid() AND query LIKE '%pg_sleep%'" >/dev/null 2>&1 || true
    # Signalling is not stopping. /stop-dml only ends the *next* iteration, so
    # the writer can still be inside a multi-statement transaction and the
    # sampler can still append once more; pg_terminate_backend likewise returns
    # when the signal is sent. Wait for the markers the probes write on exit and
    # for the backends to actually disappear, then say which of those held --
    # a container handed over as quiet while it is still mutating is worse than
    # one handed over with a warning.
    # Only wait on a marker whose probe was actually started -- an abort before
    # Q4a never writes /dml.sh or /sample-locks.sh, and blocking on their exit
    # markers would spend 20s to emit a warning about probes that never ran.
    want_dml=0;   docker exec "$CONTAINER" test -f /dml.sh          >/dev/null 2>&1 && want_dml=1
    want_locks=0; docker exec "$CONTAINER" test -f /sample-locks.sh >/dev/null 2>&1 && want_locks=1
    quiesced=1
    for _ in $(seq 1 20); do
      if (( want_dml )); then
        docker exec "$CONTAINER" test -s /dml.log >/dev/null 2>&1 || { sleep 1; continue; }
      fi
      if (( want_locks )); then
        docker exec "$CONTAINER" test -s /locks.done >/dev/null 2>&1 || { sleep 1; continue; }
      fi
      [[ "$(docker exec "$CONTAINER" psql -U postgres -d space -tAc \
            "SELECT count(*) FROM pg_stat_activity
             WHERE pid <> pg_backend_pid() AND datname = 'space'
               AND query LIKE '%pg_sleep%'" 2>/dev/null | tr -d ' ')" == "0" ]] || { sleep 1; continue; }
      quiesced=0; break
    done
    if (( quiesced == 0 )); then
      echo "container $CONTAINER left running (--keep); background probes confirmed stopped"
    else
      echo "container $CONTAINER left running (--keep); WARNING: probes did not" >&2
      echo "confirm quiescence within 20s -- treat its state as still moving" >&2
    fi
    echo "remove with: docker rm -f $CONTAINER"
  elif (( CREATED )); then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  [[ -n "${SCRATCH:-}" ]] && rm -rf "$SCRATCH"
  # Fail closed on an abort that did not set a status of its own. bash 3.2
  # exits 0 on a fatal parameter-expansion error, so "ran to completion" has to
  # be positively established rather than inferred from the exit code.
  if (( COMPLETED == 0 )); then
    echo "error: the harness aborted before finishing; its output proves nothing" >&2
    (( status == 0 )) && status=1
  fi
  exit "$status"
}
trap cleanup EXIT

# Host scratch goes in a per-run directory, allocated only now that cleanup is
# installed to remove it -- allocating it before the argument parser would leak
# a directory on every mistyped invocation. Per-run matters because the
# pre-flight refusal below tells the operator to re-run under a different
# CONTAINER name, and that is only concurrent-safe if the host-side files are
# per-run too: two runs sharing one fixed path truncate each other's partial
# index inventory mid-EXPLAIN and fail the unreached-index assertion on a run
# where nothing was wrong.
# Named after the container so a stray directory is attributable to the run
# that made it, and so a cleanup can target one run instead of globbing the
# prefix -- `rm -rf $TMPDIR/repro-reconcile-index.*` matches directories
# belonging to runs still in flight and kills them mid-measurement, so target
# one run's own `repro-reconcile-index.<container>.*` instead. Nothing
# external needs to tidy these: cleanup() removes this run's own.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/repro-reconcile-index.${CONTAINER}.XXXXXX")"

docker info >/dev/null 2>&1 || die "Docker is not responding"

step "starting $IMAGE"
# Refuse to reuse the name rather than clobbering it. The container name is
# fixed by default, so an unconditional `docker rm -f` here destroys a `--keep`
# container someone else is still querying, and destroys it silently in the
# middle of their session. A crashed earlier run is also worth being told about
# rather than erased. Both remedies are one command, named in the message.
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  die "container $CONTAINER already exists. Remove it with 'docker rm -f $CONTAINER', or run this with CONTAINER=<other-name> to leave it alone"
fi
docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=pg -e POSTGRES_DB=space \
  "$IMAGE" -c autovacuum_naptime=1s >/dev/null
CREATED=1
ready=0
for _ in $(seq 1 90); do
  if docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -U postgres -q 2>/dev/null \
     && docker exec "$CONTAINER" psql -h 127.0.0.1 -U postgres -d space -tAc "SELECT 1" >/dev/null 2>&1
  then ready=1; break; fi
  sleep 1
done
(( ready == 1 )) || die "Postgres never became ready"
q "SELECT version()"

step "applying db/postgres migrations"
docker cp "$REPO_ROOT/db/postgres" "$CONTAINER:/mig" >/dev/null
docker exec "$CONTAINER" sh -c '
  for f in $(ls /mig/*.up.sql | sort); do
    psql -U postgres -d space -v ON_ERROR_STOP=1 -q -f "$f" >/tmp/out 2>&1 || {
      echo "FAILED $(basename "$f")"; cat /tmp/out; exit 1; }
  done' || die "migrations failed"
qq "CREATE EXTENSION IF NOT EXISTS pgstattuple;"
echo "applied $(docker exec "$CONTAINER" sh -c 'ls /mig/*.up.sql | wc -l' | tr -d ' ') migrations"

step "index identities (the set the schema defines)"
"${PSQL[@]}" -c "
SELECT c.relname AS table_name, i.relname AS index_name, am.amname AS method,
       pg_get_indexdef(i.oid) AS definition
FROM pg_index ix
JOIN pg_class c ON c.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_am am ON am.oid = i.relam
WHERE c.relname IN ('node_reconcile_queue', 'node_reconcile_triggers')
ORDER BY c.relname, i.relname"

index_count="$(q "SELECT count(*) FROM pg_index ix
  JOIN pg_class c ON c.oid = ix.indrelid
  JOIN pg_class i ON i.oid = ix.indexrelid
  JOIN pg_am am ON am.oid = i.relam
  WHERE c.relname IN ('node_reconcile_queue', 'node_reconcile_triggers')
    AND am.amname = 'btree'")"
# Nine is what db/postgres defines, which is what this container has.
# This assertion guards the migration set. Deployed databases may have extra
# indexes; inventory the target database before choosing indexes to rebuild.
(( index_count == 9 )) \
  || die "expected 9 btree indexes from the migration set, found $index_count; db/postgres changed"

qq "INSERT INTO nodes (id, role, managed_by, state, created_at)
    SELECT space_uuid_v7(), 'worker', 'k8s', 'ready', NOW()
    FROM generate_series(1, $NODES);"

step "which statement reaches which index"
# Seed enough rows, with a dead-lettered slice, for the planner to prefer
# indexes over sequential scans; then run the deployed predicates. A tiny table
# plans everything as a seq scan and says nothing about reachability.
qq "INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
      SELECT n.id, 'sandbox-desired-state', g::text, NOW(), NOW()
      FROM nodes n CROSS JOIN generate_series(1, 20000) g
      ON CONFLICT DO NOTHING;
    -- Dead-letter a slice the retention pass can actually reap: it requires
    -- requested_at past the retention window too, so leaving requested_at at
    -- NOW() makes the candidate scan match zero rows and every plan drawn from
    -- it an artifact of an empty result set.
    UPDATE node_reconcile_queue
      SET dead_at = NOW() - INTERVAL '2 days',
          requested_at = NOW() - INTERVAL '3 days',
          dead_reason = 'probe'
      WHERE element IN ('1','2','3','4','5','6','7','8','9','10');
    INSERT INTO node_reconcile_triggers (node_id, reason, reasons, requested_at, updated_at)
      SELECT id, 'node_updated', ARRAY['node_updated'::state_reconciliation_reason], NOW(), NOW()
      FROM nodes ON CONFLICT DO NOTHING;
    -- The gone-node candidate scan joins node_k8s and requires a node that is
    -- not ready, so give it both. Without them the join empties the result and
    -- its plan says nothing — the same trap as a fresh requested_at above.
    INSERT INTO node_k8s (node_id, k8s_node_name, k8s_node_uid)
      SELECT id, 'ip-10-0-0-' || row_number() OVER (ORDER BY id), 'uid-' || id
      FROM nodes ON CONFLICT DO NOTHING;
    UPDATE nodes SET state = 'registered'
      WHERE id IN (SELECT id FROM nodes ORDER BY id LIMIT 10);
    -- Dead-letter a reapable slice of the triggers too: the trigger branch of
    -- the retention pass needs dead rows whose updated_at is past the window,
    -- and explaining it against a table with none says nothing.
    UPDATE node_reconcile_triggers
      SET dead_at = NOW() - INTERVAL '2 days',
          requested_at = NOW() - INTERVAL '3 days',
          updated_at = NOW() - INTERVAL '3 days'
      WHERE node_id IN (SELECT id FROM nodes ORDER BY id LIMIT 10);
    ANALYZE node_reconcile_queue, node_reconcile_triggers, nodes;" >/dev/null

: > "$SCRATCH"/reached-indexes.txt
# $1 label, $2 statement, $3 expected access path (an index name, or SEQ for a
# statement that legitimately sequentially scans), $4 optional session setting.
# `enable_seqscan = off` answers "can this index serve the statement at all",
# which is the question for an index the planner currently costs out.
explain_for() {
  local label="$1" stmt="$2" expect="$3" setting="${4:-SET enable_seqscan = on}"
  printf '\n%s\n' "$label"
  local plan
  plan="$("${PSQL[@]}" -tA -c "$setting" -c "EXPLAIN (COSTS OFF) $stmt")" \
    || die "EXPLAIN failed for: $label"
  local scans
  scans="$(printf '%s\n' "$plan" | grep -iE "Index (Only )?Scan|Bitmap Index Scan|Seq Scan|Conflict Arbiter Indexes")" \
    || die "no scan node or conflict arbiter in the plan for: $label"
  printf '%s\n' "$scans" | sed 's/^ */  /'
  if [[ "$expect" == "SEQ" ]]; then
    printf '%s\n' "$scans" | grep -qi "Seq Scan" \
      || die "$label: expected a sequential scan, got something else"
  else
    # Anchored so an expectation of `…_claim` is not satisfied by `…_claimed`.
    # The three plan shapes name an index after `using`, after `on` (bitmap
    # scans), or after `Indexes:` (an upsert's conflict arbiter).
    printf '%s\n' "$scans" | grep -qE "(using|on|Indexes:) +${expect}( |\$)" \
      || die "$label: expected the plan to reach $expect; it did not"
  fi
  # Record every index the plan actually touched, so the unreached set below is
  # a reading of these plans rather than a hardcoded claim.
  printf '%s\n' "$scans" \
    | grep -oE "(idx_node_reconcile[a-z_]*|node_reconcile_[a-z]*_pkey)" >> "$SCRATCH"/reached-indexes.txt || true
}
explain_for "ref claim (adapter.rs:1161)" \
  "SELECT node_id, facet, element FROM node_reconcile_queue
   WHERE node_id = (SELECT id FROM nodes LIMIT 1) AND next_attempt_at <= NOW() AND dead_at IS NULL
     AND (claim_token = '' OR claimed_at <= NOW() - (120 * INTERVAL '1 second'))
   ORDER BY requested_at ASC, facet ASC, element ASC LIMIT 256 FOR UPDATE SKIP LOCKED" \
  "idx_node_reconcile_queue_claim"
explain_for "sandbox-delete ref cleanup (sql/sandbox_delete.rs:37)" \
  "WITH refs AS (SELECT DISTINCT facet, element
                 FROM UNNEST(ARRAY['sandbox-desired-state']::TEXT[], ARRAY['7777']::TEXT[]) AS refs(facet, element))
   DELETE FROM node_reconcile_queue nrq USING refs
   WHERE nrq.facet = refs.facet AND nrq.element = refs.element" \
  "idx_node_reconcile_queue_facet_element"
explain_for "dead-letter candidate scan, as deployed (reconcile_queue_gc/store.rs:37)" \
  "SELECT 'queue'::TEXT AS record_kind, q.node_id, q.facet, q.element, q.requested_at
   FROM node_reconcile_queue q
   WHERE q.dead_at IS NOT NULL AND q.dead_at <= NOW() - INTERVAL '1 day'
     AND q.requested_at <= NOW() - INTERVAL '1 day'
   UNION ALL
   SELECT 'trigger'::TEXT, t.node_id, ''::TEXT, ''::TEXT, t.requested_at
   FROM node_reconcile_triggers t
   WHERE t.dead_at IS NOT NULL AND t.dead_at <= NOW() - INTERVAL '1 day'
     AND t.updated_at <= NOW() - INTERVAL '1 day'
   ORDER BY requested_at ASC LIMIT 1000" \
  "idx_node_reconcile_queue_dead"
explain_for "trigger claim (trigger-queue/src/lib.rs:178)" \
  "SELECT node_id FROM node_reconcile_triggers
   WHERE next_attempt_at <= NOW() AND dead_at IS NULL
     AND (claim_token = '' OR claimed_at <= NOW() - (60 * INTERVAL '1 second'))
   ORDER BY requested_at ASC, node_id ASC LIMIT 128 FOR UPDATE SKIP LOCKED" \
  "idx_node_reconcile_triggers_claim" "SET enable_seqscan = off"
explain_for "dead-letter delete re-check, queue branch (reconcile_queue_gc/store.rs:61)" \
  "WITH doomed AS MATERIALIZED (
     SELECT q.node_id, q.facet, q.element, q.requested_at FROM node_reconcile_queue q
     WHERE q.dead_at IS NOT NULL AND q.dead_at <= NOW() - INTERVAL '1 day'
       AND q.requested_at <= NOW() - INTERVAL '1 day'
     ORDER BY q.requested_at LIMIT 1000)
   DELETE FROM node_reconcile_queue q USING doomed d
   WHERE q.node_id = d.node_id AND q.facet = d.facet AND q.element = d.element
     AND q.dead_at IS NOT NULL AND q.dead_at <= NOW() - INTERVAL '1 day'
     AND q.requested_at <= NOW() - INTERVAL '1 day'" \
  "idx_node_reconcile_queue_dead"
# The cursor parameter is substituted as a literal NULL, which the planner folds
# to a constant true — so this is the first-page plan (cursor unset), the shape
# production issues to open a sweep. A later page binds a real UUID and makes
# `n.id > $1` a live predicate; that plan is not covered here.
explain_for "gone-node candidate scan, first page as deployed (reconcile_queue_gc/store.rs:105)" \
  "SELECT n.id, k.k8s_node_name, k.k8s_node_uid
   FROM nodes n
   JOIN node_k8s k ON k.node_id = n.id
   WHERE n.managed_by = 'k8s'
     AND n.state IS DISTINCT FROM 'ready'
     AND n.drain_phase IS NULL
     AND (NULL::UUID IS NULL OR n.id > NULL::UUID)
     AND (EXISTS (SELECT 1 FROM node_reconcile_queue q
                  WHERE q.node_id = n.id AND q.dead_at IS NULL
                    AND q.requested_at <= NOW() - INTERVAL '1 day')
       OR EXISTS (SELECT 1 FROM node_reconcile_triggers t
                  WHERE t.node_id = n.id AND t.dead_at IS NULL
                    AND t.requested_at <= NOW() - INTERVAL '1 day'))
   ORDER BY n.id ASC LIMIT 25" \
  "idx_node_reconcile_queue_requested_at" "SET enable_seqscan = off"
explain_for "gone-node prune, trigger branch as deployed (reconcile_queue_gc/store.rs:224)" \
  "WITH eligible_node AS MATERIALIZED (SELECT id FROM nodes WHERE state IS DISTINCT FROM 'ready')
   SELECT t.node_id, t.requested_at
   FROM node_reconcile_triggers t
   JOIN eligible_node n ON n.id = t.node_id
   WHERE t.dead_at IS NULL AND t.requested_at <= NOW() - INTERVAL '1 day'
     AND (t.claim_token = '' OR t.claimed_at IS NULL
          OR t.claimed_at <= NOW() - INTERVAL '60 seconds')" \
  "idx_node_reconcile_triggers_claim" "SET enable_seqscan = off"
explain_for "enqueue upsert conflict arbiter (reconcile_queue.rs:302)" \
  "INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
   SELECT id, 'network-policy', '', NOW(), NOW() FROM nodes LIMIT 1
   ON CONFLICT (node_id, facet, element) DO UPDATE SET updated_at = NOW()" \
  "node_reconcile_queue_pkey"
explain_for "trigger fanout upsert conflict arbiter (trigger-queue/src/lib.rs:117)" \
  "INSERT INTO node_reconcile_triggers (node_id, reason, reasons, requested_at, updated_at)
   SELECT id, 'node_updated', ARRAY['node_updated'::state_reconciliation_reason], NOW(), NOW()
   FROM nodes LIMIT 1
   ON CONFLICT (node_id) DO UPDATE SET updated_at = NOW()" \
  "node_reconcile_triggers_pkey"
explain_for "dead-letter trigger branch in isolation (reconcile_queue_gc/store.rs:53)" \
  "SELECT t.node_id, t.requested_at FROM node_reconcile_triggers t
   WHERE t.dead_at IS NOT NULL AND t.dead_at <= NOW() - INTERVAL '1 day'
     AND t.updated_at <= NOW() - INTERVAL '1 day'
   ORDER BY t.requested_at LIMIT 1000" \
  "idx_node_reconcile_triggers_dead" "SET enable_seqscan = off"
explain_for "queue depth metric (node_queue_depth_counts, metrics.rs:74)" \
  "SELECT facet, CASE WHEN dead_at IS NOT NULL THEN 'dead' WHEN claim_token != '' THEN 'claimed'
                      WHEN next_attempt_at > NOW() THEN 'backoff' ELSE 'ready' END AS state,
          COUNT(*)::BIGINT FROM node_reconcile_queue GROUP BY facet, state" \
  "SEQ"
echo
echo "-- indexes no statement above reached, derived from those plans --"
q "SELECT i.relname
   FROM pg_index ix
   JOIN pg_class c ON c.oid = ix.indrelid
   JOIN pg_class i ON i.oid = ix.indexrelid
   WHERE c.relname IN ('node_reconcile_queue', 'node_reconcile_triggers')
   ORDER BY i.relname" > "$SCRATCH"/all-indexes.txt
unreached="$(comm -23 <(sort -u "$SCRATCH"/all-indexes.txt) <(sort -u "$SCRATCH"/reached-indexes.txt))"
printf '%s\n' "$unreached" | sed 's/^/  /'
# No statement in this inventory gives the index a leading predicate.
unreached_count="$(printf '%s\n' "$unreached" | grep -c . || true)"
(( unreached_count == 1 )) \
  || die "expected exactly one unreached index, found $unreached_count; the statement inventory or the schema changed"
printf '%s\n' "$unreached" | grep -q '^idx_node_reconcile_triggers_claimed$' \
  || die "idx_node_reconcile_triggers_claimed was unexpectedly reached"
echo "  (reachability is not usage: only pg_stat_user_indexes.idx_scan on the"
echo "   live cluster settles which of these are actually used)"

qq "UPDATE nodes SET state = 'ready';" >/dev/null

step "index entry density, for sizing the bloat arithmetic"
# Measure entries per page with distinct values; duplicate-key deduplication
# would inflate the estimate.
qq "DROP TABLE IF EXISTS density_probe;
    CREATE TABLE density_probe (ts timestamptz);
    INSERT INTO density_probe SELECT NOW() + (g || ' microseconds')::interval
      FROM generate_series(1, 600000) g;
    CREATE INDEX idx_density_probe_ts ON density_probe(ts);" >/dev/null
# Same LATERAL discipline as the density table below: three subscripted
# references would scan this 1,640-leaf-page index three times.
"${PSQL[@]}" -c "
SELECT s.leaf_pages,
       600000 / GREATEST(s.leaf_pages, 1) AS entries_per_leaf_page,
       round(s.avg_leaf_density::numeric, 1) AS avg_leaf_density
FROM pgstatindex('idx_density_probe_ts') s"
qq "DROP TABLE density_probe;
    TRUNCATE node_reconcile_queue, node_reconcile_triggers;" >/dev/null

# The deployed statement sequence: one API inventory publish (queue-ref upsert
# plus trigger upsert), one cluster-controller trigger claim/complete, and one
# node-ctl claim/complete per node. Sources: reconcile_queue.rs:21,
# trigger-queue/src/lib.rs:117, adapter.rs:1161, adapter.rs:1226.
docker exec -i "$CONTAINER" tee /churn.sql >/dev/null <<'SQL'
DO $$
DECLARE i INT; n RECORD; tok TEXT;
BEGIN
  FOR i IN 1..(SELECT current_setting('pla.iters')::int) LOOP
    INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
    SELECT nodes.id, refs.facet, refs.element, NOW(), NOW()
    FROM nodes CROSS JOIN (VALUES ('sandbox-desired-state','sbx'), ('network-policy','')) AS refs(facet, element)
    WHERE nodes.role IN ('worker','builder')
    ON CONFLICT (node_id, facet, element) DO UPDATE
    SET generation = node_reconcile_queue.generation + 1,
        requested_at = CASE WHEN node_reconcile_queue.dead_at IS NOT NULL
                            THEN EXCLUDED.requested_at ELSE node_reconcile_queue.requested_at END,
        next_attempt_at = CASE WHEN node_reconcile_queue.dead_at IS NOT NULL THEN NOW()
                               WHEN node_reconcile_queue.claim_token = ''
                                    AND node_reconcile_queue.attempts = 0 THEN NOW()
                               ELSE node_reconcile_queue.next_attempt_at END,
        attempts = CASE WHEN node_reconcile_queue.dead_at IS NOT NULL THEN 0
                        ELSE node_reconcile_queue.attempts END,
        last_error = CASE WHEN node_reconcile_queue.dead_at IS NOT NULL
                               OR node_reconcile_queue.attempts = 0 THEN ''
                          ELSE node_reconcile_queue.last_error END,
        dead_at = NULL, dead_reason = '', updated_at = NOW();

    INSERT INTO node_reconcile_triggers (node_id, reason, reasons, requested_at, updated_at)
    SELECT nodes.id, 'node_sandbox_inventory_published',
           ARRAY['node_sandbox_inventory_published'::state_reconciliation_reason], NOW(), NOW()
    FROM nodes WHERE nodes.role IN ('worker','builder')
    ON CONFLICT (node_id) DO UPDATE
    SET generation = node_reconcile_triggers.generation + 1,
        requested_at = CASE WHEN node_reconcile_triggers.claim_token = '' THEN NOW()
                            ELSE node_reconcile_triggers.requested_at END,
        next_attempt_at = CASE WHEN node_reconcile_triggers.claim_token = '' THEN NOW()
                               ELSE node_reconcile_triggers.next_attempt_at END,
        attempts = CASE WHEN node_reconcile_triggers.claim_token = '' THEN 0
                        ELSE node_reconcile_triggers.attempts END,
        last_error = CASE WHEN node_reconcile_triggers.claim_token = '' THEN ''
                          ELSE node_reconcile_triggers.last_error END,
        dead_at = NULL, dead_reason = '', updated_at = NOW();

    -- The API publish that enqueues the ref and its trigger ends here.
    COMMIT;

    -- A second publish before the claim: the refs are queued and unclaimed, so
    -- this one takes the revival branch and re-stamps next_attempt_at in a new
    -- transaction. This exercises the case where publishes outrun claims.
    INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
    SELECT nodes.id, refs.facet, refs.element, NOW(), NOW()
    FROM nodes CROSS JOIN (VALUES ('sandbox-desired-state','sbx'), ('network-policy','')) AS refs(facet, element)
    WHERE nodes.role IN ('worker','builder')
    ON CONFLICT (node_id, facet, element) DO UPDATE
    SET generation = node_reconcile_queue.generation + 1,
        next_attempt_at = CASE WHEN node_reconcile_queue.claim_token = ''
                                    AND node_reconcile_queue.attempts = 0 THEN NOW()
                               ELSE node_reconcile_queue.next_attempt_at END,
        updated_at = NOW();
    COMMIT;

    tok := 'state-reconcile-trigger-' || i;
    UPDATE node_reconcile_triggers t
    SET claim_token = tok, claim_generation = t.generation, claimed_at = NOW(), updated_at = NOW()
    WHERE t.next_attempt_at <= NOW() AND t.dead_at IS NULL
      AND (t.claim_token = '' OR t.claimed_at <= NOW() - (60 * INTERVAL '1 second'));
    -- The cluster-controller's trigger claim is its own transaction.
    COMMIT;

    DELETE FROM node_reconcile_triggers t
    WHERE t.claim_token = tok AND t.generation = t.claim_generation;
    UPDATE node_reconcile_triggers t
    SET claim_token = '', claim_generation = 0, claimed_at = NULL,
        next_attempt_at = NOW(), updated_at = NOW()
    WHERE t.claim_token = tok;
    -- …and its completion another.
    COMMIT;

    FOR n IN SELECT id FROM nodes WHERE role IN ('worker','builder') LOOP
      tok := n.id || '-' || i;
      UPDATE node_reconcile_queue q
      SET claim_token = tok, claim_generation = q.generation, claimed_at = NOW(), updated_at = NOW()
      WHERE q.node_id = n.id AND q.next_attempt_at <= NOW() AND q.dead_at IS NULL
        AND (q.claim_token = '' OR q.claimed_at <= NOW() - (120 * INTERVAL '1 second'));
      -- ClaimNodeReconcileRefs is one RPC, so one transaction.
      COMMIT;
      -- A publish landing between the claim and the completion. This is the
      -- race production's release exists for, so the harness has to produce it
      -- or the release below is unreachable. Every fifth cycle is a modelling
      -- choice, not a measured rate: the claim_token is non-empty here, so the
      -- revival CASE leaves next_attempt_at alone and this publish moves only
      -- generation and updated_at, both HOT-safe on the queue.
      IF i % 5 = 0 THEN
        INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
        SELECT n.id, refs.facet, refs.element, NOW(), NOW()
        FROM (VALUES ('sandbox-desired-state','sbx'), ('network-policy','')) AS refs(facet, element)
        ON CONFLICT (node_id, facet, element) DO UPDATE
        SET generation = node_reconcile_queue.generation + 1,
            next_attempt_at = CASE WHEN node_reconcile_queue.claim_token = ''
                                        AND node_reconcile_queue.attempts = 0 THEN NOW()
                                   ELSE node_reconcile_queue.next_attempt_at END,
            updated_at = NOW();
        COMMIT;
      END IF;

      DELETE FROM node_reconcile_queue
      WHERE node_id = n.id AND claim_token = tok AND generation = claim_generation;
      -- Production's release deliberately omits the generation predicate its
      -- own DELETE carries: compare adapter.rs:1231 with the release's WHERE at
      -- adapter.rs:1252-1255. That asymmetry is the mechanism. When a publish
      -- lands between claim and completion it advances generation, the DELETE
      -- misses, and this UPDATE still matches on claim_token alone and
      -- re-stamps next_attempt_at -- a key of idx_node_reconcile_queue_claim,
      -- so a non-HOT update. Repeating the DELETE's predicate here would make
      -- this statement match only rows the DELETE had just removed, in the same
      -- transaction, on every path -- zero rows unconditionally, and the write
      -- class silently absent from the measurement.
      UPDATE node_reconcile_queue
      SET claim_token = '', claim_generation = 0, claimed_at = NULL,
          next_attempt_at = NOW(), updated_at = NOW()
      WHERE node_id = n.id AND claim_token = tok;
      -- CompleteNodeReconcileRefs opens its own transaction
      -- (adapter.rs:1216), so the release's NOW() is not the enqueue's.
      COMMIT;
    END LOOP;
  END LOOP;
END $$;
SQL

churn() { "${PSQL[@]}" -q -c "SET pla.iters = $1;" -f /churn.sql; }
pages() { q "SELECT pg_relation_size('$1')/8192"; }

step "Q1: which columns make an update non-HOT"
# fillfactor 30 leaves room on every page for the new tuple versions, so a
# zero-HOT result can only mean an indexed column was changed. Without it,
# HOT failures from a full page look identical to index blocking, and which one
# you get depends on the fixture size.
qq "TRUNCATE node_reconcile_queue, node_reconcile_triggers;
    ALTER TABLE node_reconcile_queue SET (fillfactor = 30);
    ALTER TABLE node_reconcile_triggers SET (fillfactor = 30);
    INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
      SELECT id,'f','',NOW(),NOW() FROM nodes;
    INSERT INTO node_reconcile_triggers (node_id, reason, reasons, requested_at, updated_at)
      SELECT id,'node_updated',ARRAY['node_updated'::state_reconciliation_reason],NOW(),NOW() FROM nodes;"
printf '%-18s %-9s %-5s %-5s %s\n' column table upd hot verdict
# Every column a deployed writer assigns, on both tables, plus one identity
# column. No deployed statement updates node_id/facet/element on the queue or
# node_id on the triggers -- they are the row's identity -- but they are pkey
# key columns and so equally never-HOT, and a matrix that silently omitted the
# whole class could not establish which columns block. `element` stands in for
# it: it is the one that can be reassigned without touching an FK, and it keys
# both node_reconcile_queue_pkey and idx_node_reconcile_queue_facet_element.
# A partial index's predicate column blocks HOT exactly like a key column does,
# so dead_at and claim_token are in here even though no index keys on them.
for spec in \
  "queue:updated_at = NOW()" "queue:claimed_at = NOW()" "queue:claim_token = 'x'||random()" \
  "queue:attempts = attempts + 1" "queue:last_error = random()::text" \
  "queue:next_attempt_at = NOW()" "queue:requested_at = NOW()" \
  "queue:generation = generation + 1" "queue:claim_generation = claim_generation + 1" \
  "queue:dead_at = NOW()" "queue:dead_reason = 'x'||random()" \
  "queue:element = 'z'||random()" \
  "triggers:updated_at = NOW()" "triggers:claimed_at = NOW()" \
  "triggers:attempts = attempts + 1" "triggers:generation = generation + 1" \
  "triggers:claim_generation = claim_generation + 1" \
  "triggers:next_attempt_at = NOW()" "triggers:requested_at = NOW()" \
  "triggers:claim_token = 'x'||random()" "triggers:dead_at = NOW()" \
  "triggers:reason = 'x'||random()" "triggers:last_error = 'x'||random()" \
  "triggers:reasons = ARRAY['node_registered'::state_reconciliation_reason]" \
  "triggers:dead_reason = 'x'||random()"
do
  tbl="node_reconcile_${spec%%:*}"; assign="${spec#*:}"
  qq "VACUUM (ANALYZE) $tbl;" >/dev/null
  qq "SELECT pg_stat_reset_single_table_counters('$tbl'::regclass);" >/dev/null
  qq "UPDATE $tbl SET $assign;" >/dev/null
  IFS='|' read -r upd hot <<<"$(q "SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='$tbl'")"
  # A 0|0 read would satisfy every verdict below vacuously, so require the
  # update to have actually touched all NODES rows.
  [[ -n "$upd" && -n "$hot" ]] || die "no stats row for $tbl after updating ${assign%% =*}"
  (( upd == NODES )) || die "expected $NODES updates on $tbl for ${assign%% =*}, saw $upd"
  # Zero HOT means an indexed column -- either an index key or a partial
  # index's predicate column. Anything short of all-HOT on an *unindexed*
  # column is rejected outright rather than tolerated; see the guard below for
  # why the fillfactor makes that exact rather than approximate.
  col="${assign%% =*}"
  case "${spec%%:*}:$col" in
    # Keys and partial-index predicates on each table, from the nine definitions.
    queue:next_attempt_at|queue:requested_at|queue:dead_at) expect=NEVER ;;
    # An identity column: pkey key and _facet_element key both.
    queue:element) expect=NEVER ;;
    triggers:updated_at|triggers:claimed_at|triggers:next_attempt_at) expect=NEVER ;;
    triggers:requested_at|triggers:claim_token|triggers:dead_at) expect=NEVER ;;
    *) expect=HOT ;;
  esac
  if [[ "$expect" == NEVER ]]; then
    (( hot == 0 )) || die "$col on ${spec%%:*}: expected no HOT updates, got $hot of $upd"
    verdict="NEVER HOT (indexed column)"
  else
    # With fillfactor 30 there is room on every page, so an unindexed column
    # must be fully HOT. A shortfall means the probe lost its free space.
    (( hot == upd )) || die "$col on ${spec%%:*}: expected all $upd updates HOT, got $hot"
    verdict="HOT"
  fi
  printf '%-18s %-9s %-5s %-5s %s\n' "$col" "${spec%%:*}" "$upd" "$hot" "$verdict"
done
qq "ALTER TABLE node_reconcile_queue RESET (fillfactor);
    ALTER TABLE node_reconcile_triggers RESET (fillfactor);" >/dev/null

step "Q1b: a partial index's predicate column blocks HOT, isolated"
# On the real tables the enqueue upsert assigns dead_at = NULL to rows whose
# dead_at is already NULL. Postgres compares values, so an assignment that
# changes nothing does not block HOT — which is why the queue's enqueue is
# blocked by next_attempt_at rather than by dead_at. This probe changes the
# predicate column's value, isolating the rule itself.
qq "DROP TABLE IF EXISTS pred_probe;
    CREATE TABLE pred_probe (id int primary key, key_col int, pred_col int, plain_col int);
    INSERT INTO pred_probe SELECT g, g, NULL, g FROM generate_series(1, 30) g;
    CREATE INDEX idx_pred_probe ON pred_probe(key_col) WHERE pred_col IS NOT NULL;" >/dev/null
for col in pred_col plain_col; do
  qq "VACUUM (ANALYZE) pred_probe;" >/dev/null
  qq "SELECT pg_stat_reset_single_table_counters('pred_probe'::regclass);" >/dev/null
  qq "UPDATE pred_probe SET $col = COALESCE($col, 0) + 1;" >/dev/null
  IFS='|' read -r upd hot <<<"$(q "SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='pred_probe'")"
  [[ -n "$upd" && -n "$hot" ]] || die "no stats row for pred_probe after updating $col"
  # Without this both verdicts below hold vacuously on a 0-update read.
  (( upd == 30 )) || die "expected 30 updates on pred_probe for $col, saw $upd"
  printf 'update %-11s upd=%-4s hot=%-4s %s\n' "$col" "$upd" "$hot" \
    "$( (( hot == 0 )) && echo 'NEVER HOT -> the predicate column blocks it' || echo 'HOT' )"
  # Both sides, or the probe evidences nothing: the predicate column must block
  # HOT outright and the unindexed one must not block it at all.
  if [[ "$col" == pred_col ]]; then
    (( hot == 0 )) || die "pred_col produced $hot HOT updates; a partial index's predicate column should block HOT"
  else
    (( hot == upd )) || die "plain_col produced only $hot HOT of $upd; an unindexed column should never block HOT"
  fi
done
qq "DROP TABLE pred_probe;" >/dev/null

step "Q2a: churn with vacuum unobstructed, at two fillfactors"
# The same statements at fillfactor 100 and 30. Whatever non-HOT survives the
# second is index-blocked; the difference is page pressure. Measuring both is
# what makes the split evidence rather than a subtraction.
churn_arm() {
  local ff="$1" cycles="$2"
  qq "TRUNCATE node_reconcile_queue, node_reconcile_triggers;
      ALTER TABLE node_reconcile_queue SET (fillfactor = $ff);
      ALTER TABLE node_reconcile_triggers SET (fillfactor = $ff);" >/dev/null
  qq "VACUUM FULL node_reconcile_queue, node_reconcile_triggers;" >/dev/null
  qq "SELECT pg_stat_reset();" >/dev/null
  churn "$cycles" >/dev/null
  qq "VACUUM (ANALYZE) node_reconcile_queue, node_reconcile_triggers;" >/dev/null
  arm_upd="$(q "SELECT n_tup_upd FROM pg_stat_user_tables WHERE relname='node_reconcile_queue'")"
  arm_hot="$(q "SELECT n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='node_reconcile_queue'")"
  arm_nonhot=$(( arm_upd - arm_hot ))
  (( arm_upd > 0 )) || die "the fillfactor=$ff arm recorded no updates"
  printf 'fillfactor %3s: %s of %s queue updates non-HOT (%s%%)\n' \
    "$ff" "$arm_nonhot" "$arm_upd" "$(( arm_nonhot * 100 / arm_upd ))"
}
ARM_CYCLES=300
churn_arm 100 "$ARM_CYCLES"
packed_nonhot="$arm_nonhot"
churn_arm 30 "$ARM_CYCLES"
roomy_nonhot="$arm_nonhot"; roomy_upd="$arm_upd"

# Per cycle each node publishes twice: the first enqueue inserts, or no-ops on a
# ref an earlier cycle's race left behind; the second finds both refs queued and
# unclaimed and re-stamps next_attempt_at — a
# key of idx_node_reconcile_queue_claim — in its own transaction. Two refs, so
# two updates per node per cycle that cannot be HOT at any fillfactor.
blocked_floor=$(( 2 * ARM_CYCLES * NODES ))
(( roomy_nonhot >= blocked_floor )) \
  || die "with room on every page only $roomy_nonhot of $roomy_upd updates were non-HOT; at least $blocked_floor are index-blocked"
# Packing can only add non-HOT updates, never remove them -- in expectation.
# Per run it's emergent: which tuple version lands on which page varies, and
# observed deltas have spanned 0 to a few hundred in both directions' noise. So
# the delta is reported, and the assertion carries one cycle's worth of writes
# as tolerance rather than demanding a strict ordering of two noisy counts.
layout_tolerance=$(( 2 * NODES ))
(( packed_nonhot + layout_tolerance >= roomy_nonhot )) \
  || die "a packed page produced $packed_nonhot non-HOT updates against a roomy page's $roomy_nonhot, a gap beyond the $layout_tolerance-update layout tolerance"
# Bound the effect from above as well: packing should not account for a large
# share of updates. The 1% ceiling allows noise while detecting a material
# change in fillfactor sensitivity.
layout_ceiling=$(( roomy_upd / 100 ))
(( packed_nonhot - roomy_nonhot <= layout_ceiling )) \
  || die "packing moved $(( packed_nonhot - roomy_nonhot )) of $roomy_upd updates non-HOT, past the $layout_ceiling ceiling"
printf 'verified: >=%s index-blocked at any fillfactor; packing added %s this run\n' \
  "$blocked_floor" "$(( packed_nonhot - roomy_nonhot ))"
qq "ALTER TABLE node_reconcile_queue RESET (fillfactor);
    ALTER TABLE node_reconcile_triggers RESET (fillfactor);" >/dev/null

step "Q2a-plateau: the footprint stays bounded while vacuum keeps up"
qq "TRUNCATE node_reconcile_queue, node_reconcile_triggers;" >/dev/null
qq "VACUUM FULL node_reconcile_queue, node_reconcile_triggers;" >/dev/null
qq "SELECT pg_stat_reset();" >/dev/null
flat_samples=()
for r in $(seq 1 6); do
  churn 150 >/dev/null
  qq "VACUUM (ANALYZE) node_reconcile_queue, node_reconcile_triggers;" >/dev/null
  flat_now="$(pages idx_node_reconcile_queue_claim)"
  printf 'after %4d cycles: idx_node_reconcile_queue_claim = %s pages\n' \
    $((r * 150)) "$flat_now"
  flat_samples+=("$flat_now")
done
"${PSQL[@]}" -c "
SELECT relname AS table_name, n_live_tup AS live, n_tup_ins AS ins, n_tup_upd AS upd,
       n_tup_hot_upd AS hot_upd, n_tup_del AS del
FROM pg_stat_user_tables
WHERE relname IN ('node_reconcile_queue','node_reconcile_triggers')
ORDER BY relname"
# Indexed arithmetically: bash 3.2, the macOS system bash, has no negative
# array subscripts (and treats one as a fatal error that exits zero).
# early_growth is reported for context and deliberately not asserted -- an
# earlier revision tested "the last third added less than the first third",
# which a series like 100 200 300 350 400 450 satisfies while still ratcheting
# without bound. The assertion below is the stronger one.
last=$(( ${#flat_samples[@]} - 1 ))
flat_end="${flat_samples[$last]}"
early_growth=$(( flat_samples[2] - flat_samples[0] ))
late_growth=$(( flat_end - flat_samples[last - 2] ))
# Stability over the trailing samples, not merely a slower slope: a series like
# 100 200 300 350 400 450 decelerates and still ratchets without bound. Allow a
# 5%-of-footprint wobble for vacuum timing, and at least one page.
tolerance=$(( flat_end / 20 )); (( tolerance < 1 )) && tolerance=1
(( late_growth <= tolerance )) \
  || die "the unobstructed arm never plateaued (${flat_samples[*]}): still added $late_growth pages over the last third, tolerance $tolerance"
printf 'footprint bounded: %s pages, +%s early vs +%s late (tolerance %s)\n' \
  "$flat_end" "$early_growth" "$late_growth" "$tolerance"
t_hot="$(q "SELECT n_tup_hot_upd FROM pg_stat_user_tables WHERE relname='node_reconcile_triggers'")"
t_upd="$(q "SELECT n_tup_upd FROM pg_stat_user_tables WHERE relname='node_reconcile_triggers'")"
# Every deployed writer of the triggers table sets updated_at -- a key of its
# _dead index -- in its own transaction, so the replay above admits no HOT
# update at any fillfactor. This is a property of those statements, not of
# PostgreSQL: two updates to one row inside one transaction write the same
# transaction_timestamp(), leaving updated_at unchanged for the second, which
# is then HOT. No deployed path does that today (the failure update clears
# claim_token, so the release update's `AND claim_token = $2` can no longer
# match), so a non-zero count here means the replay has drifted from the
# deployed statement sequence.
(( t_upd > 0 && t_hot == 0 )) \
  || die "the replayed triggers churn reported $t_hot HOT of $t_upd; every deployed write to that table sets an indexed column in its own transaction, so a HOT update means this replay no longer matches the deployed sequence"
printf 'verified: footprint bounded at %s pages; triggers %s of %s updates non-HOT\n' \
  "$flat_end" "$(( t_upd - t_hot ))" "$t_upd"

step "Q2b: identical churn with the xmin horizon pinned by an unrelated snapshot"
# Reset to Q2a's starting point so the two arms are an A/B rather than a
# continuation: VACUUM FULL rewrites both tables and their indexes, discarding
# Q2a's terminal page count and recycle-pool state.
qq "TRUNCATE node_reconcile_queue, node_reconcile_triggers;" >/dev/null
qq "VACUUM FULL node_reconcile_queue, node_reconcile_triggers;" >/dev/null
qq "SELECT pg_stat_reset();" >/dev/null
printf 'reset to %s pages before the pinned arm\n' "$(pages idx_node_reconcile_queue_claim)"

# Seed a population the churn never touches, so the steady-population assertion
# below is a real comparison. Without it every sample point is an empty table
# and `rows_end == rows_start` holds at zero no matter what the arm does --
# it would pass just as happily if the fixture had drifted to enqueueing
# nothing at all. next_attempt_at is a day out, so the claim's
# `next_attempt_at <= NOW()` never matches these rows; their facet is not one
# the publishes use, so no ON CONFLICT path reaches them either.
qq "INSERT INTO node_reconcile_queue
      (node_id, facet, element, requested_at, next_attempt_at, updated_at)
    SELECT id, 'held-ref', '', NOW(), NOW() + INTERVAL '1 day', NOW()
    FROM nodes WHERE role IN ('worker','builder');" >/dev/null

# The snapshot deliberately reads `nodes` and neither reconcile table: the xmin
# horizon is database-wide, and the arm is meaningless if the pin never starts.
docker exec -d "$CONTAINER" psql -U postgres -d space \
  -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM nodes; SELECT pg_sleep(3600);"
for _ in $(seq 1 15); do
  holders="$(q "SELECT count(*) FROM pg_stat_activity
                WHERE backend_xmin IS NOT NULL AND query LIKE '%pg_sleep(3600)%'
                  AND pid <> pg_backend_pid()")"
  [[ "$holders" == "0" ]] || break
  sleep 1
done
(( holders >= 1 )) || die "the xmin pin never started; Q2b would silently repeat Q2a"
echo "snapshot holders: $holders"
pinned_start=""
rows_start=""
pinned_samples=()
for r in $(seq 1 6); do
  churn 150 >/dev/null
  qq "VACUUM (ANALYZE) node_reconcile_queue, node_reconcile_triggers;" >/dev/null
  pinned_samples+=("$(pages idx_node_reconcile_queue_claim)")
  printf 'after %4d cycles under the pin: idx_node_reconcile_queue_claim = %s pages\n' \
    $((r * 150)) "${pinned_samples[$(( ${#pinned_samples[@]} - 1 ))]}"
  # Baseline both the pages and the population after the first round, so the
  # comparison below is "did it grow at a steady population", not "did it start
  # from empty" — the initial fill would otherwise read as growth.
  if (( r == 1 )); then
    rows_start="$(q 'SELECT count(*) FROM node_reconcile_queue')"
    pinned_start="$(pages idx_node_reconcile_queue_claim)"
  fi
done
pinned_end="$(pages idx_node_reconcile_queue_claim)"
rows_end="$(q 'SELECT count(*) FROM node_reconcile_queue')"
# Both halves of the claim: the index grew, and it grew without the population
# growing. Either failing means this arm shows nothing.
still_pinned="$(q "SELECT count(*) FROM pg_stat_activity
                   WHERE backend_xmin IS NOT NULL AND query LIKE '%pg_sleep(3600)%'
                     AND pid <> pg_backend_pid()")"
(( still_pinned >= 1 )) \
  || die "the xmin pin expired during the arm; the later rounds ran unobstructed"
# The claim is "grows without bound" against the other arm's "converges", which
# is a statement about slope, not about a ratio between two absolutes. An
# earlier form asserted `pinned_end > 3 * flat_end`; that couples two
# independently varying measurements -- flat_end moves with vacuum timing -- and
# a perfectly correct run where the unobstructed arm happened to plateau high
# would fail it. So: it grew after its own steady-population baseline, and it
# was *still* growing in the final third, where the other arm had gone flat.
#
# The third check does still compare the two arms, so be clear about why a
# strict inequality is safe where the 3x ratio was not. It is not the coupling
# that made the ratio brittle, it is the fixed multiple: it magnifies the
# converged arm's drift three-for-one, so the bar moves three pages for every
# page flat_end wanders, and how close that comes to the other arm depends on
# where this run's plateau happened to land. `>` asks for ordering alone, and the two
# assertions above have already pinned the arms on opposite sides of it -- the
# unobstructed one is asserted to have plateaued, this one to be still
# climbing. Observed separation is around 4x (217 against ~910), so the margin
# is wide and, unlike the ratio, it does not shrink when both arms drift the
# same way.
(( pinned_end > pinned_start )) \
  || die "the pinned arm did not grow after its baseline ($pinned_start -> $pinned_end)"
pinned_late_growth=$(( pinned_end - pinned_samples[${#pinned_samples[@]} - 3] ))
(( pinned_late_growth > 0 )) \
  || die "the pinned arm had stopped growing by its final rounds (+$pinned_late_growth pages); that is convergence, not a ratchet"
(( pinned_end > flat_end )) \
  || die "the pinned arm ended at $pinned_end pages, no higher than the unobstructed arm's $flat_end; the pin obstructed nothing"
# The point of the arm: the index grows while the population it indexes does
# not. A steady population with a growing index is the ratchet.
(( rows_start >= 1 )) \
  || die "the arm sampled an empty queue, so a steady population is not what was shown; the seeded held-refs are missing"
(( rows_end == rows_start )) \
  || die "the live row count moved ($rows_start -> $rows_end); the growth is not attributable to the pin"
printf 'verified: %s -> %s pages across the 750 steady-population cycles, live rows steady at %s\n' \
  "$pinned_start" "$pinned_end" "$rows_end"
# Release the pin and vacuum before reading density: the recycle-pool signature
# Gate C looks for only appears once vacuum can process the emptied pages.
q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE query LIKE '%pg_sleep(3600)%' AND pid <> pg_backend_pid()" >/dev/null
# pg_terminate_backend returns once the signal is sent, not once the backend is
# gone, so on a loaded host the VACUUM below can compute its horizon while the
# snapshot is still pinned -- leaving every dead tuple in place and failing the
# density assertion for a reason that is this script's timing, not PostgreSQL's
# behaviour. Wait for the row to disappear, the way Q4b does.
for _ in $(seq 1 30); do
  [[ "$(q "SELECT count(*) FROM pg_stat_activity
           WHERE query LIKE '%pg_sleep(3600)%' AND pid <> pg_backend_pid()")" == "0" ]] && break
  sleep 1
done
[[ "$(q "SELECT count(*) FROM pg_stat_activity
         WHERE query LIKE '%pg_sleep(3600)%' AND pid <> pg_backend_pid()")" == "0" ]] \
  || die "the pinning backend never exited; a VACUUM now would still see its snapshot"
qq "VACUUM (ANALYZE) node_reconcile_queue, node_reconcile_triggers;" >/dev/null
echo "-- after releasing the pin and vacuuming: pages stay, density collapses --"
# One CROSS JOIN LATERAL rather than a subscripted pgstatindex per column: each
# subscripted reference re-executes the function and rescans every page of the
# index, so the two-column form this replaced scanned all nine indexes twice.
# Gate C tells the operator exactly this, and the harness should be the worked
# example of it rather than a counter-example.
"${PSQL[@]}" -c "
SELECT i.relname AS index_name, pg_relation_size(i.oid)/8192 AS pages,
       s.deleted_pages, round(s.avg_leaf_density::numeric, 1) AS avg_leaf_density
FROM pg_index ix
JOIN pg_class c ON c.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
CROSS JOIN LATERAL pgstatindex(i.oid) s
WHERE c.relname IN ('node_reconcile_queue','node_reconcile_triggers')
ORDER BY pages DESC"
# Assert that churn leaves mostly empty index pages on disk. Wide thresholds
# distinguish that shape without pinning the exact density to a particular run.
# One LATERAL call for both columns, and the density threshold evaluated in SQL:
# avg_leaf_density is float8 and reads NaN for an index with no live leaf pages,
# and `NaN < 10` is false in SQL, so an unexpected NaN fails the run rather than
# satisfying the guard.
read -r dens dpages tpages collapsed <<<"$(q "
  SELECT round(s.avg_leaf_density::numeric, 1), s.deleted_pages,
         pg_relation_size(i.oid)/8192,
         (s.avg_leaf_density < 10)
  FROM pg_class i CROSS JOIN LATERAL pgstatindex(i.oid) s
  WHERE i.relname = 'idx_node_reconcile_queue_claim'" | tr '|' ' ')"
[[ "$collapsed" == t ]] \
  || die "leaf density read ${dens}% after the pin released; the recycle-pool collapse Gate C keys on did not happen"
(( tpages > 0 )) || die "no pages to measure density against"
(( dpages * 100 / tpages >= 80 )) \
  || die "only $dpages of $tpages pages are deleted; the emptied-but-retained signature is absent"
printf 'verified: %s%% leaf density with %s of %s pages deleted — emptied, retained, still on disk\n' \
  "$dens" "$dpages" "$tpages"

step "Q3: does VACUUM give the space back?"
# Hold autovacuum off for this section: with naptime at 1s it can truncate the
# heap between the churn and the measurement, which is the very contrast being
# measured, and that made the reading vary run to run.
qq "ALTER TABLE node_reconcile_queue SET (autovacuum_enabled = off);" >/dev/null
churn 150 >/dev/null
# The table is not empty at this point: the held-refs seeded before Q2b never
# drain, and the race cycles leave released refs behind. Clear it, because a
# single live row pins the last heap page and VACUUM truncates nothing, which
# would make the contrast below untestable rather than false.
qq "DELETE FROM node_reconcile_queue;" >/dev/null
printf 'before vacuum: heap = %s pages, idx_node_reconcile_queue_claim = %s pages, live rows = %s\n' \
  "$(pages node_reconcile_queue)" "$(pages idx_node_reconcile_queue_claim)" \
  "$(q 'SELECT count(*) FROM node_reconcile_queue')"
# The heap-truncation contrast only means what it claims on an empty table:
# a residual live row pins the last heap page and VACUUM truncates nothing.
live="$(q 'SELECT count(*) FROM node_reconcile_queue')"
(( live == 0 )) || die "Q3 needs an empty queue to show heap truncation; found $live rows"
heap_before="$(pages node_reconcile_queue)"
index_before="$(pages idx_node_reconcile_queue_claim)"
(( heap_before > 0 )) || die "Q3 measured no heap pages to truncate"
# The index side needs its own floor for the same reason the heap side does:
# the comparison below is index-pages-unchanged, which an empty index satisfies
# at 0 == 0 while proving nothing about whether VACUUM shrinks one.
(( index_before > 0 )) || die "Q3 measured no index pages, so 'the index kept every page' is vacuous"
qq "VACUUM node_reconcile_queue;" >/dev/null
printf 'after  vacuum: heap = %s pages, idx_node_reconcile_queue_claim = %s pages, live rows = %s\n' \
  "$(pages node_reconcile_queue)" "$(pages idx_node_reconcile_queue_claim)" \
  "$(q 'SELECT count(*) FROM node_reconcile_queue')"
(( $(pages node_reconcile_queue) == 0 )) \
  || die "the heap did not truncate to zero; the heap-vs-index contrast is unsupported"
(( $(pages idx_node_reconcile_queue_claim) == index_before )) || die "the index changed size across a plain VACUUM"
qq "ALTER TABLE node_reconcile_queue RESET (autovacuum_enabled);" >/dev/null
echo "expect: the heap truncates to zero, the index keeps every page"

step "Q4a: REINDEX INDEX CONCURRENTLY under concurrent DML, on a bloated index"
qq "INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
    SELECT n.id, 'sandbox-desired-state', g::text, NOW(), NOW()
    FROM nodes n CROSS JOIN generate_series(1, 20000) g
    ON CONFLICT DO NOTHING;" >/dev/null
before_pk="$(pages node_reconcile_queue_pkey)"
printf 'node_reconcile_queue_pkey before: %s pages over %s rows\n' \
  "$before_pk" "$(q 'SELECT count(*) FROM node_reconcile_queue')"
# Runs until /stop-dml appears, so its window is the rebuild's window rather
# than a fixed duration the rebuild finishes inside a fraction of. Errors are
# kept, not discarded: an `err` count of zero has to mean the writes succeeded,
# not that the loop never ran.
docker exec -i "$CONTAINER" tee /dml.sh >/dev/null <<'EOF'
#!/bin/sh
ok=0; err=0
rm -f /stop-dml
: > /dml-errors.log
: > /dml-count
: > /dml-failures
while [ ! -f /stop-dml ]; do
  # ON_ERROR_STOP is redundant for a single -c: psql exits 1 on a SQL error in
  # one -c whatever its setting, and only multiple -c flags or -f need it
  # (measured: single -c 1/1, two -c 0/1, -f 0/3 without/with). It is set
  # anyway because this batch is one edit away from needing it -- split these
  # statements across -c flags and the failure branch below goes blind.
  if out=$(psql -U postgres -d space -qtA -v ON_ERROR_STOP=1 -c "
    INSERT INTO node_reconcile_queue (node_id, facet, element, requested_at, updated_at)
    SELECT id, 'network-policy', 'live-'||floor(random()*1000)::text, NOW(), NOW() FROM nodes LIMIT 5
    ON CONFLICT (node_id, facet, element) DO UPDATE SET next_attempt_at = NOW(), updated_at = NOW();
    UPDATE node_reconcile_queue SET claimed_at = NOW(), claim_token = 'x', updated_at = NOW()
    WHERE facet = 'network-policy' AND element LIKE 'live-%';
    DELETE FROM node_reconcile_queue WHERE facet = 'network-policy' AND claim_token = 'x';
    SELECT extract(epoch from clock_timestamp());
  " 2>>/dml-errors.log); then
    ok=$((ok+1))
    # Only on success, and only psql's own status decides that — a pipeline
    # here would report tail's status instead and make a failed batch look
    # like a clean one.
    printf '%s\n' "$out" | tail -1 >> /dml-count
  else
    err=$((err+1)); echo . >> /dml-failures
  fi
done
echo "$ok $err"
EOF
docker exec "$CONTAINER" chmod +x /dml.sh
docker exec -d "$CONTAINER" sh -c '/dml.sh > /dml.log 2>&1'
docker exec -i "$CONTAINER" tee /sample-locks.sh >/dev/null <<'EOF'
#!/bin/sh
: > /locks.log
rm -f /locks.done
# One row per poll per lock, plus a row with an empty lock when the poll saw
# nothing, so the log yields both a real poll count and a server-side window in
# which the rebuild was observably running -- the client's wall-clock around
# `docker exec` includes process and connection startup, during which the
# backend is not reindexing at all.
#
# The stamp is statement_timestamp(), not clock_timestamp(): these queries
# group, so they emit several rows per poll, and clock_timestamp() is volatile
# and would give each of those rows a different value. Counting distinct stamps
# would then read one poll as several and defeat the degenerate-window check
# further down. statement_timestamp() is fixed for every row of one statement,
# so one distinct stamp means exactly one poll. It is still the server's clock,
# which is the reason for not stamping on the client side.
while [ ! -f /stop-dml ]; do
  sleep 0.01
  psql -U postgres -d space -tA -F'|' -c "
    SELECT extract(epoch from statement_timestamp()),
           coalesce(max(l.mode || ' on ' || c.relname), '')
    FROM pg_stat_activity a
    LEFT JOIN pg_locks l
      ON l.pid = a.pid AND l.locktype = 'relation'
    LEFT JOIN pg_class c ON c.oid = l.relation
    WHERE a.query LIKE 'REINDEX INDEX CONCURRENTLY%'
      AND a.pid <> pg_backend_pid()
    GROUP BY l.mode, c.relname" >> /locks.log
  psql -U postgres -d space -tA -F'|' -c "
    SELECT extract(epoch from statement_timestamp()), ''
    WHERE NOT EXISTS (SELECT 1 FROM pg_stat_activity
                      WHERE query LIKE 'REINDEX INDEX CONCURRENTLY%'
                        AND pid <> pg_backend_pid())" >> /locks.log
done
# Completion marker. The loop exits on /stop-dml, but the iteration in flight
# when that file appears still runs two appends, so the harness must wait for
# this rather than for the writer's /dml.log -- otherwise it can parse
# /locks.log mid-append and read a torn final line or miss the last poll.
echo done > /locks.done
EOF
docker exec "$CONTAINER" chmod +x /sample-locks.sh
docker exec -d "$CONTAINER" /sample-locks.sh
# Wait for the writer's own heartbeat, not for lock samples: the sampler only
# records while a REINDEX is in flight, so waiting on it would block until after
# the rebuild it is meant to observe.
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" test -s /dml-count && break
  sleep 1
done
docker exec "$CONTAINER" test -s /dml-count || die "the concurrent DML loop never started"

# Baseline the writer's unobstructed throughput, for comparison afterwards.
rate_a="$(docker exec "$CONTAINER" sh -c 'wc -l < /dml-count' | tr -d " ")"
sleep 2
rate_b="$(docker exec "$CONTAINER" sh -c 'wc -l < /dml-count' | tr -d " ")"
baseline_rate=$(( (rate_b - rate_a) / 2 ))
# A floor of 10/s rather than 1/s, because the throughput check below is
# expressed as a tenth of this baseline: under 10/s that ratio rounds away and
# the assertion silently stops testing anything. A slower fixture cannot
# support this comparison and must fail rather than skip it.
(( baseline_rate >= 10 )) \
  || die "the DML writer managed only $baseline_rate batches/s before the rebuild; too slow for the throughput comparison to mean anything"
printf 'writer baseline: %s batches/s with no rebuild running\n' "$baseline_rate"

errors_before="$(docker exec "$CONTAINER" sh -c 'wc -l < /dml-failures' | tr -d " ")"
start=$(now_ms)
docker exec -e PGOPTIONS="-c lock_timeout=60s" "$CONTAINER" \
  psql -U postgres -d space -c "REINDEX INDEX CONCURRENTLY public.node_reconcile_queue_pkey"
client_ms=$(( $(now_ms) - start ))
# Stop the writer and wait for it to exit before counting failures: a batch that
# began during the rebuild can fail and record after this point, and reading the
# counter first would print "errors: 0" over a failure landing moments later.
docker exec "$CONTAINER" touch /stop-dml
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" test -s /dml.log && break
  sleep 1
done
docker exec "$CONTAINER" test -s /dml.log || die "the DML writer never exited; its error count is incomplete"
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" test -s /locks.done && break
  sleep 1
done
docker exec "$CONTAINER" test -s /locks.done \
  || die "the lock sampler never exited; /locks.log may be mid-append and its window undercounted"
errors_after="$(docker exec "$CONTAINER" sh -c 'wc -l < /dml-failures' | tr -d " ")"
after_pk="$(pages node_reconcile_queue_pkey)"
printf 'rebuild command took %sms; pkey now %s pages (was %s)\n' "$client_ms" "$after_pk" "$before_pk"
(( after_pk < before_pk )) \
  || die "the rebuild reclaimed nothing ($before_pk -> $after_pk); the reclaim claim is unsupported"

echo "-- distinct locks held during the rebuild, sampled continuously --"
docker exec "$CONTAINER" sh -c "cut -d'|' -f2 /locks.log | sort -u | grep ." \
  || die "the lock sampler never saw the rebuild; the lock inventory is unverified"
docker exec "$CONTAINER" sh -c 'grep -q "ShareUpdateExclusiveLock on node_reconcile_queue$" /locks.log' \
  || die "the sampler never saw the rebuild's table lock; its coverage is unverified"

# The window in which the rebuild was observably running, from the sampler's own
# stamps — not the client's wall-clock, which includes docker and psql startup
# during which the backend is not reindexing.
window_start="$(docker exec "$CONTAINER" sh -c \
  "awk -F'|' '\$2 != \"\" {print \$1}' /locks.log | sort -n | head -1")"
window_end="$(docker exec "$CONTAINER" sh -c \
  "awk -F'|' '\$2 != \"\" {print \$1}' /locks.log | sort -n | tail -1")"
[[ -n "$window_start" && -n "$window_end" ]] \
  || die "no sampler poll observed the rebuild running; the overlap window is undefined"
# Distinct stamps are polls, however many lock rows each produced -- which is
# what statement_timestamp() buys, see the sampler comment above.
samples="$(docker exec "$CONTAINER" sh -c "cut -d'|' -f1 /locks.log | sort -u | wc -l" | tr -d " ")"
# Of those, the ones that actually saw the rebuild holding locks. This is the
# count the overlap window is built from and the one the guard below tests, so
# report it: the margin over that guard's threshold is otherwise invisible.
window_polls="$(docker exec "$CONTAINER" sh -c \
  "awk -F'|' '\$2 != \"\" {print \$1}' /locks.log | sort -u | wc -l" | tr -d " ")"
observed_ms="$(awk -v s="$window_start" -v e="$window_end" 'BEGIN{printf "%d", (e-s)*1000}')"
printf 'sampler: %s polls, %s of them observing the rebuild; it was observably running for %sms of the %sms command\n' \
  "$samples" "$window_polls" "$observed_ms" "$client_ms"
# Count batches whose own completion timestamp falls inside the rebuild's
# window. Exact, and immune to the batches that land between the command
# returning and this read.
overlapped="$(docker exec "$CONTAINER" sh -c \
  "awk -v s=$window_start -v e=$window_end '\$1 >= s && \$1 <= e' /dml-count | wc -l" | tr -d " ")"
new_errors=$(( errors_after - errors_before ))
# Because each batch carries its own completion timestamp, a writer blocked for
# the whole rebuild completes exactly zero inside the window. But zero is also
# reachable when the window is degenerate: each sampler iteration spawns two
# psql processes, so on a fast rebuild only one poll may land inside it, and a
# single-stamp window matches only batches whose stamp is exactly equal to it.
# That would report "the writer was blocked" about a run where nothing was
# wrong. So a point window fails the run rather than skipping the assertion:
# the harness's contract is that exit 0 means every claim held, and a run that
# cannot evidence the concurrency claim has not established it. The margin is
# wide -- the `sleep 0.01` is only a floor, since each iteration also pays two
# psql round-trips, and the observing-poll count printed above has run in the
# tens against this threshold of 2. Reaching it means the sampler could not
# keep up at all, which is itself worth failing on. Host load widens the
# margin rather than narrowing it: it slows the rebuild as well as the poll.
(( window_polls >= 2 )) \
  || die "the sampler observed the rebuild in only $window_polls poll(s), so the overlap window is a single point; this run cannot evidence the concurrent-DML claim"
(( overlapped >= 1 )) \
  || die "no DML batch completed while the rebuild was observably running; the writer was blocked"
during_rate=$(( observed_ms > 0 ? overlapped * 1000 / observed_ms : 0 ))
# The claim is that the writer keeps running, which is stronger than "completed
# at least one batch": a writer that managed a single batch against a 244/s
# baseline was blocked for effectively the whole rebuild and would still pass
# the check above. A tenth of baseline separates sustained progress from a
# near-stall without pinning throughput that varies with host load.
(( during_rate * 10 >= baseline_rate )) \
  || die "the writer managed $during_rate batches/s during the rebuild against a $baseline_rate/s baseline; that is a stall, not concurrent access"
printf 'DML batches completing while the rebuild ran (%sms): %s (%s/s during vs %s/s before), errors: %s\n' \
  "$observed_ms" "$overlapped" "$during_rate" "$baseline_rate" "$new_errors"
if (( new_errors > 0 )); then
  echo "-- DML errors during the rebuild --"
  docker exec "$CONTAINER" sh -c "tail -20 /dml-errors.log"
  die "concurrent DML failed during the rebuild; the concurrency claim is false"
fi
# The table is the object whose lock would block the control plane. An
# ACCESS EXCLUSIVE on the transient _ccnew/_ccold index relations is the swap
# doing its job; catching it depends on sampling luck, so report it, don't fail.
if docker exec "$CONTAINER" grep -q "AccessExclusiveLock on node_reconcile_queue$" /locks.log; then
  die "the rebuild took ACCESS EXCLUSIVE on the table; the blast-radius claim is false"
fi
# This sampler is a tripwire, not a proof: a lock held for less than one poll
# interval is invisible to it. It cannot be turned into a proof by holding a
# conflicting lock from a probe session either -- the rebuild's late phases wait
# out every conflicting holder on the table (the phase is literally named
# "waiting for readers before marking dead"), so the probe only makes the
# rebuild wait on the probe, and the run still cannot tell that apart from the
# rebuild taking a lock of its own. The zero-error DML
# stream is the corroborating evidence: ACCESS EXCLUSIVE on the table would
# block ROW EXCLUSIVE, so writers would have stalled.
if docker exec "$CONTAINER" grep -q "AccessExclusiveLock" /locks.log; then
  echo "note: the sampler caught the swap's ACCESS EXCLUSIVE on a transient index:"
  docker exec "$CONTAINER" sh -c 'grep "AccessExclusiveLock" /locks.log | sort -u | sed "s/^/  /"'
fi
echo "verified: a non-zero overlap with zero errors, and no ACCESS EXCLUSIVE on the table"

step "Q4b: what a cancelled rebuild leaves behind"
docker exec -d "$CONTAINER" psql -U postgres -d space \
  -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM nodes; SELECT pg_sleep(120);"
for _ in $(seq 1 15); do
  holders="$(q "SELECT count(*) FROM pg_stat_activity
                WHERE backend_xmin IS NOT NULL AND query LIKE '%pg_sleep(120)%'
                  AND pid <> pg_backend_pid()")"
  [[ "$holders" == "0" ]] || break
  sleep 1
done
(( holders >= 1 )) || die "the blocking snapshot never started; Q4b cannot demonstrate cancellation"

for attempt in 1 2; do
  echo "-- blocked attempt $attempt --"
  # The rebuild must FAIL here. A success means nothing was blocking it, so the
  # cancellation and the stranded-index behaviour below went undemonstrated.
  if docker exec -e PGOPTIONS="-c lock_timeout=5s" "$CONTAINER" \
       psql -U postgres -d space -v ON_ERROR_STOP=1 \
       -c "REINDEX INDEX CONCURRENTLY public.idx_node_reconcile_queue_requested_at" >"$SCRATCH"/q4b.log 2>&1; then
    die "attempt $attempt succeeded; the rebuild was never blocked"
  fi
  grep -q 'canceling statement due to lock timeout' "$SCRATCH"/q4b.log \
    || { cat "$SCRATCH"/q4b.log; die "attempt $attempt failed for some reason other than lock_timeout"; }
  grep -E 'ERROR' "$SCRATCH"/q4b.log || true
done

"${PSQL[@]}" -c "
SELECT i.relname AS index_name, ix.indisvalid, ix.indisready
FROM pg_index ix
JOIN pg_class c ON c.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
WHERE c.relname = 'node_reconcile_queue' AND NOT ix.indisvalid"
stranded="$(q "SELECT count(*) FROM pg_index ix
               JOIN pg_class c ON c.oid = ix.indrelid
               WHERE c.relname = 'node_reconcile_queue' AND NOT ix.indisvalid")"
(( stranded == 2 )) || die "expected 2 stranded invalid indexes, found $stranded"
original_valid="$(q "SELECT indisvalid FROM pg_index
                     WHERE indexrelid = 'idx_node_reconcile_queue_requested_at'::regclass")"
[[ "$original_valid" == "t" ]] || die "the original index did not stay valid through the cancellations"
echo "verified: one invalid _ccnew index per cancelled attempt; the original stayed valid"
q "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE query LIKE '%pg_sleep(120)%' AND pid <> pg_backend_pid()" >/dev/null

step "Q4c: the documented recovery, and the two transaction-block traps"
# Wait for the terminated holder to actually clear: DROP INDEX CONCURRENTLY
# waits on the table's lockers, so running it too early hangs rather than
# failing. Bound the recovery's lock wait as well.
for _ in $(seq 1 30); do
  [[ "$(q "SELECT count(*) FROM pg_stat_activity
           WHERE query LIKE '%pg_sleep(120)%' AND pid <> pg_backend_pid()")" == "0" ]] && break
  sleep 1
done
for idx in $(q "SELECT i.relname
                FROM pg_index ix
                JOIN pg_class c ON c.oid = ix.indrelid
                JOIN pg_class i ON i.oid = ix.indexrelid
                WHERE c.relname = 'node_reconcile_queue' AND NOT ix.indisvalid"); do
  docker exec -e PGOPTIONS="-c lock_timeout=30s" "$CONTAINER" \
    psql -U postgres -d space -v ON_ERROR_STOP=1 -c "DROP INDEX CONCURRENTLY public.$idx"
done
# Assert the end state, don't just print it: this is the only check that Step
# 4's recovery actually cleared the leftovers, and a per-statement success with
# one index still invalid would otherwise exit 0 with the count in the output.
remaining="$(q "
  SELECT count(*) FROM pg_index ix
  JOIN pg_class c ON c.oid = ix.indrelid
  WHERE c.relname IN ('node_reconcile_queue', 'node_reconcile_triggers')
    AND c.relnamespace = 'public'::regnamespace
    AND NOT ix.indisvalid")"
(( remaining == 0 )) \
  || die "recovery left $remaining invalid index(es) behind; Step 4's drop sequence did not clear the leftovers"
echo "invalid indexes remaining on both reconcile tables: $remaining"
echo "-- REINDEX CONCURRENTLY folded into a transaction by a multi-statement -c --"
trap_out="$(docker exec "$CONTAINER" psql -U postgres -d space \
  -c "SET lock_timeout = '5s'; REINDEX INDEX CONCURRENTLY public.idx_node_reconcile_queue_requested_at;" 2>&1 || true)"
printf '%s\n' "$trap_out" | grep -E 'ERROR' || true
printf '%s\n' "$trap_out" | grep -q 'REINDEX CONCURRENTLY cannot run inside a transaction block' \
  || die "the multi-statement -c form no longer fails; the trap this documents is gone"

echo "-- DROP INDEX CONCURRENTLY inside an explicit transaction --"
trap_out="$(docker exec "$CONTAINER" psql -U postgres -d space \
  -c "BEGIN; DROP INDEX CONCURRENTLY public.idx_node_reconcile_queue_requested_at; COMMIT;" 2>&1 || true)"
printf '%s\n' "$trap_out" | grep -E 'ERROR' || true
printf '%s\n' "$trap_out" | grep -q 'DROP INDEX CONCURRENTLY cannot run inside a transaction block' \
  || die "DROP INDEX CONCURRENTLY no longer refuses a transaction block"
echo "-- the correct form: session settings via PGOPTIONS, one statement per -c --"
docker exec -e PGOPTIONS="-c lock_timeout=30s" "$CONTAINER" \
  psql -U postgres -d space -c "REINDEX INDEX CONCURRENTLY public.idx_node_reconcile_queue_requested_at"

step "done"
COMPLETED=1
