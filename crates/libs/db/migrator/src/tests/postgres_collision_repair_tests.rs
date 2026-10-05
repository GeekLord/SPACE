use pplx_space_db_test_fixtures::try_raw_pg_test_db;

use super::super::*;
use crate::pg_test_support::TestResult;

async fn install_migrations_table(pool: &PgPool) -> TestResult {
    sqlx::query(sql!(
        r#"
        CREATE TABLE _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMPTZ NOT NULL DEFAULT now(),
            success BOOLEAN NOT NULL,
            checksum BYTEA NOT NULL,
            execution_time BIGINT NOT NULL
        )
        "#
    ))
    .execute(pool)
    .await?;
    Ok(())
}

async fn insert_migration_row(pool: &PgPool, version: i64, description: &str) -> TestResult {
    sqlx::query(sql!(
        r#"
        INSERT INTO _sqlx_migrations
            (version, description, success, checksum, execution_time)
        VALUES ($1, $2, TRUE, $3, 0)
        "#
    ))
    .bind(version)
    .bind(description)
    .bind(vec![0xDE_u8, 0xAD, 0xBE, 0xEF])
    .execute(pool)
    .await?;
    Ok(())
}

async fn insert_v68_row(pool: &PgPool, description: &str) -> TestResult {
    insert_migration_row(pool, 68, description).await
}

async fn insert_v82_row(pool: &PgPool, description: &str) -> TestResult {
    insert_migration_row(pool, 82, description).await
}

async fn migration_row_count(pool: &PgPool, version: i64) -> TestResult<i64> {
    Ok(sqlx::query_scalar(sql!(
        "SELECT COUNT(*) FROM _sqlx_migrations WHERE version = $1"
    ))
    .bind(version)
    .fetch_one(pool)
    .await?)
}

async fn v68_row_count(pool: &PgPool) -> TestResult<i64> {
    migration_row_count(pool, 68).await
}

async fn migration_description(pool: &PgPool, version: i64) -> TestResult<Option<String>> {
    Ok(sqlx::query_scalar(sql!(
        "SELECT description FROM _sqlx_migrations WHERE version = $1"
    ))
    .bind(version)
    .fetch_optional(pool)
    .await?)
}

#[tokio::test]
async fn deletes_stale_orphan_on_delete_row_at_v68() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };
    install_migrations_table(&fixture.pool).await?;
    insert_v68_row(&fixture.pool, COLLIDED_V68_ORPHAN_DESCRIPTION).await?;

    repair_v68_collision_postgres(&fixture.pool).await?;

    assert_eq!(v68_row_count(&fixture.pool).await?, 0);
    Ok(())
}

#[tokio::test]
async fn preserves_unrelated_v68_row() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };
    install_migrations_table(&fixture.pool).await?;
    insert_v68_row(&fixture.pool, "snapshots state check and latest index").await?;

    repair_v68_collision_postgres(&fixture.pool).await?;

    assert_eq!(v68_row_count(&fixture.pool).await?, 1);
    Ok(())
}

#[tokio::test]
async fn noop_on_fresh_database_without_migrations_table() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };
    repair_v68_collision_postgres(&fixture.pool).await?;
    Ok(())
}

#[tokio::test]
async fn rekeys_stale_warm_pool_row_from_v82_to_v84() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };
    install_migrations_table(&fixture.pool).await?;
    insert_v82_row(&fixture.pool, COLLIDED_V82_WARM_POOL_DESCRIPTION).await?;

    repair_v82_collision_postgres(&fixture.pool).await?;

    assert_eq!(migration_row_count(&fixture.pool, 82).await?, 0);
    assert_eq!(migration_row_count(&fixture.pool, 83).await?, 0);
    assert_eq!(migration_row_count(&fixture.pool, 84).await?, 1);
    assert_eq!(
        migration_description(&fixture.pool, 84).await?,
        Some(COLLIDED_V82_WARM_POOL_DESCRIPTION.to_string())
    );
    Ok(())
}

#[tokio::test]
async fn noop_when_v84_row_already_exists() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };
    install_migrations_table(&fixture.pool).await?;
    insert_v82_row(&fixture.pool, COLLIDED_V82_WARM_POOL_DESCRIPTION).await?;
    insert_migration_row(&fixture.pool, 84, COLLIDED_V82_WARM_POOL_DESCRIPTION).await?;

    repair_v82_collision_postgres(&fixture.pool).await?;

    assert_eq!(migration_row_count(&fixture.pool, 82).await?, 1);
    assert_eq!(migration_row_count(&fixture.pool, 84).await?, 1);
    assert_eq!(
        migration_description(&fixture.pool, 82).await?,
        Some(COLLIDED_V82_WARM_POOL_DESCRIPTION.to_string())
    );
    assert_eq!(
        migration_description(&fixture.pool, 84).await?,
        Some(COLLIDED_V82_WARM_POOL_DESCRIPTION.to_string())
    );
    Ok(())
}

#[tokio::test]
async fn preserves_unrelated_v82_row() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };
    install_migrations_table(&fixture.pool).await?;
    insert_v82_row(&fixture.pool, "snapshots ready latest covering index").await?;

    repair_v82_collision_postgres(&fixture.pool).await?;

    assert_eq!(migration_row_count(&fixture.pool, 82).await?, 1);
    assert_eq!(migration_row_count(&fixture.pool, 84).await?, 0);
    assert_eq!(
        migration_description(&fixture.pool, 82).await?,
        Some("snapshots ready latest covering index".to_string())
    );
    Ok(())
}

#[tokio::test]
async fn noop_on_fresh_database_without_migrations_table_for_v82() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };
    repair_v82_collision_postgres(&fixture.pool).await?;
    Ok(())
}
