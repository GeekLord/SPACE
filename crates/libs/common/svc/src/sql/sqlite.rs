use super::migration_checksums::AcceptedChecksums;
use pplx_space_common_core::sql;
use std::collections::{BTreeSet, HashMap};
use std::error::Error as StdError;
use std::fmt::Display;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::trace::{TraceEvent, TraceEventCodes};
use rusqlite::{Connection, Transaction, params};
use sqlx::migrate::{Migration, Migrator};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{SqliteConnection, SqlitePool};
use tracing::Instrument as _;

mod cutover;

use pplx_space_sqlite_migrations::{
    ensure_common_jobs_lease_index, ensure_common_jobs_priority_index, job_column_exists,
    job_lease_column_count,
};

pub type SqliteResult<T> = Result<T, SqliteError>;

/// An error while opening, migrating, or maintaining a service-owned SQLite store.
///
/// The concrete database and filesystem errors remain available through the
/// standard error source chain without making this shared helper's public API
/// depend on every backend error type.
#[derive(Debug, thiserror::Error)]
#[error("{context}{source}")]
pub struct SqliteError {
    context: String,
    #[source]
    source: Box<dyn StdError + Send + Sync + 'static>,
}

impl SqliteError {
    fn context(context: impl Into<String>, source: impl StdError + Send + Sync + 'static) -> Self {
        Self {
            context: format!("{}: ", context.into()),
            source: Box::new(source),
        }
    }

    fn message(message: impl Into<String>) -> Self {
        Self {
            context: String::new(),
            source: Box::new(SqliteErrorMessage(message.into())),
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
struct SqliteErrorMessage(String);

trait SqliteContext<T> {
    fn context(self, context: impl Display) -> SqliteResult<T>;
    fn with_context(self, context: impl FnOnce() -> String) -> SqliteResult<T>;
}

impl<T, E> SqliteContext<T> for Result<T, E>
where
    E: StdError + Send + Sync + 'static,
{
    fn context(self, context: impl Display) -> SqliteResult<T> {
        self.map_err(|source| SqliteError::context(context.to_string(), source))
    }

    fn with_context(self, context: impl FnOnce() -> String) -> SqliteResult<T> {
        self.map_err(|source| SqliteError::context(context(), source))
    }
}

impl<T> SqliteContext<T> for Option<T> {
    fn context(self, context: impl Display) -> SqliteResult<T> {
        self.ok_or_else(|| SqliteError::message(context.to_string()))
    }

    fn with_context(self, context: impl FnOnce() -> String) -> SqliteResult<T> {
        self.ok_or_else(|| SqliteError::message(context()))
    }
}

macro_rules! impl_sqlite_error_from {
    ($($error:ty),+ $(,)?) => {
        $(
            impl From<$error> for SqliteError {
                fn from(source: $error) -> Self {
                    Self::context("SQLite operation failed", source)
                }
            }
        )+
    };
}

impl_sqlite_error_from!(
    pplx_space_sqlite_migrations::MigrationCompatibilityError,
    pplx_space_sqlite_migrations::InspectJobColumnsError,
    pplx_space_sqlite_migrations::EnsureCommonJobsLeaseIndexError,
    pplx_space_sqlite_migrations::EnsureCommonJobsPriorityIndexError,
);

#[derive(Debug, Clone)]
pub struct RusqliteOpenOptions {
    pub busy_timeout: Duration,
    pub foreign_keys: bool,
    pub synchronous_normal: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct SqliteU64(pub u64);

impl rusqlite::ToSql for SqliteU64 {
    fn to_sql(&self) -> rusqlite::Result<rusqlite::types::ToSqlOutput<'_>> {
        let value = i64::try_from(self.0)
            .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
        Ok(rusqlite::types::ToSqlOutput::Owned(
            rusqlite::types::Value::Integer(value),
        ))
    }
}

impl rusqlite::types::FromSql for SqliteU64 {
    fn column_result(value: rusqlite::types::ValueRef<'_>) -> rusqlite::types::FromSqlResult<Self> {
        let value = <i64 as rusqlite::types::FromSql>::column_result(value)?;
        let value = u64::try_from(value)
            .map_err(|error| rusqlite::types::FromSqlError::Other(Box::new(error)))?;
        Ok(Self(value))
    }
}

impl Default for RusqliteOpenOptions {
    fn default() -> Self {
        Self {
            busy_timeout: Duration::from_secs(5),
            foreign_keys: false,
            synchronous_normal: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MigrationFailurePolicy {
    /// Return the migration error and leave the database files untouched.
    Fail,
    /// Recreate the database after a failed migration.
    ///
    /// This is only for node-local SQLite stores whose state is rebuildable
    /// from local inventory and/or the cluster Postgres SSOT. Do not use it
    /// for authoritative live state.
    Recreate,
}

/// Embedded migration sets for a service-owned SQLite store and any shared
/// common schema it consumes.
#[derive(Clone, Copy)]
pub struct EmbeddedMigrators {
    pub service: &'static Migrator,
    pub common: Option<&'static Migrator>,
}

pub type MigrationCompatibilityHook =
    fn(
        &Connection,
        &Migrator,
    ) -> Result<(), pplx_space_sqlite_migrations::MigrationCompatibilityError>;

/// Apply a service's embedded migrations and then converge its shared schema.
///
/// This is the in-process counterpart of `space-db-migrator ... up`, intended
/// for daemons that must acquire an ownership mutex before touching SQLite.
pub async fn migrate_embedded(
    db_name: &str,
    db_path: &Path,
    migrators: EmbeddedMigrators,
    baseline_version: Option<i64>,
    failure_policy: MigrationFailurePolicy,
    compatibility_hook: Option<MigrationCompatibilityHook>,
) -> SqliteResult<()> {
    let public_service = super::baselines::is_public(migrators.service);
    if !public_service && migrators.common.is_some_and(super::baselines::is_public) {
        return Err(SqliteError::message(format!(
            "{db_name} requires its service baseline before the shared jobs baseline; see db/SQLITE_BASELINE.md"
        )));
    }
    cutover::prepare(db_name, db_path, migrators.service, migrators.common).await?;
    let baseline_version = if public_service {
        migrators
            .service
            .iter()
            .filter(|migration| migration.migration_type.is_up_migration())
            .map(|migration| migration.version)
            .min()
    } else {
        baseline_version
    };
    let checksums = AcceptedChecksums::embedded().context("invalid migration checksum manifest")?;
    checksums
        .validate(db_name, migrators.service)
        .context("unlisted migration checksum")?;
    if let Some(common) = migrators.common {
        checksums
            .validate("common", common)
            .context("unlisted common migration checksum")?;
    }
    match migrate_embedded_once(
        db_name,
        db_path,
        migrators,
        baseline_version,
        compatibility_hook,
    )
    .await
    {
        Ok(()) => Ok(()),
        Err(first_error) if failure_policy == MigrationFailurePolicy::Fail || public_service => {
            Err(first_error)
        }
        Err(first_error) => {
            tracing::warn!(
                db_name,
                db_path = %db_path.display(),
                error = %first_error,
                "embedded SQLite migration failed; recreating local database"
            );
            pplx_space_metrics::db::sqlite::recreate(db_name);
            remove_database_files(db_path).with_context(|| {
                format!("failed to remove SQLite database {}", db_path.display())
            })?;
            migrate_embedded_once(
                db_name,
                db_path,
                migrators,
                baseline_version,
                compatibility_hook,
            )
            .await
            .with_context(|| {
                format!(
                    "failed to recreate SQLite database {} after embedded migration failure: {first_error}",
                    db_path.display()
                )
            })
        }
    }
}

async fn migrate_embedded_once(
    db_name: &str,
    db_path: &Path,
    migrators: EmbeddedMigrators,
    baseline_version: Option<i64>,
    compatibility_hook: Option<MigrationCompatibilityHook>,
) -> SqliteResult<()> {
    let public_baseline =
        baseline_version.is_some_and(|v| v >= super::baselines::PUBLIC_SQLITE_BASELINE);
    if public_baseline {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).context("failed to create SQLite directory")?;
        }
        let mut conn = Connection::open(db_path).context("failed to open SQLite database")?;
        // Reject both histories before common DDL or legacy compatibility hooks.
        prepare_public_common_schema(db_name, &mut conn, migrators, compatibility_hook)?;
    }
    if let Some(compatibility_hook) = compatibility_hook.filter(|_| !public_baseline) {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("failed to create SQLite directory {}", parent.display())
            })?;
        }
        let conn = Connection::open(db_path)
            .with_context(|| format!("failed to open SQLite at {}", db_path.display()))?;
        compatibility_hook(&conn, migrators.service)?;
    }

    migrate(
        db_name,
        db_path,
        migrators.service,
        baseline_version,
        MigrationFailurePolicy::Fail,
    )
    .await?;

    if let Some(common_migrator) = migrators.common.filter(|_| !public_baseline) {
        let mut conn = Connection::open(db_path)
            .with_context(|| format!("failed to open SQLite at {}", db_path.display()))?;
        migrate_common_schema_up(&mut conn, common_migrator)?;
    }

    Ok(())
}

fn validate_public_history(
    store: &str,
    conn: &Connection,
    migrator: &Migrator,
    common: bool,
) -> SqliteResult<bool> {
    let table = if common {
        "_space_common_schema_migrations"
    } else {
        "_sqlx_migrations"
    };
    let exists: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name = ?1)",
            [table],
            |row| row.get(0),
        )
        .context("failed to inspect public migration history")?;
    if !exists {
        return Ok(false);
    }
    let query = if common {
        "SELECT version, success, checksum FROM _space_common_schema_migrations"
    } else {
        "SELECT version, success, checksum FROM _sqlx_migrations"
    };
    let mut statement = conn
        .prepare(query)
        .context("failed to read public migration history")?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, bool>(1)?,
                row.get::<_, Vec<u8>>(2)?,
            ))
        })
        .context("failed to query public migration history")?;
    let bundled = migrations_by_version(migrator);
    let checksums = AcceptedChecksums::embedded().context("invalid migration checksum manifest")?;
    let mut applied = false;
    for row in rows {
        let (version, success, checksum) = row.context("invalid public migration history")?;
        if !success
            || bundled.get(&version).is_none_or(|migration| {
                !checksums.accepts(store, version, &migration.checksum, &checksum)
            })
        {
            return Err(SqliteError::message(format!(
                "{table} has failed, modified, or unbundled migration {version}; see db/SQLITE_BASELINE.md"
            )));
        }
        applied = true;
    }
    Ok(applied)
}

fn prepare_public_common_schema(
    db_name: &str,
    conn: &mut Connection,
    migrators: EmbeddedMigrators,
    compatibility_hook: Option<MigrationCompatibilityHook>,
) -> SqliteResult<()> {
    let service_applied = validate_public_history(db_name, conn, migrators.service, false)?;
    let common_applied = match migrators.common {
        Some(common) => validate_public_history("common", conn, common, true)?,
        None => false,
    };
    if service_applied && migrators.common.is_some() && !common_applied {
        return Err(SqliteError::message(
            "SQLite service history is present but shared history is missing; explicit repair is required",
        ));
    }
    if !service_applied {
        let expected = if let Some(common) = migrators.common.filter(|_| common_applied) {
            let mut reference =
                Connection::open_in_memory().context("failed to open common schema reference")?;
            migrate_common_schema_up(&mut reference, common)?;
            public_application_schema(&reference)?
        } else {
            Vec::new()
        };
        if public_application_schema(conn)? != expected {
            return Err(SqliteError::message(
                "SQLite has untracked application schema; explicit cutover is required",
            ));
        }
    }
    if let Some(hook) = compatibility_hook {
        hook(conn, migrators.service)?;
    }
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL,
            execution_time BIGINT NOT NULL
        );",
    )
    .context("failed to create service migration history")?;
    if let Some(common) = migrators.common {
        migrate_common_schema_up(conn, common)?;
    }
    Ok(())
}

fn public_application_schema(conn: &Connection) -> SqliteResult<Vec<(String, String)>> {
    conn.prepare(
        "SELECT name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'
         AND name NOT IN ('_sqlx_migrations', '_space_common_schema_migrations', '_space_baseline_archive') ORDER BY name",
    )
    .context("failed to inspect untracked SQLite schema")?
    .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
    .context("failed to query untracked SQLite schema")?
    .collect::<Result<_, _>>()
    .context("failed to read untracked SQLite schema")
}

pub async fn migrate(
    db_name: &str,
    db_path: &Path,
    migrator: &Migrator,
    baseline_version: Option<i64>,
    failure_policy: MigrationFailurePolicy,
) -> SqliteResult<()> {
    cutover::prepare(db_name, db_path, migrator, None).await?;
    let baseline_version = if super::baselines::is_public(migrator) {
        migrator
            .iter()
            .filter(|migration| migration.migration_type.is_up_migration())
            .map(|migration| migration.version)
            .min()
    } else {
        baseline_version
    };
    AcceptedChecksums::embedded()
        .and_then(|checksums| checksums.validate(db_name, migrator))
        .context("invalid migration checksum manifest or unlisted source")?;
    match migrate_once(db_name, db_path, migrator, baseline_version).await {
        Ok(()) => Ok(()),
        Err(first_error)
            if failure_policy == MigrationFailurePolicy::Fail
                || baseline_version
                    .is_some_and(|v| v >= super::baselines::PUBLIC_SQLITE_BASELINE) =>
        {
            Err(first_error).with_context(|| {
                format!(
                    "failed to migrate {db_name} SQLite at {}",
                    db_path.display()
                )
            })
        }
        Err(first_error) => {
            tracing::warn!(
                db_name,
                db_path = %db_path.display(),
                error = %first_error,
                "SQLite migration failed; recreating local database"
            );
            pplx_space_metrics::db::sqlite::recreate(db_name);
            remove_database_files(db_path).with_context(|| {
                format!("failed to remove SQLite database {}", db_path.display())
            })?;
            migrate_once(db_name, db_path, migrator, baseline_version)
                .await
                .with_context(|| {
                    format!(
                        "failed to recreate SQLite database {} after migration failure: {first_error}",
                        db_path.display()
                    )
                })
        }
    }
}

const COMMON_JOBS_LEASES_VERSION: i64 = 2;
const COMMON_JOBS_PRIORITY_VERSION: i64 = 4;
const COMMON_JOBS_CANCELLATION_VERSION: i64 = 6;
fn jobs_table_exists(conn: &Connection) -> SqliteResult<bool> {
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'jobs'",
        [],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .context("failed to inspect jobs table")
}

pub fn migrate_common_schema_up(
    conn: &mut Connection,
    common_migrator: &Migrator,
) -> SqliteResult<()> {
    let checksums = AcceptedChecksums::embedded().context("invalid migration checksum manifest")?;
    migrate_common_schema_with_checksums(conn, common_migrator, &checksums)
}

fn migrate_common_schema_with_checksums(
    conn: &mut Connection,
    common_migrator: &Migrator,
    checksums: &AcceptedChecksums,
) -> SqliteResult<()> {
    checksums
        .validate("common", common_migrator)
        .context("unlisted common migration checksum")?;
    ensure_common_schema_migrations_table(conn)?;
    let applied = applied_common_schema_migrations(conn)?;
    validate_common_schema_history(&applied, common_migrator)?;

    for migration in common_migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
    {
        if let Some(checksum) = applied.get(&migration.version) {
            if !checksums.accepts("common", migration.version, &migration.checksum, checksum) {
                return Err(SqliteError::message(format!(
                    "common schema migration {} checksum mismatch",
                    migration.version
                )));
            }
            continue;
        }

        if should_stamp_common_schema_migration(conn, migration)? {
            stamp_common_schema_migration(conn, migration)?;
            continue;
        }

        apply_common_schema_migration(conn, migration)?;
    }

    Ok(())
}

pub fn ensure_common_schema_migrations_table(conn: &Connection) -> SqliteResult<()> {
    conn.execute_batch(
        r"
        CREATE TABLE IF NOT EXISTS _space_common_schema_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL,
            execution_time BIGINT NOT NULL
        );
        ",
    )
    .context("failed to create common schema migration table")?;

    let dirty_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM _space_common_schema_migrations WHERE success = FALSE",
            [],
            |row| row.get(0),
        )
        .context("failed to inspect common schema migration table")?;
    if dirty_count > 0 {
        return Err(SqliteError::message(
            "common schema has a failed migration row; repair it before continuing",
        ));
    }

    Ok(())
}

pub fn applied_common_schema_migrations(conn: &Connection) -> SqliteResult<HashMap<i64, Vec<u8>>> {
    let mut stmt = conn
        .prepare(
            "SELECT version, checksum FROM _space_common_schema_migrations WHERE success = TRUE",
        )
        .context("failed to prepare common schema migration history query")?;
    stmt.query_map([], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, Vec<u8>>(1)?))
    })
    .context("failed to query common schema migration history")?
    .collect::<Result<HashMap<_, _>, _>>()
    .context("failed to read common schema migration history")
}

pub fn rollback_common_schema_migration(
    conn: &mut Connection,
    common_migrator: &Migrator,
    current_version: i64,
) -> SqliteResult<()> {
    let down_migration = common_migrator
        .iter()
        .find(|migration| {
            migration.version == current_version && migration.migration_type.is_down_migration()
        })
        .with_context(|| {
            format!("common schema migration {current_version} has no bundled down migration")
        })?;

    if common_schema_migration_was_stamped(conn, current_version)? {
        conn.execute(
            "DELETE FROM _space_common_schema_migrations WHERE version = ?1",
            params![current_version],
        )
        .with_context(|| {
            format!("failed to delete common schema migration {current_version} history")
        })?;
        return Ok(());
    }

    let jobs_schema_objects = if current_version == COMMON_JOBS_CANCELLATION_VERSION {
        jobs_schema_objects(conn)?
    } else {
        Vec::new()
    };
    let tx = conn
        .transaction()
        .with_context(|| format!("failed to begin common schema rollback {current_version}"))?;
    tx.execute_batch(down_migration.sql.as_ref())
        .with_context(|| {
            format!("failed to roll back common schema migration {current_version}")
        })?;
    restore_missing_jobs_schema_objects(&tx, &jobs_schema_objects)?;
    tx.execute(
        "DELETE FROM _space_common_schema_migrations WHERE version = ?1",
        params![current_version],
    )
    .with_context(|| {
        format!("failed to delete common schema migration {current_version} history")
    })?;
    tx.commit()
        .with_context(|| format!("failed to commit common schema rollback {current_version}"))?;
    Ok(())
}

fn common_schema_migration_was_stamped(conn: &Connection, version: i64) -> SqliteResult<bool> {
    conn.query_row(
        "SELECT execution_time = -1 FROM _space_common_schema_migrations WHERE version = ?1",
        params![version],
        |row| row.get::<_, bool>(0),
    )
    .with_context(|| format!("failed to inspect common schema migration {version} history"))
}

fn validate_common_schema_history(
    applied: &HashMap<i64, Vec<u8>>,
    common_migrator: &Migrator,
) -> SqliteResult<()> {
    let bundled = migrations_by_version(common_migrator);
    let max_bundled = bundled.keys().copied().max().unwrap_or_default();
    let public = bundled
        .keys()
        .any(|v| *v >= super::baselines::PUBLIC_SQLITE_BASELINE);
    for version in applied
        .keys()
        .filter(|version| public || **version <= max_bundled)
    {
        if !bundled.contains_key(version) {
            return Err(SqliteError::message(format!(
                "common schema has applied migration {version}, but it is not bundled"
            )));
        }
    }
    Ok(())
}

fn should_stamp_common_schema_migration(
    conn: &Connection,
    migration: &Migration,
) -> SqliteResult<bool> {
    if migration.version == 1 {
        return jobs_table_exists(conn);
    }

    if migration.version == COMMON_JOBS_PRIORITY_VERSION {
        return should_stamp_common_jobs_priority_migration(conn);
    }

    if migration.version != COMMON_JOBS_LEASES_VERSION {
        return Ok(false);
    }

    let lease_column_count = job_lease_column_count(conn)?;
    if lease_column_count == 0 {
        return Ok(false);
    }
    if lease_column_count != 3 {
        return Err(SqliteError::message(format!(
            "jobs table has a partial lease-column upgrade ({lease_column_count}/3 columns); repair it before applying common schema migrations"
        )));
    }

    ensure_common_jobs_lease_index(conn)?;
    Ok(true)
}

fn should_stamp_common_jobs_priority_migration(conn: &Connection) -> SqliteResult<bool> {
    if !job_column_exists(conn, "priority")? {
        return Ok(false);
    }

    ensure_common_jobs_priority_index(conn)?;
    Ok(true)
}

fn apply_common_schema_migration(conn: &mut Connection, migration: &Migration) -> SqliteResult<()> {
    let jobs_schema_objects = if migration.version == COMMON_JOBS_CANCELLATION_VERSION {
        jobs_schema_objects(conn)?
    } else {
        Vec::new()
    };
    let start = std::time::Instant::now();
    let tx = conn.transaction().with_context(|| {
        format!(
            "failed to begin common schema migration {}",
            migration.version
        )
    })?;
    if migration.version == COMMON_JOBS_CANCELLATION_VERSION {
        ensure_jobs_traceparent_column(&tx)?;
    }
    tx.execute_batch(migration.sql.as_ref()).with_context(|| {
        format!(
            "failed to apply common schema migration {}",
            migration.version
        )
    })?;
    restore_missing_jobs_schema_objects(&tx, &jobs_schema_objects)?;
    let execution_time = i64::try_from(start.elapsed().as_nanos()).unwrap_or(i64::MAX);
    insert_common_schema_migration_row(&tx, migration, execution_time)?;
    tx.commit().with_context(|| {
        format!(
            "failed to commit common schema migration {}",
            migration.version
        )
    })
}

fn ensure_jobs_traceparent_column(tx: &Transaction<'_>) -> SqliteResult<()> {
    let exists = tx
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('jobs') WHERE name = 'traceparent'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .context("failed to inspect jobs traceparent column")?
        > 0;
    if !exists {
        tx.execute_batch("ALTER TABLE jobs ADD COLUMN traceparent TEXT;")
            .context("failed to add jobs traceparent column")?;
    }
    Ok(())
}

fn jobs_schema_objects(conn: &Connection) -> SqliteResult<Vec<(String, String)>> {
    let mut statement = conn
        .prepare(
            "SELECT name, sql
             FROM sqlite_schema
             WHERE tbl_name = 'jobs'
               AND type IN ('index', 'trigger')
               AND sql IS NOT NULL
             ORDER BY type, name",
        )
        .context("failed to inspect jobs schema objects")?;
    let rows = statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .context("failed to query jobs schema objects")?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .context("failed to read jobs schema objects")
}

fn restore_missing_jobs_schema_objects(
    conn: &Connection,
    objects: &[(String, String)],
) -> SqliteResult<()> {
    for (name, sql) in objects {
        let exists = conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name = ?1)",
                [name],
                |row| row.get::<_, bool>(0),
            )
            .with_context(|| format!("failed to inspect jobs schema object {name}"))?;
        if !exists {
            conn.execute_batch(sql)
                .with_context(|| format!("failed to restore jobs schema object {name}"))?;
        }
    }
    Ok(())
}

fn stamp_common_schema_migration(conn: &Connection, migration: &Migration) -> SqliteResult<()> {
    insert_common_schema_migration_row(conn, migration, -1)
}

fn insert_common_schema_migration_row(
    conn: &Connection,
    migration: &Migration,
    execution_time: i64,
) -> SqliteResult<()> {
    conn.execute(
        r"
        INSERT INTO _space_common_schema_migrations
            (version, description, success, checksum, execution_time)
        VALUES (?1, ?2, TRUE, ?3, ?4)
        ON CONFLICT(version) DO UPDATE SET
            description = excluded.description,
            success = TRUE,
            checksum = excluded.checksum,
            execution_time = excluded.execution_time
        ",
        params![
            migration.version,
            migration.description.as_ref(),
            migration.checksum.as_ref(),
            execution_time,
        ],
    )
    .with_context(|| {
        format!(
            "failed to stamp common schema migration {}",
            migration.version
        )
    })?;
    Ok(())
}

pub fn open_rusqlite(db_path: &Path, options: RusqliteOpenOptions) -> SqliteResult<Connection> {
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create SQLite directory {}", parent.display()))?;
    }

    let conn = Connection::open(db_path)
        .with_context(|| format!("failed to open SQLite database {}", db_path.display()))?;
    conn.busy_timeout(options.busy_timeout)
        .with_context(|| format!("failed to set busy timeout for {}", db_path.display()))?;

    let mut pragmas = String::from("PRAGMA journal_mode=WAL;");
    if options.synchronous_normal {
        pragmas.push_str("PRAGMA synchronous=NORMAL;");
    }
    if options.foreign_keys {
        pragmas.push_str("PRAGMA foreign_keys=ON;");
    }
    conn.execute_batch(&pragmas)
        .with_context(|| format!("failed to configure SQLite database {}", db_path.display()))?;
    conn.trace_v2(
        TraceEventCodes::SQLITE_TRACE_PROFILE,
        Some(profile_rusqlite_trace_event),
    );
    restrict_database_permissions(db_path)?;
    Ok(conn)
}

pub fn remove_database_files(db_path: &Path) -> SqliteResult<()> {
    for path in database_files(db_path) {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("failed to remove SQLite database file {}", path.display())
                });
            }
        }
    }
    Ok(())
}

pub fn restrict_database_permissions(db_path: &Path) -> SqliteResult<()> {
    for path in database_files(db_path) {
        restrict_file_permissions(&path)?;
    }
    Ok(())
}

async fn migrate_once(
    db_name: &str,
    db_path: &Path,
    migrator: &Migrator,
    baseline_version: Option<i64>,
) -> SqliteResult<()> {
    let span = tracing::info_span!(
        "sqlite.migrate",
        db.system = "sqlite",
        db.name = db_name,
        db.path = %db_path.display(),
    );
    async {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("failed to create SQLite directory {}", parent.display())
            })?;
        }

        let connect_options = SqliteConnectOptions::new()
            .filename(db_path)
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(connect_options)
            .await
            .with_context(|| {
                format!(
                    "failed to connect to {db_name} SQLite at {}",
                    db_path.display()
                )
            })?;

        let result = async {
            prepare_baseline(db_name, &pool, migrator, baseline_version).await?;
            let mut rollback_compatible_migrator = rollback_compatible_migrator(migrator);
            if baseline_version.is_some_and(|v| v >= super::baselines::PUBLIC_SQLITE_BASELINE) {
                rollback_compatible_migrator.ignore_missing = false;
            }
            let mut conn = pool
                .acquire()
                .await
                .context("failed to acquire SQLite migration connection")?;
            AcceptedChecksums::embedded()
                .context("invalid migration checksum manifest")?
                .run(db_name, &rollback_compatible_migrator, &mut *conn)
                .await
                .with_context(|| format!("failed to apply {db_name} SQLite migrations"))?;
            Ok(())
        }
        .await;

        pool.close().await;
        if result.is_ok() {
            restrict_database_permissions(db_path)?;
        }
        result
    }
    .instrument(span)
    .await
}

fn rollback_compatible_migrator(migrator: &Migrator) -> Migrator {
    Migrator {
        migrations: migrator.migrations.clone(),
        ignore_missing: true,
        locking: migrator.locking,
        no_tx: migrator.no_tx,
        table_name: migrator.table_name.clone(),
        create_schemas: migrator.create_schemas.clone(),
    }
}

fn profile_rusqlite_query(sql: &str, elapsed: Duration) {
    tracing::info!(
        target: "rusqlite::query",
        summary = sqlite_query_summary(sql),
        db.system = "sqlite",
        db.statement = sql,
        rows_affected = 0_i64,
        rows_returned = 0_i64,
        elapsed_secs = elapsed.as_secs_f64(),
    );
}

fn profile_rusqlite_trace_event(event: TraceEvent<'_>) {
    if let TraceEvent::Profile(statement, elapsed) = event {
        let sql = statement.sql();
        profile_rusqlite_query(sql.as_ref(), elapsed);
    }
}

fn sqlite_query_summary(sql: &str) -> &'static str {
    // Skip a leading `/*module_path:line*/` locator comment (the `sql!`
    // macro) so classification still sees the statement verb.
    let sql = match sql.trim_start().strip_prefix("/*") {
        Some(rest) => rest.split_once("*/").map(|(_, sql)| sql).unwrap_or(sql),
        None => sql,
    };
    match sql
        .split_whitespace()
        .next()
        .map(str::trim)
        .map(|word| word.trim_end_matches(';'))
        .unwrap_or_default()
        .to_ascii_uppercase()
        .as_str()
    {
        "SELECT" => "sqlite SELECT",
        "INSERT" => "sqlite INSERT",
        "UPDATE" => "sqlite UPDATE",
        "DELETE" => "sqlite DELETE",
        "CREATE" => "sqlite CREATE",
        "DROP" => "sqlite DROP",
        "ALTER" => "sqlite ALTER",
        "BEGIN" => "sqlite BEGIN",
        "COMMIT" => "sqlite COMMIT",
        "ROLLBACK" => "sqlite ROLLBACK",
        "PRAGMA" => "sqlite PRAGMA",
        _ => "sqlite query",
    }
}

async fn ensure_sqlx_migrations_table_conn(conn: &mut SqliteConnection) -> SqliteResult<()> {
    sqlx::query(sql!(
        r#"
        CREATE TABLE IF NOT EXISTS _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL,
            execution_time BIGINT NOT NULL
        )
        "#
    ))
    .execute(conn)
    .await
    .context("failed to create SQLite _sqlx_migrations table")?;
    Ok(())
}

async fn prepare_baseline(
    db_name: &str,
    pool: &SqlitePool,
    migrator: &Migrator,
    baseline_version: Option<i64>,
) -> SqliteResult<()> {
    let mut conn = pool
        .acquire()
        .await
        .context("failed to acquire SQLite connection")?;
    sqlx::query(sql!("BEGIN IMMEDIATE"))
        .execute(&mut *conn)
        .await
        .with_context(|| format!("failed to begin {db_name} SQLite baseline transaction"))?;

    let result = prepare_baseline_locked(db_name, &mut conn, migrator, baseline_version).await;
    match result {
        Ok(()) => {
            sqlx::query(sql!("COMMIT"))
                .execute(&mut *conn)
                .await
                .with_context(|| {
                    format!("failed to commit {db_name} SQLite baseline transaction")
                })?;
            Ok(())
        }
        Err(error) => {
            let rollback_result = sqlx::query(sql!("ROLLBACK")).execute(&mut *conn).await;
            if let Err(rollback_error) = rollback_result {
                tracing::warn!(
                    db_name,
                    error = %rollback_error,
                    "failed to roll back SQLite baseline transaction"
                );
            }
            Err(error)
        }
    }
}

async fn prepare_baseline_locked(
    db_name: &str,
    conn: &mut SqliteConnection,
    migrator: &Migrator,
    baseline_version: Option<i64>,
) -> SqliteResult<()> {
    if baseline_version.is_some_and(|v| v >= super::baselines::PUBLIC_SQLITE_BASELINE) {
        if !table_exists_conn(&mut *conn, "_sqlx_migrations").await?
            && application_object_count(&mut *conn).await? > 0
        {
            return Err(SqliteError::message(format!(
                "{db_name} SQLite requires an explicit public-baseline cutover; see db/SQLITE_BASELINE.md"
            )));
        }
        // SQLx validates the complete history, including the baseline checksum.
        return Ok(());
    }

    let applied_versions = applied_versions(&mut *conn).await?;
    if applied_versions.is_empty() {
        let object_count = application_object_count(&mut *conn).await?;
        if object_count > 0 {
            return Err(SqliteError::message(format!(
                "{db_name} SQLite has application tables but no SQLx migration history; recreating is required"
            )));
        }
        return Ok(());
    }

    let migrations_by_version = migrations_by_version(migrator);
    let max_known = migrations_by_version
        .keys()
        .copied()
        .max()
        .unwrap_or_default();
    for version in applied_versions.iter().copied().filter(|version| {
        baseline_version.is_none_or(|baseline_version| *version >= baseline_version)
            && *version <= max_known
    }) {
        if !migrations_by_version.contains_key(&version) {
            return Err(SqliteError::message(format!(
                "{db_name} SQLite has applied migration {version}, but it is not bundled"
            )));
        }
    }

    let Some(baseline_version) = baseline_version else {
        return Ok(());
    };

    let max_applied = applied_versions.iter().copied().max().unwrap_or_default();
    if max_applied < baseline_version {
        return Err(SqliteError::message(format!(
            "{db_name} SQLite is at migration {max_applied}, below supported baseline {baseline_version}"
        )));
    }

    let baseline = migrations_by_version
        .get(&baseline_version)
        .copied()
        .with_context(|| {
            format!("{db_name} baseline migration {baseline_version} is not bundled")
        })?;

    ensure_sqlx_migrations_table_conn(&mut *conn).await?;

    sqlx::query(sql!("DELETE FROM _sqlx_migrations WHERE version < ?1"))
        .bind(baseline_version)
        .execute(&mut *conn)
        .await
        .with_context(|| {
            format!("failed to prune {db_name} SQLite migration history below baseline")
        })?;

    sqlx::query(sql!(
        r#"
        INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time)
        VALUES (?1, ?2, TRUE, ?3, 0)
        ON CONFLICT(version) DO UPDATE SET
            description = excluded.description,
            success = TRUE,
            checksum = excluded.checksum,
            execution_time = 0
        "#
    ))
    .bind(baseline.version)
    .bind(baseline.description.as_ref())
    .bind(baseline.checksum.as_ref())
    .execute(&mut *conn)
    .await
    .with_context(|| format!("failed to restamp {db_name} SQLite baseline migration"))?;

    for version in applied_versions
        .iter()
        .copied()
        .filter(|version| *version > baseline_version)
        .filter(|version| *version <= max_known)
    {
        let migration = migrations_by_version
            .get(&version)
            .copied()
            .with_context(|| {
                format!("{db_name} SQLite has applied migration {version}, but it is not bundled")
            })?;
        sqlx::query(sql!(
            r#"
            INSERT OR IGNORE INTO _sqlx_migrations
                (version, description, success, checksum, execution_time)
            VALUES (?1, ?2, TRUE, ?3, 0)
            "#
        ))
        .bind(migration.version)
        .bind(migration.description.as_ref())
        .bind(migration.checksum.as_ref())
        .execute(&mut *conn)
        .await
        .with_context(|| {
            format!("failed to import {db_name} SQLite migration {version} history")
        })?;
    }

    Ok(())
}

async fn applied_versions(conn: &mut SqliteConnection) -> SqliteResult<Vec<i64>> {
    let mut versions = BTreeSet::new();

    if table_exists_conn(&mut *conn, "_sqlx_migrations").await? {
        let rows: Vec<i64> = sqlx::query_scalar(sql!(
            "SELECT version FROM _sqlx_migrations WHERE success = TRUE"
        ))
        .fetch_all(&mut *conn)
        .await
        .context("failed to load SQLite SQLx migration history")?;
        versions.extend(rows);
    }

    if table_exists_conn(&mut *conn, "goose_db_version").await? {
        let rows: Vec<i64> = sqlx::query_scalar(sql!(
            r#"
            SELECT g.version_id
            FROM goose_db_version g
            JOIN (
                SELECT version_id, MAX(id) AS id
                FROM goose_db_version
                WHERE version_id > 0
                GROUP BY version_id
            ) latest ON latest.version_id = g.version_id AND latest.id = g.id
            WHERE g.is_applied = 1
            "#
        ))
        .fetch_all(&mut *conn)
        .await
        .context("failed to load SQLite goose migration history")?;
        versions.extend(rows);
    }

    if table_exists_conn(&mut *conn, "schema_migrations").await? {
        let rows: Vec<i64> = sqlx::query_scalar(sql!("SELECT version FROM schema_migrations"))
            .fetch_all(&mut *conn)
            .await
            .context("failed to load SQLite schema_migrations history")?;
        versions.extend(rows);
    }

    Ok(versions.into_iter().collect())
}

async fn application_object_count(conn: &mut SqliteConnection) -> SqliteResult<i64> {
    sqlx::query_scalar(sql!(
        r#"
        SELECT COUNT(*)
        FROM sqlite_master
        WHERE type IN ('table', 'index', 'trigger', 'view')
          AND name NOT LIKE 'sqlite_%'
          AND name NOT IN ('_sqlx_migrations', 'goose_db_version', 'schema_migrations')
        "#
    ))
    .fetch_one(conn)
    .await
    .context("failed to inspect SQLite schema objects")
}

#[cfg(test)]
async fn table_exists(pool: &SqlitePool, table_name: &str) -> SqliteResult<bool> {
    let exists: Option<i64> = sqlx::query_scalar(sql!(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1"
    ))
    .bind(table_name)
    .fetch_optional(pool)
    .await
    .with_context(|| format!("failed to check for SQLite table {table_name}"))?;
    Ok(exists.is_some())
}

async fn table_exists_conn(conn: &mut SqliteConnection, table_name: &str) -> SqliteResult<bool> {
    let exists: Option<i64> = sqlx::query_scalar(sql!(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1"
    ))
    .bind(table_name)
    .fetch_optional(conn)
    .await
    .with_context(|| format!("failed to check for SQLite table {table_name}"))?;
    Ok(exists.is_some())
}

fn migrations_by_version(migrator: &Migrator) -> HashMap<i64, &Migration> {
    migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| (migration.version, migration))
        .collect()
}

fn database_files(db_path: &Path) -> [PathBuf; 3] {
    [
        db_path.to_path_buf(),
        PathBuf::from(format!("{}-wal", db_path.display())),
        PathBuf::from(format!("{}-shm", db_path.display())),
    ]
}

#[cfg(unix)]
fn restrict_file_permissions(path: &Path) -> SqliteResult<()> {
    use std::os::unix::fs::PermissionsExt as _;

    match std::fs::metadata(path) {
        Ok(_) => std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to chmod 0600 {}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => {
            Err(error).with_context(|| format!("failed to stat SQLite file {}", path.display()))
        }
    }
}

#[cfg(not(unix))]
fn restrict_file_permissions(_path: &Path) -> SqliteResult<()> {
    Ok(())
}

#[cfg(test)]
mod tests;
