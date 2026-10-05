use pplx_space_common_core::types::SandboxId;

use super::*;
use pplx_space_db_test_fixtures::pg_test_db;

use pplx_space_test_env::TestResult;

async fn insert_sandbox(pool: &PgPool, sandbox_id: SandboxId, lifecycle: &str) -> TestResult {
    sqlx::query(sql!(
        "INSERT INTO sandboxes (
             id, user_id, org_id, lifecycle, placement, managed_by,
             network_policy_override_json, network_policy_generation
         )
         VALUES (
             $1,
             '00000000-0000-0000-0000-000000000010',
             '00000000-0000-0000-0000-000000000001',
             $2, 'on_node', 'k8s', $3, 1
         )"
    ))
    .bind(sandbox_id)
    .bind(lifecycle)
    .bind(sqlx::types::Json(
        &pplx_space_net_common::NetworkPolicyV1::default(),
    ))
    .execute(pool)
    .await?;
    Ok(())
}

#[tokio::test(flavor = "current_thread")]
async fn wake_completion_advances_the_restore_it_owns() -> TestResult {
    let db = pg_test_db().await?;
    let sandbox_id = SandboxId::new();
    insert_sandbox(&db.pool, sandbox_id, "restoring").await?;

    assert_eq!(
        complete_wake_lifecycle(&db.pool, sandbox_id, PublishedSuspendFence::Enforced).await?,
        WakeLifecycleCompletion::Completed
    );
    let lifecycle =
        sqlx::query_scalar::<_, String>(sql!("SELECT lifecycle FROM sandboxes WHERE id = $1"))
            .bind(sandbox_id)
            .fetch_one(&db.pool)
            .await?;
    assert_eq!(lifecycle, "started");
    Ok(())
}

#[tokio::test(flavor = "current_thread")]
async fn wake_completion_cannot_overwrite_a_newer_suspend_claim() -> TestResult {
    let db = pg_test_db().await?;
    for suspend_lifecycle in ["suspending", "suspended"] {
        let sandbox_id = SandboxId::new();
        insert_sandbox(&db.pool, sandbox_id, "restoring").await?;
        sqlx::query(sql!("UPDATE sandboxes SET lifecycle = $2 WHERE id = $1"))
            .bind(sandbox_id)
            .bind(suspend_lifecycle)
            .execute(&db.pool)
            .await?;

        assert_eq!(
            complete_wake_lifecycle(&db.pool, sandbox_id, PublishedSuspendFence::Enforced).await?,
            WakeLifecycleCompletion::SupersededBySuspend,
            "the stale wake completion must defer after suspend owns the lifecycle"
        );
        let lifecycle =
            sqlx::query_scalar::<_, String>(sql!("SELECT lifecycle FROM sandboxes WHERE id = $1"))
                .bind(sandbox_id)
                .fetch_one(&db.pool)
                .await?;
        assert_eq!(lifecycle, suspend_lifecycle);
    }
    Ok(())
}

#[tokio::test(flavor = "current_thread")]
async fn direct_restore_completion_advances_its_suspended_baseline() -> TestResult {
    let db = pg_test_db().await?;
    let sandbox_id = SandboxId::new();
    insert_sandbox(&db.pool, sandbox_id, "suspended").await?;

    assert_eq!(
        complete_wake_lifecycle(
            &db.pool,
            sandbox_id,
            PublishedSuspendFence::DirectRestoreBaseline,
        )
        .await?,
        WakeLifecycleCompletion::Completed
    );
    assert_eq!(
        sqlx::query_scalar::<_, String>(sql!("SELECT lifecycle FROM sandboxes WHERE id = $1"))
            .bind(sandbox_id)
            .fetch_one(&db.pool)
            .await?,
        "started"
    );
    Ok(())
}
