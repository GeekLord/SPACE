pub use pplx_space_sqlite_migrations::stamp_sqlite_migration;
use pplx_space_sqlite_migrations::{
    ensure_common_jobs_lease_index, job_column_exists, job_lease_column_count,
    stamp_missing_sqlite_migration,
};
use rusqlite::Connection;
use sqlx::migrate::Migrator;

const JOBS_TRACEPARENT_MIGRATION_VERSION: i64 = 2;
const JOBS_LEASES_MIGRATION_VERSION: i64 = 3;

#[derive(Debug, thiserror::Error)]
pub enum PrepareCommonJobsMigrationsError {
    #[error(transparent)]
    InspectColumns(#[from] pplx_space_sqlite_migrations::InspectJobColumnsError),
    #[error("failed to stamp volume-manager jobs migration: {0}")]
    Stamp(#[source] pplx_space_sqlite_migrations::StampSqliteMigrationError),
    #[error("failed to ensure volume-manager jobs lease index: {0}")]
    EnsureLeaseIndex(#[source] pplx_space_sqlite_migrations::EnsureCommonJobsLeaseIndexError),
    #[error(
        "volume-manager jobs table has a partial lease-column upgrade ({column_count}/3 columns)"
    )]
    PartialLeaseUpgrade { column_count: usize },
}

/// Align legacy volume-manager service history before common jobs convergence.
pub fn prepare_common_jobs_migrations(
    conn: &Connection,
    service_migrator: &Migrator,
) -> Result<(), pplx_space_sqlite_migrations::MigrationCompatibilityError> {
    prepare_common_jobs_migrations_inner(conn, service_migrator)
        .map_err(pplx_space_sqlite_migrations::MigrationCompatibilityError::new)
}

fn prepare_common_jobs_migrations_inner(
    conn: &Connection,
    service_migrator: &Migrator,
) -> Result<(), PrepareCommonJobsMigrationsError> {
    if !service_migrator
        .iter()
        .any(|migration| migration.version == JOBS_TRACEPARENT_MIGRATION_VERSION)
    {
        return Ok(());
    }
    if job_column_exists(conn, "traceparent")? {
        stamp_missing_sqlite_migration(conn, service_migrator, JOBS_TRACEPARENT_MIGRATION_VERSION)
            .map_err(PrepareCommonJobsMigrationsError::Stamp)?;
    }

    let lease_column_count = job_lease_column_count(conn)?;
    if lease_column_count == 0 {
        return Ok(());
    }
    if lease_column_count != 3 {
        return Err(PrepareCommonJobsMigrationsError::PartialLeaseUpgrade {
            column_count: lease_column_count,
        });
    }

    ensure_common_jobs_lease_index(conn)
        .map_err(PrepareCommonJobsMigrationsError::EnsureLeaseIndex)?;
    stamp_missing_sqlite_migration(conn, service_migrator, JOBS_LEASES_MIGRATION_VERSION)
        .map_err(PrepareCommonJobsMigrationsError::Stamp)
}
