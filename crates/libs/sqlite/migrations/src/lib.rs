use std::collections::HashMap;

use rusqlite::{Connection, params};
use sqlx::migrate::{Migration, Migrator};

#[derive(Debug, thiserror::Error)]
#[error("SQLite migration compatibility check failed: {0}")]
pub struct MigrationCompatibilityError(
    #[source] Box<dyn std::error::Error + Send + Sync + 'static>,
);

impl MigrationCompatibilityError {
    pub fn new(source: impl std::error::Error + Send + Sync + 'static) -> Self {
        Self(Box::new(source))
    }
}

#[derive(Debug, thiserror::Error)]
#[error("failed to inspect jobs columns: {0}")]
pub struct InspectJobColumnsError(#[source] pub rusqlite::Error);

#[derive(Debug, thiserror::Error)]
#[error("failed to create common jobs lease index: {0}")]
pub struct EnsureCommonJobsLeaseIndexError(#[source] pub rusqlite::Error);

#[derive(Debug, thiserror::Error)]
#[error("failed to create common jobs priority index: {0}")]
pub struct EnsureCommonJobsPriorityIndexError(#[source] pub rusqlite::Error);

#[derive(Debug, thiserror::Error)]
pub enum StampSqliteMigrationError {
    #[error("migration {version} is not bundled")]
    NotBundled { version: i64 },
    #[error("failed to create SQLite migration table: {0}")]
    CreateTable(#[source] rusqlite::Error),
    #[error("failed to stamp SQLite migration {version}: {source}")]
    Stamp {
        version: i64,
        #[source]
        source: rusqlite::Error,
    },
}

pub fn job_lease_columns_complete(conn: &Connection) -> Result<bool, InspectJobColumnsError> {
    Ok(job_lease_column_count(conn)? == 3)
}

pub fn job_lease_column_count(conn: &Connection) -> Result<usize, InspectJobColumnsError> {
    ["lease_owner", "lease_expires_at", "heartbeat_at"]
        .into_iter()
        .map(|column| job_column_exists(conn, column))
        .try_fold(0_usize, |count, exists| {
            exists.map(|exists| if exists { count + 1 } else { count })
        })
}

pub fn job_column_exists(conn: &Connection, column: &str) -> Result<bool, InspectJobColumnsError> {
    conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('jobs') WHERE name = ?1",
        params![column],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(InspectJobColumnsError)
}

pub fn ensure_common_jobs_lease_index(
    conn: &Connection,
) -> Result<(), EnsureCommonJobsLeaseIndexError> {
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_jobs_lease_expiry
             ON jobs(lease_expires_at)
             WHERE status = 'running' AND lease_expires_at IS NOT NULL;",
    )
    .map_err(EnsureCommonJobsLeaseIndexError)
}

pub fn ensure_common_jobs_priority_index(
    conn: &Connection,
) -> Result<(), EnsureCommonJobsPriorityIndexError> {
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_jobs_pending_priority
             ON jobs(kind, priority DESC, created_at ASC, job_id ASC)
             WHERE status = 'pending';",
    )
    .map_err(EnsureCommonJobsPriorityIndexError)
}

pub fn stamp_sqlite_migration(
    conn: &Connection,
    migrator: &Migrator,
    version: i64,
) -> Result<(), StampSqliteMigrationError> {
    stamp_sqlite_migration_with_conflict_clause(
        conn,
        migrator,
        version,
        r"
        ON CONFLICT(version) DO UPDATE SET
            description = excluded.description,
            success = TRUE,
            checksum = excluded.checksum,
            execution_time = 0
        ",
    )
}

pub fn stamp_missing_sqlite_migration(
    conn: &Connection,
    migrator: &Migrator,
    version: i64,
) -> Result<(), StampSqliteMigrationError> {
    stamp_sqlite_migration_with_conflict_clause(
        conn,
        migrator,
        version,
        "ON CONFLICT(version) DO NOTHING",
    )
}

fn stamp_sqlite_migration_with_conflict_clause(
    conn: &Connection,
    migrator: &Migrator,
    version: i64,
    conflict_clause: &str,
) -> Result<(), StampSqliteMigrationError> {
    let migration = migrations_by_version(migrator)
        .get(&version)
        .copied()
        .ok_or(StampSqliteMigrationError::NotBundled { version })?;
    conn.execute_batch(
        r"
        CREATE TABLE IF NOT EXISTS _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL,
            execution_time BIGINT NOT NULL
        );
        ",
    )
    .map_err(StampSqliteMigrationError::CreateTable)?;
    conn.execute(
        &format!(
            r"
            INSERT INTO _sqlx_migrations
                (version, description, success, checksum, execution_time)
            VALUES (?1, ?2, TRUE, ?3, 0)
            {conflict_clause}
            "
        ),
        params![
            migration.version,
            migration.description.as_ref(),
            migration.checksum.as_ref(),
        ],
    )
    .map_err(|source| StampSqliteMigrationError::Stamp { version, source })?;
    Ok(())
}

fn migrations_by_version(migrator: &Migrator) -> HashMap<i64, &Migration> {
    migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| (migration.version, migration))
        .collect()
}
