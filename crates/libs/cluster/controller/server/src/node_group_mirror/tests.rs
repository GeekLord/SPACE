use pplx_space_common_core::types::NodeId;

use pplx_space_common_core::types::NodeGroupId;
use pplx_space_db_test_fixtures::{TestDbResult, try_pg_test_db};
use sqlx::PgPool;

use super::apply_mirror;

type TestResult<T = ()> = TestDbResult<T>;

async fn insert_node(pool: &PgPool, k8s_node_name: &str) -> TestResult<NodeId> {
    insert_node_with_role(pool, k8s_node_name, "worker").await
}

async fn insert_node_with_role(
    pool: &PgPool,
    k8s_node_name: &str,
    role: &str,
) -> TestResult<NodeId> {
    let node_id = NodeId::new();
    sqlx::query(
        "INSERT INTO nodes (id, address, role, managed_by, state)
         VALUES ($1, '10.0.0.1'::INET, $2, 'k8s', 'ready')",
    )
    .bind(node_id)
    .bind(role)
    .execute(pool)
    .await?;
    sqlx::query("INSERT INTO node_k8s (node_id, k8s_node_name) VALUES ($1, $2)")
        .bind(node_id)
        .bind(k8s_node_name)
        .execute(pool)
        .await?;
    Ok(node_id)
}

async fn insert_group(pool: &PgPool, name: &str) -> TestResult<NodeGroupId> {
    let group_id = NodeGroupId::new();
    sqlx::query("INSERT INTO node_groups (id, name) VALUES ($1, $2)")
        .bind(group_id)
        .bind(name)
        .execute(pool)
        .await?;
    Ok(group_id)
}

async fn mirrored_group(pool: &PgPool, node_id: NodeId) -> TestResult<Option<NodeGroupId>> {
    Ok(sqlx::query_scalar::<_, Option<NodeGroupId>>(
        "SELECT node_group_id FROM nodes WHERE id = $1",
    )
    .bind(node_id)
    .fetch_one(pool)
    .await?)
}

#[tokio::test(flavor = "current_thread")]
async fn mirror_sets_clears_and_noops() -> TestResult {
    let Some(fixture) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &fixture.pool;
    let group = insert_group(pool, "org-a-dedicated").await?;
    let labeled = insert_node(pool, "ip-10-0-0-1.ec2.internal").await?;
    let unlabeled = insert_node(pool, "ip-10-0-0-2.ec2.internal").await?;

    // First pass: labeled node gains the group, unlabeled stays NULL.
    let names = vec![
        "ip-10-0-0-1.ec2.internal".to_string(),
        "ip-10-0-0-2.ec2.internal".to_string(),
    ];
    let updated = apply_mirror(pool, &names, &[Some(group), None]).await?;
    assert_eq!(updated, 1, "only the labeled node changes");
    assert_eq!(mirrored_group(pool, labeled).await?, Some(group));
    assert_eq!(mirrored_group(pool, unlabeled).await?, None);

    // Steady state: identical input writes nothing.
    let updated = apply_mirror(pool, &names, &[Some(group), None]).await?;
    assert_eq!(updated, 0, "steady-state tick must be a no-op");

    // Label removed: the mirror clears back to NULL (read everywhere as
    // the default generic group).
    let updated = apply_mirror(pool, &names, &[None, None]).await?;
    assert_eq!(updated, 1);
    assert_eq!(mirrored_group(pool, labeled).await?, None);

    // A node with no node_k8s mapping is simply skipped.
    let updated = apply_mirror(
        pool,
        &["ip-10-9-9-9.ec2.internal".to_string()],
        &[Some(group)],
    )
    .await?;
    assert_eq!(updated, 0);
    Ok(())
}

/// Node ids are role-scoped, so one Kubernetes Node may back several
/// `nodes` rows (worker + builder) sharing a `node_k8s.k8s_node_name`.
/// Node groups are worker pools — the mirror must stamp only the worker
/// row, or a co-hosted builder row would inflate `nodes_count` and trip
/// the group residue guards.
#[tokio::test(flavor = "current_thread")]
async fn mirror_only_stamps_worker_rows() -> TestResult {
    let Some(fixture) = try_pg_test_db().await? else {
        return Ok(());
    };
    let pool = &fixture.pool;
    let group = insert_group(pool, "org-a-dedicated").await?;
    let host = "ip-10-0-0-3.ec2.internal";
    let worker = insert_node_with_role(pool, host, "worker").await?;
    let builder = insert_node_with_role(pool, host, "builder").await?;

    let updated = apply_mirror(pool, &[host.to_string()], &[Some(group)]).await?;
    assert_eq!(updated, 1, "only the worker row changes");
    assert_eq!(mirrored_group(pool, worker).await?, Some(group));
    assert_eq!(
        mirrored_group(pool, builder).await?,
        None,
        "the co-hosted builder row must not join the worker group"
    );
    Ok(())
}
