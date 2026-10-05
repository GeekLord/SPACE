use pplx_space_common_core::types::NodeId;

use pplx_space_db_test_fixtures::try_pg_test_db;

use super::*;

use pplx_space_test_env::TestResult;

async fn insert_terminating_k8s_node(
    pool: &PgPool,
    node_id: NodeId,
    node_name: &str,
) -> TestResult {
    sqlx::query(sql!(
        "INSERT INTO nodes (id, address, role, managed_by, state, drain_phase, drain_started_at)
         VALUES ($1, '10.0.0.99'::inet, 'worker', 'k8s', 'registered', 'terminating', NOW())"
    ))
    .bind(node_id)
    .execute(pool)
    .await?;
    sqlx::query(sql!(
        "INSERT INTO node_k8s (node_id, k8s_node_name, k8s_node_uid)
         VALUES ($1, $2, 'kube-uid')"
    ))
    .bind(node_id)
    .bind(node_name)
    .execute(pool)
    .await?;
    Ok(())
}

/// Deleting a terminating node leaves a tombstone keyed on the
/// deterministic SPACE node id, even after the `node_k8s` CASCADE
/// drops `k8s_node_name`. Without the tombstone, the daemon on the
/// still-running EC2 would re-bootstrap the row on its next heartbeat
/// and the orchestrator would re-drain the same node.
#[tokio::test(flavor = "current_thread")]
async fn delete_terminating_node_inserts_tombstone() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let node_id = NodeId::new();
    let node_name = format!("space-test-node-{}", node_id.as_uuid().simple());
    insert_terminating_k8s_node(&db.pool, node_id, &node_name).await?;

    let deleted = delete_terminating_node_and_record_tombstone(&db.pool, node_id).await?;
    assert!(deleted, "expected terminating row to be deleted");

    let remaining: i64 = sqlx::query_scalar(sql!("SELECT COUNT(*) FROM nodes WHERE id = $1"))
        .bind(node_id)
        .fetch_one(&db.pool)
        .await?;
    assert_eq!(remaining, 0, "nodes row must be gone");

    let (tomb_name, role, reason): (String, String, Option<String>) = sqlx::query_as(sql!(
        "SELECT k8s_node_name, role, reason FROM node_k8s_tombstones WHERE node_id = $1"
    ))
    .bind(node_id)
    .fetch_one(&db.pool)
    .await?;
    assert_eq!(tomb_name, node_name);
    assert_eq!(role, "worker");
    assert_eq!(reason.as_deref(), Some("admin-terminate"));
    Ok(())
}

/// A node not in `terminating` (operator undrained between
/// `:terminate` and the reconciler tick) must be left alone and no
/// tombstone written.
#[tokio::test(flavor = "current_thread")]
async fn delete_terminating_node_is_noop_when_phase_drifted() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let node_id = NodeId::new();
    sqlx::query(sql!(
        "INSERT INTO nodes (id, address, role, managed_by, state, drain_phase)
         VALUES ($1, '10.0.0.99'::inet, 'worker', 'k8s', 'registered', NULL)"
    ))
    .bind(node_id)
    .execute(&db.pool)
    .await?;

    let deleted = delete_terminating_node_and_record_tombstone(&db.pool, node_id).await?;
    assert!(!deleted, "phase != terminating must be a no-op");

    let still_present: i64 = sqlx::query_scalar(sql!("SELECT COUNT(*) FROM nodes WHERE id = $1"))
        .bind(node_id)
        .fetch_one(&db.pool)
        .await?;
    assert_eq!(still_present, 1, "row must survive the no-op");

    let tomb_count: i64 = sqlx::query_scalar(sql!(
        "SELECT COUNT(*) FROM node_k8s_tombstones WHERE node_id = $1"
    ))
    .bind(node_id)
    .fetch_one(&db.pool)
    .await?;
    assert_eq!(tomb_count, 0, "no tombstone for a no-op delete");
    Ok(())
}
