//! Plan-structure and page-shape regression for
//! [`pinned_local_only_sandboxes_query`].
//!
//! The behavioural tests in `inflight_upload_occupancy_tests` cover *which*
//! rows the `:force-upload-local-snapshots` enumeration returns, over fixtures
//! of two or three sandboxes. They cannot see the defect this module guards,
//! because that defect is not about which rows come back — for the node whose
//! forced drain this query family stalled the answer was correctly zero — but
//! about how many rows Postgres reads to decide that.
//!
//! `target_node_id` is a placement diagnostic that suspend never clears, so a
//! long-lived node accumulates every sandbox ever suspended from it. The
//! statement's `ORDER BY` is load-bearing for the operator-visible
//! deferred-tail contract, and it needs an index carrying both the node
//! predicate and the sort key or the planner takes the ordering from the
//! primary key's own index and filters the whole table to answer "nothing".
//!
//! Three properties pin the fix, all read straight off the plan as rows
//! examined or plan structure rather than as timings or costs:
//!
//! 1. **The work is bounded by the node, not the table.**
//!    [`enumeration_reads_only_the_nodes_pinned_rows`] counts the `sandboxes`
//!    rows the plan's scan nodes examined and requires them to stay inside the
//!    node's own pinned history. Deliberately not an assertion about *which*
//!    index: more than one node-bounded plan is acceptable, and pinning the
//!    planner's current choice would fail on a behaviour-preserving change.
//!    [`the_composite_index_is_what_bounds_the_scan`] covers the part that is
//!    not the planner's business — that the composite index is what produces
//!    the bound — by dropping it and requiring the plan to degrade to reading
//!    the whole table.
//! 2. **The durability probe stays un-pullable.**
//!    [`durability_check_stays_an_unpullable_subquery`] asserts the
//!    scalar-subquery fence structurally, as its twin in the node-drain store
//!    does. That one is not about the access path: it stops the planner
//!    realising the durability check as an anti-join over the whole snapshot
//!    catalog after updated statistics change its cost estimate. A cost-based
//!    bias is not evidence.
//! 3. **The in-flight probe reads only the sandboxes it is asked about.**
//!    [`inflight_check_reads_only_the_probed_sandboxes`] counts the `snapshots`
//!    rows the in-flight check examines, across [`PLAN_CASES`], and
//!    requires them to stay within the node's own snapshots. The check is
//!    fenced like the durability one; unfenced, the planner is free to
//!    merge-join it along the snapshots index and read snapshots belonging to
//!    other nodes' sandboxes.
//!
//! [`page_is_the_lowest_ids_and_excludes_non_suspended_rows`] covers the
//! behavioural contract: the page is the ascending-id prefix of the eligible
//! set, so a re-invocation picks up the `deferred[]` tail the previous call
//! published, and a non-suspended row pinned to the node is never an answer.

use pplx_space_common_core::sql;
use pplx_space_common_core::types::{NodeId, SandboxId};
use pplx_space_db_test_fixtures::try_pg_test_db;
use sqlx::PgPool;
use std::num::NonZeroUsize;
use uuid::Uuid;

use super::super::nodes::FORCE_UPLOAD_ENUMERATION_CAP;
use super::{list_pinned_local_only_sandboxes, pinned_local_only_sandboxes_query};

use pplx_space_test_env::TestResult;

/// The production entry point, with the typed ids unwrapped so its answer
/// compares directly against the fixture's raw ones.
async fn list_page(pool: &PgPool, node: Uuid, limit: NonZeroUsize) -> TestResult<Vec<Uuid>> {
    let page = list_pinned_local_only_sandboxes(pool, NodeId::from_uuid(node), limit).await?;
    Ok(page.into_iter().map(SandboxId::as_uuid).collect())
}

/// Suspended rows pinned to the node that already have a durable backup. This
/// is the node's history: large, and entirely uninteresting to the operator.
const DURABLE_HISTORY: usize = 900;

/// Suspended rows pinned to the node with no snapshot at all — the sandboxes
/// the operator is forcing an upload for. More than one page's worth at the
/// page size the ordering test uses, so the prefix property is observable.
const GENUINE_WORK: usize = 7;

/// Non-durable rows pinned to the node in every other lifecycle the column
/// takes on a live node. None of them is an answer, and all of them pass the
/// two shared predicates — `lifecycle = 'suspended'` is the only conjunct that
/// excludes them.
const OTHER_LIFECYCLES: [&str; 4] = ["running", "creating", "stopped", "failed"];

/// Durable suspended rows pinned to *other* nodes. These are the fleet: never
/// an answer to the node under test, and the rows a plan that lost the index
/// would read anyway.
///
/// Sized only so the table dwarfs the node: the bound tests compare rows
/// examined against the node's own pinned rows and the whole table, and they
/// need the two to differ by more than an order of magnitude to tell a
/// node-bounded scan from a fleet-wide one.
const FLEET_ELSEWHERE: usize = 10000;

/// `state='creating'` full snapshots belonging to other nodes' sandboxes.
/// The cluster-wide population is small. They are what
/// the in-flight predicate quantifies over, and the fixture keeps it non-empty
/// so that predicate is planned against the shape production has rather than
/// against an empty join side.
const FOREIGN_INFLIGHT_UPLOADS: usize = 120;

/// Page size the ordering assertions use: smaller than [`GENUINE_WORK`], so a
/// page is a strict prefix of the eligible set.
const SHORT_PAGE: NonZeroUsize = NonZeroUsize::new(3).unwrap();

/// The limit the `:force-upload-local-snapshots` handler actually sends: its
/// cap plus the one sentinel row that signals truncation. The plan tests run
/// at this size as well as [`SHORT_PAGE`], because the literal `LIMIT` is an
/// input to the planner's choice.
const PRODUCTION_PAGE: NonZeroUsize = NonZeroUsize::new(FORCE_UPLOAD_ENUMERATION_CAP + 1).unwrap();

/// Every page size and plan-cache mode the plan tests assert over.
const PLAN_CASES: [(NonZeroUsize, &str); 4] = [
    (SHORT_PAGE, "force_custom_plan"),
    (SHORT_PAGE, "force_generic_plan"),
    (PRODUCTION_PAGE, "force_custom_plan"),
    (PRODUCTION_PAGE, "force_generic_plan"),
];

/// A page comfortably above the backlog, so it returns the whole eligible set
/// and a shorter page is provably a prefix of the same answer.
const FULL_PAGE: NonZeroUsize = NonZeroUsize::new(GENUINE_WORK * 4).unwrap();

/// Insert sandboxes with the supplied ids and matching lifecycles, pinned to
/// `node`, in the order given.
///
/// `placement_changed_at` is non-NULL because it is the correlation the legacy
/// branch of both shared predicates reads; without it those branches take a
/// different path than production's rows do.
///
/// The ids arrive as a slice, in the order given, so the ordering test can
/// insert them descending: a plan that returned rows in physical order would
/// then hand back the highest ids rather than the lowest. `WITH ORDINALITY …
/// ORDER BY t.ord` pins the insertion order to the array order rather than
/// leaving it to `UNNEST`'s unspecified emission order. The composite index
/// already yields the node's rows in id order, so this guards a plan that
/// stops using it; see
/// [`page_is_the_lowest_ids_and_excludes_non_suspended_rows`].
async fn insert_rows(pool: &PgPool, node: Uuid, ids: &[Uuid], lifecycles: &[&str]) -> TestResult {
    sqlx::query(sql!(
        "INSERT INTO sandboxes (
             id, user_id, org_id, lifecycle, placement, managed_by,
             target_node_id, placement_changed_at, lifecycle_changed_at,
             network_policy_generation
         )
         SELECT
             t.id,
             '00000000-0000-0000-0000-000000000010',
             '00000000-0000-0000-0000-000000000001',
             t.lifecycle, 'unplaced', 'k8s',
             $3, NOW() - INTERVAL '30 days', NOW() - INTERVAL '30 days', 1
           FROM UNNEST($1::uuid[], $2::text[]) WITH ORDINALITY AS t(id, lifecycle, ord)
          ORDER BY t.ord"
    ))
    .bind(ids)
    .bind(lifecycles)
    .bind(node)
    .execute(pool)
    .await?;
    Ok(())
}

/// Insert suspended sandboxes with the supplied ids, pinned to `node`.
async fn insert_suspended_rows(pool: &PgPool, node: Uuid, ids: &[Uuid]) -> TestResult {
    insert_rows(pool, node, ids, &vec!["suspended"; ids.len()]).await
}

/// Insert `count` suspended sandboxes pinned to `node` and return their ids.
async fn insert_generated_suspended_rows(
    pool: &PgPool,
    node: Uuid,
    count: usize,
) -> TestResult<Vec<Uuid>> {
    let ids: Vec<Uuid> = (0..count).map(|_| Uuid::now_v7()).collect();
    insert_suspended_rows(pool, node, &ids).await?;
    Ok(ids)
}

/// Insert one non-durable row per entry of [`OTHER_LIFECYCLES`], pinned to
/// `node`.
async fn insert_other_lifecycle_rows(pool: &PgPool, node: Uuid) -> TestResult<Vec<Uuid>> {
    let ids: Vec<Uuid> = OTHER_LIFECYCLES.iter().map(|_| Uuid::now_v7()).collect();
    insert_rows(pool, node, &ids, &OTHER_LIFECYCLES).await?;
    Ok(ids)
}

/// Register a `state='ready'` full snapshot plus its storage-location row for
/// every sandbox in `sandbox_ids`, making each one durable and therefore not an
/// answer.
async fn insert_ready_backups(pool: &PgPool, sandbox_ids: &[Uuid]) -> TestResult {
    sqlx::query(sql!(
        "WITH inserted AS (
             INSERT INTO snapshots (id, sandbox_id, type, state, source_node_id, timestamp)
             SELECT space_uuid_v7(), t.sandbox_id, 'full', 'ready', NULL, NOW()
               FROM UNNEST($1::uuid[]) AS t(sandbox_id)
             RETURNING id
         )
         INSERT INTO snapshot_storage_locations (snapshot_id, storage_connection_string)
         SELECT id, 's3://test-bucket/' || id FROM inserted"
    ))
    .bind(sandbox_ids)
    .execute(pool)
    .await?;
    Ok(())
}

/// Sandboxes on other nodes that [`seed_fleet_below_node`] seeds beneath the
/// node under test, each with a durable snapshot.
const FLEET_BELOW_NODE: usize = 3000;

/// Seed a fleet whose sandbox ids all sort below the node under test, then the
/// node itself, and `ANALYZE`. Returns the node and how many snapshots its own
/// sandboxes carry.
///
/// Ids are UUIDv7, so seeding the fleet first gives it the lower ids. A merge
/// anti-join along `idx_snapshots_sandbox_id` then has to walk the fleet's
/// snapshots to reach the node's, which is what makes that plan visible as
/// reads outside the node. [`seed_fleet`] seeds the fleet last, where the walk
/// passes over only the other node's history.
async fn seed_fleet_below_node(pool: &PgPool) -> TestResult<(Uuid, u64)> {
    let fleet_node = Uuid::now_v7();
    let fleet = insert_generated_suspended_rows(pool, fleet_node, FLEET_BELOW_NODE).await?;
    insert_ready_backups(pool, &fleet).await?;
    sqlx::query(sql!(
        "INSERT INTO snapshots (id, sandbox_id, type, state, source_node_id, timestamp)
         SELECT space_uuid_v7(), t.sandbox_id, 'full', 'creating', $2, NOW()
           FROM UNNEST($1::uuid[]) AS t(sandbox_id)"
    ))
    .bind(&fleet[..FOREIGN_INFLIGHT_UPLOADS])
    .bind(fleet_node)
    .execute(pool)
    .await?;

    let node = Uuid::now_v7();
    let history = insert_generated_suspended_rows(pool, node, DURABLE_HISTORY).await?;
    insert_ready_backups(pool, &history).await?;
    insert_generated_suspended_rows(pool, node, GENUINE_WORK).await?;

    sqlx::query(sql!(
        "ANALYZE sandboxes, snapshots, snapshot_storage_locations"
    ))
    .execute(pool)
    .await?;

    let node_snapshots: i64 = sqlx::query_scalar(sql!(
        "SELECT count(*)
           FROM snapshots sn
           JOIN sandboxes s ON s.id = sn.sandbox_id
          WHERE s.target_node_id = $1"
    ))
    .bind(node)
    .fetch_one(pool)
    .await?;
    Ok((node, u64::try_from(node_snapshots)?))
}

/// What the fixture holds, and which node answers which question.
struct Fleet {
    /// A node carrying nothing but durable history: every suspended row on it
    /// already has a registered snapshot, so the correct answer is the empty
    /// page. This forces the access-path differential to exhaust its scan.
    ///
    /// With no row to return, no plan can satisfy the `LIMIT` early, so the
    /// pkey-ordered scan has to read the whole table however the fixture is
    /// sized. A node that *does* have candidates lets that scan stop as soon as
    /// it reaches them, so a differential measured against one can pass while
    /// measuring nothing if the candidates happen to hold low ids.
    ///
    /// The empty page is also a first-class outcome of this endpoint rather
    /// than an edge case: the handler answers it with its own early return so a
    /// re-invocation is a cheap idempotent ping (`nodes.rs`,
    /// `apply_force_upload_local_snapshots`).
    quiet_node: Uuid,
    /// A node with a real backlog, for the page-shape assertions.
    work_node: Uuid,
    /// `work_node`'s genuine work queue, ascending — the answer the page must
    /// be a prefix of. Inserted in descending order; see
    /// [`insert_rows`].
    work: Vec<Uuid>,
    /// `work_node`'s non-durable rows in other lifecycles. Not answers.
    other_lifecycles: Vec<Uuid>,
    /// Every `sandboxes` row in the fixture.
    total_rows: u64,
    /// Rows pinned to [`Fleet::quiet_node`].
    quiet_node_rows: u64,
}

/// Seed the fixture and `ANALYZE`, so the planner sees it rather than an
/// empty-table default.
///
/// `fleet_elsewhere` is a parameter because only the two bound tests,
/// [`enumeration_reads_only_the_nodes_pinned_rows`] and
/// [`the_composite_index_is_what_bounds_the_scan`], compare against the fleet;
/// the others assert node-local properties and would otherwise pay for inserts
/// they don't read. They pass [`FOREIGN_INFLIGHT_UPLOADS`], which is the floor —
/// the in-flight population is sliced out of the fleet.
async fn seed_fleet(pool: &PgPool, fleet_elsewhere: usize) -> TestResult<Fleet> {
    assert!(
        fleet_elsewhere >= FOREIGN_INFLIGHT_UPLOADS,
        "fleet must cover the in-flight population it is sliced from"
    );
    let quiet_node = Uuid::now_v7();
    let quiet_history = insert_generated_suspended_rows(pool, quiet_node, DURABLE_HISTORY).await?;
    insert_ready_backups(pool, &quiet_history).await?;

    let work_node = Uuid::now_v7();
    let work_history = insert_generated_suspended_rows(pool, work_node, DURABLE_HISTORY).await?;
    insert_ready_backups(pool, &work_history).await?;

    // Descending insertion order: see `insert_rows`.
    let mut work: Vec<Uuid> = (0..GENUINE_WORK).map(|_| Uuid::now_v7()).collect();
    work.sort_unstable();
    let mut descending = work.clone();
    descending.reverse();
    insert_suspended_rows(pool, work_node, &descending).await?;

    let other_lifecycles = insert_other_lifecycle_rows(pool, work_node).await?;

    let fleet_node = Uuid::now_v7();
    let fleet = insert_generated_suspended_rows(pool, fleet_node, fleet_elsewhere).await?;
    insert_ready_backups(pool, &fleet).await?;
    sqlx::query(sql!(
        "INSERT INTO snapshots (id, sandbox_id, type, state, source_node_id, timestamp)
         SELECT space_uuid_v7(), t.sandbox_id, 'full', 'creating', $2, NOW()
           FROM UNNEST($1::uuid[]) AS t(sandbox_id)"
    ))
    .bind(&fleet[..FOREIGN_INFLIGHT_UPLOADS])
    .bind(fleet_node)
    .execute(pool)
    .await?;

    sqlx::query(sql!(
        "ANALYZE sandboxes, snapshots, snapshot_storage_locations"
    ))
    .execute(pool)
    .await?;

    // Read the counts back rather than deriving them from the constants, so a
    // fixture that silently seeded less than it meant to cannot make the bound
    // in `enumeration_reads_only_the_nodes_pinned_rows` trivially true.
    let (total_rows, quiet_node_rows): (i64, i64) = sqlx::query_as(sql!(
        "SELECT count(*), count(*) FILTER (WHERE target_node_id = $1) FROM sandboxes"
    ))
    .bind(quiet_node)
    .fetch_one(pool)
    .await?;

    Ok(Fleet {
        quiet_node,
        work_node,
        work,
        other_lifecycles,
        total_rows: u64::try_from(total_rows)?,
        quiet_node_rows: u64::try_from(quiet_node_rows)?,
    })
}

/// One `EXPLAIN (ANALYZE, FORMAT JSON)` statement's result.
///
/// Typed rather than walked as a `serde_json::Value`, following the shape in
/// `node_drain/store/pinned_local_only_scale_tests.rs`: serde handles the root
/// array, the `Plan` wrapper and the `Plans` nesting declaratively, so a
/// traversal that silently misses one of the three — which reads exactly like
/// "the pathology is absent" — is not expressible.
#[derive(Debug, serde::Deserialize)]
struct Explained {
    #[serde(rename = "Plan")]
    plan: PlanNode,
}

#[derive(Debug, serde::Deserialize)]
struct PlanNode {
    #[serde(rename = "Node Type")]
    node_type: String,
    #[serde(rename = "Relation Name")]
    relation: Option<String>,
    #[serde(rename = "Actual Rows", default)]
    rows: u64,
    #[serde(rename = "Rows Removed by Filter", default)]
    rows_removed: u64,
    #[serde(rename = "Actual Loops", default)]
    loops: u64,
    #[serde(rename = "Index Cond")]
    index_cond: Option<String>,
    #[serde(rename = "Recheck Cond")]
    recheck_cond: Option<String>,
    #[serde(rename = "Filter")]
    filter: Option<String>,
    #[serde(rename = "Plans", default)]
    children: Vec<PlanNode>,
}

impl PlanNode {
    /// How many `sandboxes` rows the plan's scan nodes actually examined: the
    /// rows they emitted plus the rows their own filter discarded, summed over
    /// every scan of the table and multiplied by the loop count so a parallel
    /// plan's per-worker averages add up to the real total.
    ///
    /// This is the quantity the change is about, and it is what the admin
    /// handler's latency is made of. It is also deliberately the *only* thing
    /// asserted about the plan's shape here: which index the planner reaches
    /// for is its business, and more than one node-bounded plan is acceptable.
    /// A wall-clock assertion would be a flake and a cost assertion moves with
    /// every planner release; rows examined is the contract.
    fn sandbox_rows_examined(&self) -> u64 {
        let own = if self.relation.as_deref() == Some("sandboxes") {
            (self.rows + self.rows_removed) * self.loops.max(1)
        } else {
            0
        };
        own + self
            .children
            .iter()
            .map(PlanNode::sandbox_rows_examined)
            .sum::<u64>()
    }

    /// Is the durability probe planned inside a scalar subquery?
    ///
    /// True iff some `Result` node — which is how Postgres realises a scalar
    /// subquery — has the `snapshot_storage_locations` access somewhere beneath
    /// it. Unfenced, that access hangs off a top-level join instead.
    fn durability_probe_is_fenced(&self) -> bool {
        fn reaches_storage_locations(node: &PlanNode) -> bool {
            node.relation.as_deref() == Some("snapshot_storage_locations")
                || node.children.iter().any(reaches_storage_locations)
        }
        (self.node_type == "Result" && reaches_storage_locations(self))
            || self
                .children
                .iter()
                .any(PlanNode::durability_probe_is_fenced)
    }

    /// How many `snapshots` rows the in-flight check examined: every scan of
    /// the table whose conditions name `state = 'creating'`, counted the same
    /// way as [`PlanNode::sandbox_rows_examined`]. The durability probe reads
    /// `snapshots` too, but never filters on `creating`, so it is not counted.
    fn inflight_probe_rows_examined(&self) -> u64 {
        let own = if self.names_creating() {
            (self.rows + self.rows_removed) * self.loops.max(1)
        } else {
            0
        };
        own + self
            .children
            .iter()
            .map(PlanNode::inflight_probe_rows_examined)
            .sum::<u64>()
    }

    /// How many times the in-flight check's `snapshots` scans executed, summed.
    fn inflight_probe_loops(&self) -> u64 {
        let own = if self.names_creating() {
            self.loops.max(1)
        } else {
            0
        };
        own + self
            .children
            .iter()
            .map(PlanNode::inflight_probe_loops)
            .sum::<u64>()
    }

    /// Does the plan contain the in-flight check's `snapshots` scan at all?
    fn reaches_inflight_probe(&self) -> bool {
        self.names_creating() || self.children.iter().any(PlanNode::reaches_inflight_probe)
    }

    /// Is this a `snapshots` scan whose conditions name `state = 'creating'`?
    fn names_creating(&self) -> bool {
        self.relation.as_deref() == Some("snapshots")
            && [&self.index_cond, &self.recheck_cond, &self.filter]
                .into_iter()
                .flatten()
                .any(|cond| cond.contains("'creating'"))
    }
}

/// `EXPLAIN (ANALYZE, FORMAT JSON)` one statement against `node`.
async fn explain(pool: &PgPool, query: &str, node: Uuid) -> TestResult<PlanNode> {
    // `TIMING OFF`: every assertion here reads row counts or node types, which
    // per-node timing does not affect, and instrumenting a subplan that runs
    // once per pinned row costs more than the plan does.
    let statement = format!("EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) {query}");
    let raw: serde_json::Value = sqlx::query_scalar(sqlx::AssertSqlSafe(sql!(statement.as_str())))
        .bind(node)
        .fetch_one(pool)
        .await?;
    let mut explained: Vec<Explained> = serde_json::from_value(raw)?;
    Ok(explained.pop().ok_or("EXPLAIN returned no plan")?.plan)
}

/// `EXPLAIN (ANALYZE, FORMAT JSON)` one statement against `node` under a
/// forced `plan_cache_mode`.
///
/// [`explain`] can't exercise a generic plan: a bound parameter reaches the
/// planner as a value, so every plan it produces is a custom one. A generic
/// plan only exists for a prepared statement, so this prepares the query on
/// a connection of its own, forces the mode there, and explains its `EXECUTE`.
async fn explain_prepared(
    pool: &PgPool,
    query: &str,
    node: Uuid,
    plan_cache_mode: &str,
) -> TestResult<PlanNode> {
    use sqlx::Connection as _;

    // Detached, so the prepared statement and the forced mode leave with this
    // connection instead of going back to the pool, however this returns.
    let mut conn = pool.acquire().await?.detach();
    let prepare = format!("PREPARE enumeration(uuid) AS {query}");
    sqlx::query(sqlx::AssertSqlSafe(sql!(prepare.as_str())))
        .execute(&mut conn)
        .await?;
    let set_mode = format!("SET plan_cache_mode = {plan_cache_mode}");
    sqlx::query(sqlx::AssertSqlSafe(sql!(set_mode.as_str())))
        .execute(&mut conn)
        .await?;
    // `EXECUTE` takes no bind parameters of its own, so the node id is a
    // literal here; it is a fixture-generated UUID, never external input.
    let statement =
        format!("EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) EXECUTE enumeration('{node}')");
    let raw: serde_json::Value = sqlx::query_scalar(sqlx::AssertSqlSafe(sql!(statement.as_str())))
        .fetch_one(&mut conn)
        .await?;
    conn.close().await?;
    let mut explained: Vec<Explained> = serde_json::from_value(raw)?;
    Ok(explained.pop().ok_or("EXPLAIN returned no plan")?.plan)
}

/// The property: an operator forcing uploads on one node must not make
/// Postgres read rows that belong to other nodes. That is read straight off the
/// plan as rows examined, so it holds at any fixture size rather than at a
/// calibrated one.
///
/// Asked against [`Fleet::quiet_node`], whose answer is the empty page. That is
/// the shape the defect lived in: with no row to return there is nothing for a
/// `LIMIT` to stop early on, so a plan that gets its ordering from the primary
/// key has to read the whole table before it can answer "nothing". It is also
/// the ordinary answer — what an operator gets once the backlog has cleared.
#[tokio::test(flavor = "current_thread")]
async fn enumeration_reads_only_the_nodes_pinned_rows() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &db.pool;
    let fleet = seed_fleet(pool, FLEET_ELSEWHERE).await?;
    let node = fleet.quiet_node;
    let pinned_rows = fleet.quiet_node_rows;
    let total_rows = fleet.total_rows;

    // The fixture has to hold enough rows elsewhere for "the node's rows" and
    // "the table's rows" to be distinguishable at all.
    assert!(
        total_rows > pinned_rows * 10,
        "fixture is too uniform to separate a node-bounded scan from a fleet-wide one: \
         {pinned_rows} of {total_rows} rows are pinned to the node under test"
    );

    // Both plan-cache modes, because sqlx prepares the statement and a pooled
    // connection may switch it to a generic plan, and both page sizes, because
    // the literal `LIMIT` feeds the plan choice. The index alone does not hold
    // the bound in both: without the fences, the generic plan on this fixture
    // reads the whole table even with the composite index present.
    for (page, plan_cache_mode) in PLAN_CASES {
        let query = pinned_local_only_sandboxes_query(page);
        let plan = explain_prepared(pool, &query, node, plan_cache_mode).await?;
        assert!(
            plan.sandbox_rows_examined() <= pinned_rows,
            "the enumeration must read no more `sandboxes` rows than the node's own \
             pinned history ({pinned_rows}) (LIMIT {page}, {plan_cache_mode}); it \
             examined {} of {total_rows}. Plan was {plan:?}",
            plan.sandbox_rows_examined()
        );
    }
    Ok(())
}

/// The index is what bounds the scan, and this proves it rather than asserting
/// it.
///
/// The statement and the migration that indexes for it ship separately — the
/// repository forbids a migration beside runtime code in one change — so
/// nothing else in the tree records that they are coupled.
///
/// Checked at runtime, inside this test's own cloned database: drop the index
/// and the plan must degrade to reading the whole table. Doing it here rather
/// than by editing the migration keeps both halves of the differential in one
/// database and one run, and proves the index is present in a *migrated*
/// database rather than only present in a `.sql` file. It degrades that way
/// rather than by sorting, which is worth knowing — the primary key supplies
/// `id` order too, so the planner does not need a `Sort` to answer this query
/// without the composite. It just has to
/// read every row to do it, which is the entire defect. An assertion about a
/// `Sort` appearing would therefore be false, and an assertion that the
/// dropped index is no longer used would be true by construction.
///
/// Measured at [`SHORT_PAGE`] only. Whether the planner falls back to the
/// primary key or to the narrow index plus a sort depends on the page size
/// relative to the table: at [`PRODUCTION_PAGE`] against this fixture's table,
/// the sort is the cheaper fallback and still node-bounded, so the defect
/// doesn't reproduce there. A larger table can change that cost choice.
#[tokio::test(flavor = "current_thread")]
async fn the_composite_index_is_what_bounds_the_scan() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &db.pool;
    let fleet = seed_fleet(pool, FLEET_ELSEWHERE).await?;
    let node = fleet.quiet_node;

    let with_index = explain(pool, &pinned_local_only_sandboxes_query(SHORT_PAGE), node).await?;
    let bounded = with_index.sandbox_rows_examined();
    assert!(
        bounded <= fleet.quiet_node_rows,
        "precondition: with the composite index the scan must stay inside the node's \
         {} pinned rows, but it examined {bounded}; the differential below proves \
         nothing otherwise. Plan was {with_index:?}",
        fleet.quiet_node_rows
    );

    sqlx::query(sql!("DROP INDEX idx_sandboxes_target_node_ordered"))
        .execute(pool)
        .await?;
    sqlx::query(sql!("ANALYZE sandboxes")).execute(pool).await?;

    let without_index = explain(pool, &pinned_local_only_sandboxes_query(SHORT_PAGE), node).await?;
    let unbounded = without_index.sandbox_rows_examined();
    assert!(
        unbounded >= fleet.total_rows,
        "dropping `idx_sandboxes_target_node_ordered` must send this statement back to \
         reading the whole table — that is the defect the index exists to \
         remove. It examined {unbounded} of {} rows, so either \
         the index is not load-bearing or this fixture no longer reproduces the \
         defect, or the statement lost its `ORDER BY` and so no longer needs the \
         primary key's ordering. Plan was {without_index:?}",
        fleet.total_rows
    );
    Ok(())
}

/// The durability `NOT EXISTS` is wrapped in a scalar subquery so the planner
/// *cannot* realise it as a hash or merge anti-join over the whole
/// `snapshots` ⋈ `snapshot_storage_locations` product — only as a per-row
/// `SubPlan` whose own `sn.sandbox_id = s.id` makes each execution an index
/// probe.
///
/// A `LIMIT` alone can make the nested loop cheaper, but updated statistics
/// can shift the outer row estimate and favor a merge anti-join over the whole
/// snapshot catalog. The guard must be structural rather than a timing or cost
/// assertion.
#[tokio::test(flavor = "current_thread")]
async fn durability_check_stays_an_unpullable_subquery() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &db.pool;
    let fleet = seed_fleet(pool, FOREIGN_INFLIGHT_UPLOADS).await?;

    for (page, plan_cache_mode) in PLAN_CASES {
        let query = pinned_local_only_sandboxes_query(page);
        let plan = explain_prepared(pool, &query, fleet.work_node, plan_cache_mode).await?;
        assert!(
            plan.durability_probe_is_fenced(),
            "the durability check must be planned inside a scalar subquery (a `Result` \
             node above the `snapshot_storage_locations` access), not as a join the \
             planner is free to re-cost into a hash or merge anti-join (LIMIT {page}, \
             {plan_cache_mode}); plan was {plan:?}"
        );
    }
    Ok(())
}

/// The in-flight check is fenced like the durability check, so each
/// execution looks up the one sandbox being asked about and never reads
/// another node's snapshots.
///
/// Unfenced, it is a sublink the planner may pull up into an anti-join. The
/// node-ordered scan makes a merge anti-join along `idx_snapshots_sandbox_id`
/// available, and on this fixture the planner takes it in both plan-cache
/// modes: it walks every snapshot whose sandbox id sorts below the page,
/// whichever node that sandbox belongs to. [`seed_fleet_below_node`] puts the
/// whole fleet below the node, so that walk reads the fleet's snapshots.
///
/// The bound is the node's own snapshots plus one per execution of the probe.
/// The fenced probe only ever reads the probed sandbox's snapshots, so it
/// stays inside the first term; the second absorbs `EXPLAIN`'s per-loop
/// rounding, which can add up to one row per execution. Both terms are fixed
/// by the node and the probe, not by how many rows a regressed plan scans, so
/// a merge walk over the fleet, which executes once, exceeds it. It holds
/// whichever order Postgres evaluates the two probes in.
///
/// What it does not catch is a fenced probe that scans the whole in-flight set
/// on each execution: when the durability check runs first, few rows reach
/// the probe, and the reads can stay under the bound.
#[tokio::test(flavor = "current_thread")]
async fn inflight_check_reads_only_the_probed_sandboxes() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &db.pool;
    let (node, node_snapshots) = seed_fleet_below_node(pool).await?;
    for (page, plan_cache_mode) in PLAN_CASES {
        let query = pinned_local_only_sandboxes_query(page);
        let plan = explain_prepared(pool, &query, node, plan_cache_mode).await?;
        assert!(
            plan.reaches_inflight_probe(),
            "the in-flight check's `snapshots` scan must be found in the plan, or \
             the count below proves nothing (LIMIT {page}, {plan_cache_mode}); plan \
             was {plan:?}"
        );
        let executions = plan.inflight_probe_loops();
        let read = plan.inflight_probe_rows_examined();
        let bound = node_snapshots + executions;
        assert!(
            read <= bound,
            "the in-flight check must read only the probed sandboxes' snapshots \
             (LIMIT {page}, {plan_cache_mode}): it read {read} snapshot rows, above the \
             node's own {node_snapshots} plus {executions} for rounding. Plan was {plan:?}"
        );
    }
    Ok(())
}

/// Two properties the statement has to preserve, and one it could break.
///
/// **The page is the ascending-id prefix.** The handler processes the head of
/// the page and publishes the rest as `deferred[]`, so the operator's next call
/// has to pick up where this one stopped rather than resample. The fixture
/// inserts the work rows in *descending* id order, so a plan that returned
/// physical order would give the highest ids, not the lowest.
///
/// What this does **not** reliably prove is the `ORDER BY` itself. Without the
/// clause the page's order is whatever index the planner picks: the composite
/// index returns id order and these assertions stay green, the narrow index
/// returns physical order and they fail. The clause is still load-bearing: it
/// makes the
/// ordering a requirement the planner has to satisfy rather than a property of
/// whichever plan it happens to pick, and a plan that stopped using the index
/// would return an unordered page without it. That argument is not something a
/// fixture at this scale can demonstrate, so it is recorded here rather than
/// asserted. Deleting the `ORDER BY` does fail
/// [`the_composite_index_is_what_bounds_the_scan`], which is what catches the
/// edit in practice.
///
/// **The cap is a page size, not a filter.** A full page returns exactly the
/// eligible set, so a short page is a prefix of the same answer rather than a
/// different one.
///
/// **A non-suspended row is still not an answer.** The fixture seeds a
/// non-durable row in every other lifecycle a live node carries, and checks
/// both directions: the page excludes them, and those rows are separately
/// shown to be pinned to this node with no snapshot at all, so every predicate
/// except `lifecycle = 'suspended'` admits them. Without the second half the
/// exclusion could hold because the shared predicates had already dropped
/// them, and force-uploading a *running* sandbox — reading its live snapshot
/// directory underneath it — would be invisible here.
#[tokio::test(flavor = "current_thread")]
async fn page_is_the_lowest_ids_and_excludes_non_suspended_rows() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &db.pool;
    let fleet = seed_fleet(pool, FOREIGN_INFLIGHT_UPLOADS).await?;
    let node = fleet.work_node;
    let work_ascending = fleet.work;
    let other_lifecycles = fleet.other_lifecycles;

    // Through the production entry point rather than a re-implementation of it:
    // these are the only assertions here that describe what an operator
    // receives, so they have to exercise the bind and the `sql!` site the
    // handler actually uses.
    let full_page = list_page(pool, node, FULL_PAGE).await?;
    assert_eq!(
        full_page,
        work_ascending,
        "a page above the backlog must return exactly the node's non-durable suspended \
         rows, in ascending id order; {DURABLE_HISTORY} rows of durable history and \
         {} non-suspended rows must not leak in",
        other_lifecycles.len()
    );

    let short_page = list_page(pool, node, SHORT_PAGE).await?;
    assert_eq!(
        short_page,
        work_ascending[..SHORT_PAGE.get()],
        "a page below the backlog must be the lowest ids of the same answer — that \
         prefix is what makes the handler's `deferred[]` tail the work the next \
         call picks up"
    );
    // Re-running an unchanged query proves nothing, so move the head instead:
    // a newly eligible sandbox with a lower id than everything on the page must
    // lead the next one. That is the property `deferred[]` rests on — the page
    // is a position in an ordering, not a sample — and it is what a page that
    // merely reflected physical or insertion order would get wrong.
    let intruder = Uuid::parse_str("00000000-0000-0000-0000-000000000001")?;
    insert_suspended_rows(pool, node, &[intruder]).await?;
    let after = list_page(pool, node, SHORT_PAGE).await?;
    assert_eq!(
        after.first(),
        Some(&intruder),
        "a newly eligible sandbox whose id sorts below the whole page must lead \
         the next page; got {after:?}"
    );
    assert_eq!(
        &after[1..],
        &short_page[..SHORT_PAGE.get() - 1],
        "and the rest of the page must shift down by one rather than resample"
    );

    // The exclusion above is only evidence if those rows would otherwise be
    // answers. They are pinned to this node and carry no snapshot at all, so
    // they are non-durable with no upload in flight — every predicate except
    // the lifecycle one admits them. Asserted against the fixture's own state
    // rather than by rewriting the statement's SQL, which would fail on a
    // reformat that changed no behaviour.
    let (pinned_here, with_snapshots): (i64, i64) = sqlx::query_as(sql!(
        "SELECT count(*) FILTER (WHERE s.target_node_id = $2),
                count(*) FILTER (WHERE EXISTS (
                    SELECT 1 FROM snapshots sn WHERE sn.sandbox_id = s.id
                ))
           FROM sandboxes s
          WHERE s.id = ANY($1)"
    ))
    .bind(&other_lifecycles)
    .bind(node)
    .fetch_one(pool)
    .await?;
    assert_eq!(
        (pinned_here, with_snapshots),
        (i64::try_from(other_lifecycles.len())?, 0),
        "the non-suspended rows must all be pinned to this node and carry no \
         snapshot, or their absence from the page holds for some reason other than \
         the lifecycle predicate and proves nothing"
    );
    Ok(())
}
