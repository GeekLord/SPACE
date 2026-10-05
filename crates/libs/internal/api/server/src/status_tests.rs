use pplx_space_common_core::types::{NodeId, SandboxId};

use super::*;
use pplx_space_db_test_fixtures::{insert_ready_worker_node, try_pg_test_db};

use pplx_space_test_env::TestResult;

async fn insert_space_sandbox(
    pool: &sqlx::PgPool,
    sandbox_id: SandboxId,
    node_id: NodeId,
) -> TestResult {
    sqlx::query(
        "INSERT INTO sandboxes (
             id, user_id, org_id, lifecycle, placement, active_node_id,
             target_node_id, managed_by, network_policy_generation
         )
         VALUES (
             $1,
             '00000000-0000-0000-0000-000000000010',
             '00000000-0000-0000-0000-000000000001',
             'started',
             'on_node',
             $2,
             $2,
             'space',
             1
         )",
    )
    .bind(sandbox_id)
    .bind(node_id)
    .execute(pool)
    .await?;
    Ok(())
}

#[tokio::test(flavor = "current_thread")]
async fn complete_inventory_marks_missing_space_sandbox_deleted() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let node_id = NodeId::new();
    let sandbox_id = SandboxId::new();
    insert_ready_worker_node(&db.pool, node_id).await?;
    insert_space_sandbox(&db.pool, sandbox_id, node_id).await?;

    let mut conn = db.pool.acquire().await?;
    prune_absent_node_sandboxes(&mut conn, node_id, &[]).await?;
    drop(conn);

    let (lifecycle, placement, active_node_id, target_node_id): (
        String,
        String,
        Option<NodeId>,
        Option<NodeId>,
    ) = sqlx::query_as(
        "SELECT lifecycle, placement, active_node_id, target_node_id
         FROM sandboxes
         WHERE id = $1",
    )
    .bind(sandbox_id)
    .fetch_one(&db.pool)
    .await?;

    assert_eq!(lifecycle, "deleted");
    assert_eq!(placement, "unplaced");
    assert_eq!(active_node_id, None);
    assert_eq!(target_node_id, None);
    Ok(())
}
