use pplx_space_db_test_fixtures::try_raw_pg_test_db;
use sqlx::SqlSafeStr as _;

use super::super::*;
use crate::pg_test_support::TestResult;

#[tokio::test]
async fn all_postgres_migrations_apply_to_fresh_database() -> TestResult {
    let Some(fixture) = try_raw_pg_test_db().await? else {
        return Ok(());
    };

    POSTGRES_MIGRATOR.run(&fixture.pool).await?;
    POSTGRES_MIGRATOR.run(&fixture.pool).await?;

    let latest: i64 = sqlx::query_scalar(sql!(
        "SELECT MAX(version) FROM _sqlx_migrations WHERE success = TRUE"
    ))
    .fetch_one(&fixture.pool)
    .await?;
    let expected_latest = POSTGRES_MIGRATOR
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| migration.version)
        .max()
        .expect("Postgres migrator must bundle at least one migration");
    assert_eq!(latest, expected_latest);

    let mut migrations: Vec<_> = POSTGRES_MIGRATOR.iter().cloned().collect();
    migrations.push(sqlx::migrate::Migration::new(
        expected_latest + 1,
        Cow::Borrowed("next migration"),
        MigrationType::Simple,
        "ALTER TABLE organizations ADD COLUMN upgrade_probe boolean NOT NULL DEFAULT true;"
            .into_sql_str(),
        false,
    ));
    Migrator::with_migrations(migrations)
        .run(&fixture.pool)
        .await?;

    let upgraded: bool = sqlx::query_scalar(sql!(
        "SELECT upgrade_probe FROM organizations WHERE slug = 'local'"
    ))
    .fetch_one(&fixture.pool)
    .await?;
    assert!(upgraded);
    Ok(())
}
