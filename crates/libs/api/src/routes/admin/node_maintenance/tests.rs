use pplx_space_common_core::types::NodeId;

use super::*;
use pplx_space_db_test_fixtures::try_pg_test_db;

use pplx_space_test_env::TestResult;

async fn row_count(pool: &sqlx::PgPool, table: &str, node_id: NodeId) -> Result<i64, sqlx::Error> {
    let query = match table {
        "node_direct" => "SELECT COUNT(*) FROM node_direct WHERE node_id = $1",
        "node_template_inventory" => {
            "SELECT COUNT(*) FROM node_template_inventory WHERE node_id = $1"
        }
        "node_status_snapshots" => "SELECT COUNT(*) FROM node_status_snapshots WHERE node_id = $1",
        "node_runtime_installations" => {
            "SELECT COUNT(*) FROM node_runtime_installations WHERE node_id = $1"
        }
        "node_facet_observed_status" => {
            "SELECT COUNT(*) FROM node_facet_observed_status WHERE node_id = $1"
        }
        "node_reconcile_triggers" => {
            "SELECT COUNT(*) FROM node_reconcile_triggers WHERE node_id = $1"
        }
        _ => unreachable!("unknown test table {table}"),
    };
    sqlx::query_scalar::<_, i64>(query)
        .bind(node_id)
        .fetch_one(pool)
        .await
}

#[tokio::test(flavor = "current_thread")]
async fn hard_delete_direct_node_removes_node_and_projection_rows() -> TestResult {
    let Some(db) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &db.pool;
    let node_id = NodeId::new();
    let template_id = uuid::Uuid::now_v7();

    sqlx::query(sql!(
        "INSERT INTO nodes (id, address, role, managed_by, state)
         VALUES ($1, '10.0.0.12'::INET, 'worker', 'space', 'registered')"
    ))
    .bind(node_id)
    .execute(pool)
    .await?;
    sqlx::query(sql!(
        "INSERT INTO node_direct (node_id, name, node_api_endpoint)
         VALUES ($1, 'worker-1', '10.0.0.12:9802')"
    ))
    .bind(node_id)
    .execute(pool)
    .await?;
    sqlx::query(sql!(
        "INSERT INTO templates (id, name, org_id)
         VALUES ($1, 'node-delete-test', '00000000-0000-0000-0000-000000000001')"
    ))
    .bind(template_id)
    .execute(pool)
    .await?;
    sqlx::query(
        sql!("INSERT INTO node_template_inventory (node_id, template_name, content_hash, runtime, arch)
         VALUES ($1, 'node-delete-test', 'sha256:1111111111111111111111111111111111111111111111111111111111111111', 'fc', 'aarch64')"),
    )
    .bind(node_id)
    .execute(pool)
    .await?;
    sqlx::query(sql!(
        "INSERT INTO node_status_snapshots (
             node_id, observed_at, stale_after, reachable, services, updated_at
         )
         VALUES ($1, NOW(), NOW() + INTERVAL '1 hour', TRUE, '[]'::JSONB, NOW())"
    ))
    .bind(node_id)
    .execute(pool)
    .await?;
    sqlx::query(sql!(
        "INSERT INTO node_runtime_installations (node_id, runtime, runtime_version)
         VALUES ($1, 'fc', '1.0.0')"
    ))
    .bind(node_id)
    .execute(pool)
    .await?;
    sqlx::query(sql!(
        "INSERT INTO node_facet_observed_status (node_id, facet, element, observed_at)
         VALUES ($1, 'template_inventory', '', NOW())"
    ))
    .bind(node_id)
    .execute(pool)
    .await?;
    sqlx::query(sql!(
        "INSERT INTO node_reconcile_triggers (node_id, reason)
         VALUES ($1, 'node_updated')"
    ))
    .bind(node_id)
    .execute(pool)
    .await?;

    let deleted = hard_delete_direct_node(pool, node_id).await?;
    assert_eq!(deleted, 1);

    let nodes: i64 = sqlx::query_scalar(sql!("SELECT COUNT(*) FROM nodes WHERE id = $1"))
        .bind(node_id)
        .fetch_one(pool)
        .await?;
    assert_eq!(nodes, 0);
    for table in [
        "node_direct",
        "node_template_inventory",
        "node_status_snapshots",
        "node_runtime_installations",
        "node_facet_observed_status",
        "node_reconcile_triggers",
    ] {
        assert_eq!(
            row_count(pool, table, node_id).await?,
            0,
            "{table} should cascade with node deletion"
        );
    }

    let deleted_again = hard_delete_direct_node(pool, node_id).await?;
    assert_eq!(deleted_again, 0);
    Ok(())
}
