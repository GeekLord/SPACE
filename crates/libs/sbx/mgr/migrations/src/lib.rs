//! Sandbox-manager schema admission and migrations shared by the daemon and CLI.
use pplx_space_sqlite_migrations::{
    ensure_common_jobs_lease_index, ensure_common_jobs_priority_index, job_column_exists,
    job_lease_columns_complete, stamp_missing_sqlite_migration,
};
use rusqlite::Connection;
use sqlx::migrate::Migrator;

pub static SANDBOX_MANAGER_MIGRATOR: Migrator = sqlx::migrate!("../../../../../db/sandbox-manager");
pub static COMMON_SCHEMA_MIGRATOR: Migrator = sqlx::migrate!("../../../../../db/common");

const JOBS_LEASES_VERSION: i64 = 27;
const JOBS_PRIORITY_VERSION: i64 = 37;

// The final schema contraction raises SQLite's application-owned user_version.
// Admission happens before migration history repair or any service work so a
// binary from the preparation release cannot operate on the contracted store.
const SUPPORTED_SCHEMA_FLOOR: i64 = 3;

#[derive(Debug, thiserror::Error)]
enum PrepareMigrationsError {
    #[error("failed to read sandbox-manager schema floor: {0}")]
    ReadSchemaFloor(#[source] rusqlite::Error),
    #[error(
        "sandbox-manager schema floor {required} is not admitted for this operation (allowed 0..={supported}); use a forward upgrade or repair"
    )]
    UnsupportedSchemaFloor { required: i64, supported: i64 },
    #[error("failed to inspect active snapshot uploads: {0}")]
    InspectUploads(#[source] rusqlite::Error),
    #[error(
        "active snapshot upload {0} lacks staged metadata; finish or repair it with the preparation release before cutover"
    )]
    LegacyUpload(String),
    #[error(transparent)]
    InspectColumns(#[from] pplx_space_sqlite_migrations::InspectJobColumnsError),
    #[error(transparent)]
    EnsureLeaseIndex(#[from] pplx_space_sqlite_migrations::EnsureCommonJobsLeaseIndexError),
    #[error(transparent)]
    EnsurePriorityIndex(#[from] pplx_space_sqlite_migrations::EnsureCommonJobsPriorityIndexError),
    #[error(transparent)]
    Stamp(#[from] pplx_space_sqlite_migrations::StampSqliteMigrationError),
}

/// Reject an incompatible store before writing, then stamp service migrations
/// whose columns were already installed by the common migrator. Both entry
/// points run this before applying service migrations.
pub fn prepare_migrations(
    conn: &Connection,
    service_migrator: &Migrator,
) -> Result<(), pplx_space_sqlite_migrations::MigrationCompatibilityError> {
    prepare_migrations_inner(conn, service_migrator)
        .map_err(pplx_space_sqlite_migrations::MigrationCompatibilityError::new)
}

/// No part of the contracted database, including its common job schema, may
/// be downgraded. Check before the CLI creates or edits migration history.
pub fn ensure_downgrade_allowed(
    conn: &Connection,
) -> Result<(), pplx_space_sqlite_migrations::MigrationCompatibilityError> {
    check_schema_floor(conn, 1)
        .map_err(pplx_space_sqlite_migrations::MigrationCompatibilityError::new)
}

fn prepare_migrations_inner(
    conn: &Connection,
    service_migrator: &Migrator,
) -> Result<(), PrepareMigrationsError> {
    check_schema_floor(conn, SUPPORTED_SCHEMA_FLOOR)?;
    check_active_upload_format(conn)?;
    if service_migrator
        .iter()
        .any(|migration| migration.version == JOBS_LEASES_VERSION)
        && job_lease_columns_complete(conn)?
    {
        ensure_common_jobs_lease_index(conn)?;
        stamp_missing_sqlite_migration(conn, service_migrator, JOBS_LEASES_VERSION)?;
    }
    if service_migrator
        .iter()
        .any(|migration| migration.version == JOBS_PRIORITY_VERSION)
        && job_column_exists(conn, "priority")?
    {
        ensure_common_jobs_priority_index(conn)?;
        stamp_missing_sqlite_migration(conn, service_migrator, JOBS_PRIORITY_VERSION)?;
    }
    Ok(())
}

fn check_schema_floor(conn: &Connection, supported: i64) -> Result<(), PrepareMigrationsError> {
    let required = conn
        .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
        .map_err(PrepareMigrationsError::ReadSchemaFloor)?;
    if required < 0 || required > supported {
        return Err(PrepareMigrationsError::UnsupportedSchemaFloor {
            required,
            supported,
        });
    }
    Ok(())
}

fn check_active_upload_format(conn: &Connection) -> Result<(), PrepareMigrationsError> {
    use rusqlite::OptionalExtension;
    let has_jobs: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'jobs')",
            [],
            |row| row.get(0),
        )
        .map_err(PrepareMigrationsError::InspectUploads)?;
    if !has_jobs {
        return Ok(());
    }
    let incompatible: Option<String> = conn
        .query_row(
            "SELECT job_id FROM jobs WHERE kind = 'snapshot_upload'
         AND status IN ('pending', 'running')
         AND CASE WHEN json_valid(payload)
             THEN json_type(payload, '$.includes_metadata_job') IS NOT 'true'
             ELSE 1 END
         ORDER BY job_id LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(PrepareMigrationsError::InspectUploads)?;
    match incompatible {
        Some(job_id) => Err(PrepareMigrationsError::LegacyUpload(job_id)),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests;
