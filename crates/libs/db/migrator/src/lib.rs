//! The SPACE schema migrator: the one-shot job that applies every bundled
//! migration set — the control-plane Postgres schema and each node-local
//! `SQLite` store — and converges the control-plane Postgres roles.
//!
//! This crate is the whole job. The `space-db-migrator` binary is a thin
//! `main` that parses flags, initializes logging, and calls [`run`], so a
//! deployment that needs private wiring can supply its own `main` against
//! this library without copying any of the job.
//!
//! It is its own crate rather than a module of a service library because
//! `sqlx::migrate!` embeds every bundled `db/*` directory as static data in
//! whatever crate holds the macro: only the job that applies them should
//! carry that weight, and no long-running service links this.

use pplx_space_common_svc::sql;
use std::borrow::Cow;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::{Parser, Subcommand, ValueEnum};
use rusqlite::Connection;
use sqlx::migrate::{MigrateError, Migration, MigrationType, Migrator};
use sqlx::postgres::PgPoolOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{PgConnection, PgPool, SqlitePool};

use pplx_space_common_svc::sql::baselines::{self, SqliteStoreConfig};
use pplx_space_common_svc::sql::sqlite::{self, MigrationFailurePolicy, SqliteError};
use pplx_space_sqlite_migrations::{job_lease_columns_complete, stamp_sqlite_migration};

mod baseline_cutover;
pub mod bootstrap_roles;
pub mod migration_retry;
#[cfg(test)]
mod pg_test_support;
pub mod user_password;

static POSTGRES_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/postgres");
use pplx_space_sbxmgr_migrations::SANDBOX_MANAGER_MIGRATOR;
static TEMPLATE_MANAGER_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/template-manager");
static NODE_MANAGER_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/node-manager");
static NODE_CTL_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/node-ctl");
static RUNTIME_MANAGER_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/runtime-manager");
static VOLUME_MANAGER_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/volume-manager");
static BUILD_MANAGER_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/build-manager");
static COMMON_SCHEMA_MIGRATOR: Migrator = sqlx::migrate!("../../../../db/common");

const POSTGRES_BASELINE_ADVISORY_LOCK: i64 = 0x5350_4143_455f_424c;

/// The name the migrator logs its startup banner under, and the name of the
/// binary that hosts it.
pub const SERVICE_NAME: &str = "space-db-migrator";

/// Which database the job acts on and what it does to it: the binary's
/// subcommand tree, so a private `main` reuses the whole command surface
/// rather than restating it.
#[derive(Subcommand)]
pub enum Database {
    /// Run control-plane Postgres migrations.
    #[command(alias = "postgres")]
    ControlPlane(ControlPlaneArgs),
    /// Converge control-plane Postgres roles, grants, and object ownership.
    #[command(name = "bootstrap-roles")]
    BootstrapRoles(bootstrap_roles::BootstrapRolesArgs),
    /// Set an existing console user's password and revoke their sessions.
    SetUserPassword(user_password::SetUserPasswordArgs),
    /// Run sandbox-manager `SQLite` migrations.
    #[command(name = "sandbox-manager", alias = "node-local", alias = "sqlite")]
    SandboxManager(SqliteArgs),
    /// Run template-manager `SQLite` migrations.
    #[command(name = "template-manager")]
    TemplateManager(SqliteArgs),
    /// Run node-manager `SQLite` migrations.
    #[command(name = "node-manager")]
    NodeManager(SqliteArgs),
    /// Run node-ctl `SQLite` migrations.
    #[command(name = "node-ctl")]
    NodeCtl(SqliteArgs),
    /// Run runtime-manager `SQLite` migrations.
    #[command(name = "runtime-manager")]
    RuntimeManager(SqliteArgs),
    /// Run volume-manager `SQLite` migrations.
    #[command(name = "volume-manager")]
    VolumeManager(SqliteArgs),
    /// Run build-manager `SQLite` migrations.
    #[command(name = "build-manager")]
    BuildManager(SqliteArgs),
}

#[derive(Parser)]
pub struct ControlPlaneArgs {
    /// Control-plane Postgres connection URI.
    #[arg(long)]
    pub database_url: String,

    /// Confirm destructive reset when command is `reset`.
    #[arg(long)]
    pub confirm_data_loss: bool,

    /// `activeDeadlineSeconds` of the Job running this command, which the
    /// lock-retry window is sized against. The Job's chart passes its own
    /// value in; Kubernetes does not expose the deadline to the container.
    #[arg(
        long,
        env = "SPACE_DB_MIGRATE_JOB_DEADLINE_SECONDS",
        default_value_t = migration_retry::MIGRATION_JOB_ACTIVE_DEADLINE.as_secs()
    )]
    pub job_deadline_seconds: u64,

    /// Migration command to run.
    #[arg(value_enum, default_value_t = Command::Up)]
    pub command: Command,
}

#[derive(Parser)]
pub struct SqliteArgs {
    /// Node-local `SQLite` database path.
    #[arg(long)]
    pub database_path: Option<PathBuf>,

    /// Confirm destructive reset when command is `reset`.
    #[arg(long)]
    pub confirm_data_loss: bool,

    /// Migration command to run.
    #[arg(value_enum, default_value_t = Command::Up)]
    pub command: Command,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum Command {
    Up,
    Down,
    Status,
    Reset,
}

type SqliteDowngradeAdmission =
    fn(&Connection) -> Result<(), pplx_space_sqlite_migrations::MigrationCompatibilityError>;

#[derive(Clone, Copy)]
struct SqliteDatabase {
    name: &'static str,
    default_path: &'static str,
    migrator: &'static Migrator,
    store: SqliteStoreConfig,
    common_schema: bool,
    compatibility_hook: Option<sqlite::MigrationCompatibilityHook>,
    downgrade_admission: Option<SqliteDowngradeAdmission>,
}

/// Everything [`run`] needs from the process that hosts it: the binary's
/// subcommand, already parsed.
///
/// Deliberately not `Debug`: the control-plane subcommands carry a Postgres
/// URI with a password in it.
pub struct DbMigrateRunConfig {
    /// Which database to act on, and what to do to it.
    pub database: Database,
}

impl From<Database> for DbMigrateRunConfig {
    fn from(database: Database) -> Self {
        Self { database }
    }
}

/// Why [`run`] returned without finishing the requested command.
///
/// Variants name the step that failed rather than the kind of failure: a
/// migration job that fails is read by whoever is unblocking a deploy, and
/// which step died is the whole diagnosis. Every SQL variant keeps the
/// driver error as its source.
#[derive(Debug, thiserror::Error)]
pub enum RunDbMigrateError {
    #[error(transparent)]
    BaselineCutover(#[from] baseline_cutover::Error),
    #[error("reset requires --confirm-data-loss")]
    ResetNotConfirmed,
    #[error("migration {version} has no matching .down.sql file")]
    MissingDownMigration { version: i64 },
    #[error(transparent)]
    BootstrapRoles(#[from] bootstrap_roles::BootstrapRolesError),
    #[error(transparent)]
    UserPassword(#[from] user_password::SetUserPasswordError),
    #[error(transparent)]
    Sqlite(#[from] SqliteError),
    #[error(transparent)]
    DowngradeAdmission(#[from] pplx_space_sqlite_migrations::MigrationCompatibilityError),
    #[error("failed to connect to control-plane Postgres: {0}")]
    ConnectPostgres(#[source] sqlx::Error),
    #[error("failed to reconnect to control-plane Postgres after reset: {0}")]
    ReconnectPostgres(#[source] sqlx::Error),
    #[error("failed to apply control-plane Postgres migrations: {0}")]
    ApplyMigrations(#[source] migration_retry::MigrationRunFailed),
    #[error("failed to apply control-plane Postgres migrations after reset: {0}")]
    ApplyMigrationsAfterReset(#[source] migration_retry::MigrationRunFailed),
    #[error("failed to connect to SQLite at {path}: {source}")]
    ConnectSqlite {
        path: PathBuf,
        #[source]
        source: sqlx::Error,
    },
    #[error("failed to open SQLite at {path}: {source}")]
    OpenSqlite {
        path: PathBuf,
        #[source]
        source: rusqlite::Error,
    },
    #[error("failed to acquire Postgres connection: {0}")]
    AcquirePostgresConnection(#[source] sqlx::Error),
    #[error("failed to drop Postgres public schema: {0}")]
    DropPublicSchema(#[source] sqlx::Error),
    #[error("failed to recreate Postgres public schema: {0}")]
    CreatePublicSchema(#[source] sqlx::Error),
    #[error("failed to restore Postgres public schema grants: {0}")]
    GrantPublicSchema(#[source] sqlx::Error),
    #[error("failed to create control-plane Postgres _sqlx_migrations table: {0}")]
    CreatePostgresMigrationsTable(#[source] sqlx::Error),
    #[error("failed to create SQLite _sqlx_migrations table: {0}")]
    CreateSqliteMigrationsTable(#[source] sqlx::Error),
    #[error("failed to acquire Postgres connection for v{version} collision repair: {source}")]
    AcquireCollisionRepairConnection {
        version: i64,
        #[source]
        source: sqlx::Error,
    },
    #[error("failed to check for _sqlx_migrations table: {0}")]
    CheckMigrationsTable(#[source] sqlx::Error),
    #[error("failed to read v{version} description from _sqlx_migrations: {source}")]
    ReadCollidedDescription {
        version: i64,
        #[source]
        source: sqlx::Error,
    },
    #[error("failed to delete stale v68 row from _sqlx_migrations: {0}")]
    DeleteCollidedV68Row(#[source] sqlx::Error),
    #[error("failed to check for v84 row in _sqlx_migrations: {0}")]
    CheckV84Row(#[source] sqlx::Error),
    #[error("failed to re-key stale v82 row to v84 in _sqlx_migrations: {0}")]
    RekeyCollidedV82Row(#[source] sqlx::Error),
    #[error("failed to begin Postgres baseline transaction: {0}")]
    BeginBaselineTransaction(#[source] sqlx::Error),
    #[error("failed to acquire Postgres baseline advisory lock: {0}")]
    BaselineAdvisoryLock(#[source] sqlx::Error),
    #[error(
        "control-plane Postgres has application schema but no migration history; run explicit reset or restore from backup"
    )]
    SchemaWithoutHistory,
    #[error("failed to commit empty Postgres baseline transaction: {0}")]
    CommitEmptyBaselineTransaction(#[source] sqlx::Error),
    #[error("failed to prune Postgres migration history below baseline: {0}")]
    PruneBaselineHistory(#[source] sqlx::Error),
    #[error("failed to restamp Postgres baseline migration: {0}")]
    RestampBaseline(#[source] sqlx::Error),
    #[error("failed to import Postgres migration {version} history: {source}")]
    ImportBaselineHistory {
        version: i64,
        #[source]
        source: sqlx::Error,
    },
    #[error("failed to commit Postgres baseline transaction: {0}")]
    CommitBaselineTransaction(#[source] sqlx::Error),
    #[error(
        "{db_name} is at migration {max_applied}, below supported baseline {baseline_version}; run explicit reset or restore from a newer backup"
    )]
    BelowBaseline {
        db_name: &'static str,
        max_applied: i64,
        baseline_version: i64,
    },
    #[error(
        "{db_name} has applied migration {max_applied}, newer than bundled migration {max_known}"
    )]
    AheadOfBundledMigrations {
        db_name: &'static str,
        max_applied: i64,
        max_known: i64,
    },
    #[error("{db_name} baseline migration {baseline_version} is not bundled")]
    BaselineNotBundled {
        db_name: &'static str,
        baseline_version: i64,
    },
    #[error("{db_name} has applied migration {version}, but it is not bundled")]
    AppliedMigrationNotBundled { db_name: &'static str, version: i64 },
    #[error("failed to inspect Postgres application schema: {0}")]
    InspectPostgresSchema(#[source] sqlx::Error),
    #[error("failed to check for legacy migration table: {0}")]
    CheckLegacyMigrationTable(#[source] sqlx::Error),
    #[error("failed to load control-plane Postgres legacy migration history: {0}")]
    LoadLegacyHistory(#[source] sqlx::Error),
    #[error("failed to load control-plane Postgres SQLx migration history: {0}")]
    LoadPostgresHistory(#[source] sqlx::Error),
    #[error("failed to load SQLite SQLx migration history: {0}")]
    LoadSqliteHistory(#[source] sqlx::Error),
    #[error("failed to roll back control-plane Postgres migration: {0}")]
    RollbackPostgres(#[source] MigrateError),
    #[error("failed to roll back SQLite migration: {0}")]
    RollbackSqlite(#[source] MigrateError),
}

/// Run the requested migration command to completion.
///
/// One-shot: there is no shutdown token, because the job either finishes the
/// command or fails. Kubernetes bounds it with `activeDeadlineSeconds`, which
/// the control-plane subcommand is told about so its lock-retry window can be
/// sized against it (see
/// [`migration_retry::MIGRATION_JOB_ACTIVE_DEADLINE`]).
pub async fn run(config: DbMigrateRunConfig) -> Result<(), RunDbMigrateError> {
    match config.database {
        Database::ControlPlane(args) => run_control_plane(args).await,
        Database::BootstrapRoles(args) => Ok(bootstrap_roles::run(args).await?),
        Database::SetUserPassword(args) => Ok(user_password::run(args).await?),
        Database::SandboxManager(args) => run_sqlite(sqlite_sandbox_manager(), args).await,
        Database::TemplateManager(args) => run_sqlite(sqlite_template_manager(), args).await,
        Database::NodeManager(args) => run_sqlite(sqlite_node_manager(), args).await,
        Database::NodeCtl(args) => run_sqlite(sqlite_node_ctl(), args).await,
        Database::RuntimeManager(args) => run_sqlite(sqlite_runtime_manager(), args).await,
        Database::VolumeManager(args) => run_sqlite(sqlite_volume_manager(), args).await,
        Database::BuildManager(args) => run_sqlite(sqlite_build_manager(), args).await,
    }
}

fn sqlite_sandbox_manager() -> SqliteDatabase {
    SqliteDatabase {
        name: "sandbox-manager",
        default_path: pplx_space_common_svc::core::host::linux::paths::SANDBOX_MANAGER_DB,
        migrator: &SANDBOX_MANAGER_MIGRATOR,
        store: baselines::SANDBOX_MANAGER,
        common_schema: true,
        compatibility_hook: Some(pplx_space_sbxmgr_migrations::prepare_migrations),
        downgrade_admission: Some(pplx_space_sbxmgr_migrations::ensure_downgrade_allowed),
    }
}

fn sqlite_template_manager() -> SqliteDatabase {
    SqliteDatabase {
        name: "template-manager",
        default_path: pplx_space_common_svc::core::host::linux::paths::TEMPLATE_MANAGER_DB,
        migrator: &TEMPLATE_MANAGER_MIGRATOR,
        store: baselines::TEMPLATE_MANAGER,
        common_schema: true,
        compatibility_hook: None,
        downgrade_admission: None,
    }
}

fn sqlite_node_manager() -> SqliteDatabase {
    SqliteDatabase {
        name: "node-manager",
        default_path: pplx_space_common_svc::core::host::linux::paths::NODE_MANAGER_DB,
        migrator: &NODE_MANAGER_MIGRATOR,
        store: baselines::NODE_MANAGER,
        common_schema: false,
        compatibility_hook: None,
        downgrade_admission: None,
    }
}

fn sqlite_node_ctl() -> SqliteDatabase {
    SqliteDatabase {
        name: "node-ctl",
        default_path: pplx_space_common_svc::core::host::linux::paths::NODE_CTL_DB,
        migrator: &NODE_CTL_MIGRATOR,
        store: baselines::NODE_CTL,
        common_schema: false,
        compatibility_hook: None,
        downgrade_admission: None,
    }
}

fn sqlite_runtime_manager() -> SqliteDatabase {
    SqliteDatabase {
        name: "runtime-manager",
        default_path: pplx_space_common_svc::core::host::linux::paths::RUNTIME_MANAGER_DB,
        migrator: &RUNTIME_MANAGER_MIGRATOR,
        store: baselines::RUNTIME_MANAGER,
        common_schema: true,
        compatibility_hook: None,
        downgrade_admission: None,
    }
}

fn sqlite_volume_manager() -> SqliteDatabase {
    SqliteDatabase {
        name: "volume-manager",
        default_path: pplx_space_common_svc::core::host::linux::paths::VOLUME_MANAGER_DB,
        migrator: &VOLUME_MANAGER_MIGRATOR,
        store: baselines::VOLUME_MANAGER,
        common_schema: true,
        compatibility_hook: Some(pplx_space_volmgr_migrations::prepare_common_jobs_migrations),
        downgrade_admission: None,
    }
}

fn sqlite_build_manager() -> SqliteDatabase {
    SqliteDatabase {
        name: "build-manager",
        default_path: pplx_space_common_svc::core::host::linux::paths::BUILD_MANAGER_DB,
        migrator: &BUILD_MANAGER_MIGRATOR,
        store: baselines::BUILD_MANAGER,
        common_schema: true,
        compatibility_hook: Some(prepare_build_manager_jobs_migrations),
        downgrade_admission: None,
    }
}

async fn run_control_plane(args: ControlPlaneArgs) -> Result<(), RunDbMigrateError> {
    ensure_down_migration_pairs(&POSTGRES_MIGRATOR)?;
    let mut pool_options = PgPoolOptions::new().max_connections(1);
    // Up/Down run as space_migrator (assumed via SET ROLE when the
    // connection authenticates as an admin) so migration-created objects get
    // migrator ownership and its default privileges. Reset keeps the
    // connecting identity: it drops the public schema, which the migrator
    // does not own.
    if matches!(args.command, Command::Up | Command::Down) {
        pool_options = pool_options
            .after_connect(|conn, _metadata| Box::pin(bootstrap_roles::assume_migrator_role(conn)));
    }
    let pool = pool_options
        .connect(&args.database_url)
        .await
        .map_err(RunDbMigrateError::ConnectPostgres)?;

    let retry_policy = migration_retry::LockRetryPolicy::for_job_deadline(Duration::from_secs(
        args.job_deadline_seconds,
    ));
    match args.command {
        Command::Up => {
            if baselines::is_public(&POSTGRES_MIGRATOR) {
                baseline_cutover::prepare(&pool, &POSTGRES_MIGRATOR).await?;
            } else {
                repair_v68_collision_postgres(&pool).await?;
                repair_v82_collision_postgres(&pool).await?;
                prepare_postgres_baseline(&pool, &POSTGRES_MIGRATOR, baselines::POSTGRES).await?;
            }
            apply_control_plane_migrations(&pool, retry_policy, RunDbMigrateError::ApplyMigrations)
                .await?;
        }
        // Deliberately unretried, unlike Up: `undo` takes the same table
        // locks, and down migrations bound them the same way, but a rollback
        // is a supervised operator action with a human present to re-run it.
        Command::Down => rollback_last_postgres(&pool, &POSTGRES_MIGRATOR).await?,
        Command::Status => print_status_postgres(&pool, &POSTGRES_MIGRATOR).await?,
        Command::Reset => {
            if !args.confirm_data_loss {
                return Err(RunDbMigrateError::ResetNotConfirmed);
            }
            reset_postgres_schema(&pool).await?;
            // Re-apply migrations under the same identity rules as Up: the
            // schema drop/create above needs the connecting admin (the
            // migrator does not own the public schema), but the rebuilt
            // objects must be migrator-owned or the reset database lands
            // outside the role model until an extra bootstrap pass. The
            // reset grant of ALL on the schema to PUBLIC lets the migrator
            // create before bootstrap-roles reconverges the tighter grants.
            let migrate_pool = PgPoolOptions::new()
                .max_connections(1)
                .after_connect(|conn, _metadata| {
                    Box::pin(bootstrap_roles::assume_migrator_role(conn))
                })
                .connect(&args.database_url)
                .await
                .map_err(RunDbMigrateError::ReconnectPostgres)?;
            apply_control_plane_migrations(
                &migrate_pool,
                retry_policy,
                RunDbMigrateError::ApplyMigrationsAfterReset,
            )
            .await?;
        }
    }

    Ok(())
}

/// Apply every pending control-plane migration, retrying a lock timeout.
///
/// `failed` names the pass in the reported error, because the reset path runs
/// this twice and "which of the two" is the first thing an operator asks.
async fn apply_control_plane_migrations(
    pool: &PgPool,
    retry_policy: migration_retry::LockRetryPolicy,
    failed: fn(migration_retry::MigrationRunFailed) -> RunDbMigrateError,
) -> Result<(), RunDbMigrateError> {
    migration_retry::run_up(pool, &POSTGRES_MIGRATOR, retry_policy)
        .await
        .map_err(failed)?;
    Ok(())
}

async fn run_sqlite(database: SqliteDatabase, args: SqliteArgs) -> Result<(), RunDbMigrateError> {
    ensure_down_migration_pairs(database.migrator)?;
    if database.common_schema {
        ensure_down_migration_pairs(&COMMON_SCHEMA_MIGRATOR)?;
    }
    let database_path = args
        .database_path
        .unwrap_or_else(|| PathBuf::from(database.default_path));

    match args.command {
        Command::Up => {
            migrate_sqlite_up(
                database,
                &database_path,
                database.store.migration_failure_policy,
            )
            .await?;
        }
        Command::Reset => {
            if !args.confirm_data_loss {
                return Err(RunDbMigrateError::ResetNotConfirmed);
            }
            sqlite::remove_database_files(&database_path)?;
            migrate_sqlite_up(database, &database_path, MigrationFailurePolicy::Fail).await?;
        }
        Command::Down => {
            rollback_last_sqlite_database(database, &database_path).await?;
        }
        Command::Status => {
            print_status_sqlite_database(database, &database_path).await?;
        }
    }

    Ok(())
}

async fn migrate_sqlite_up(
    database: SqliteDatabase,
    database_path: &Path,
    failure_policy: MigrationFailurePolicy,
) -> Result<(), RunDbMigrateError> {
    Ok(sqlite::migrate_embedded(
        database.name,
        database_path,
        sqlite::EmbeddedMigrators {
            service: database.migrator,
            common: database.common_schema.then_some(&COMMON_SCHEMA_MIGRATOR),
        },
        Some(database.store.baseline_version),
        failure_policy,
        database.compatibility_hook,
    )
    .await?)
}

#[derive(Debug, thiserror::Error)]
enum PrepareJobsMigrationsError {
    #[error(transparent)]
    InspectColumns(#[from] pplx_space_sqlite_migrations::InspectJobColumnsError),
    #[error(transparent)]
    Stamp(#[from] pplx_space_sqlite_migrations::StampSqliteMigrationError),
}

fn prepare_build_manager_jobs_migrations(
    conn: &Connection,
    service_migrator: &Migrator,
) -> Result<(), pplx_space_sqlite_migrations::MigrationCompatibilityError> {
    prepare_build_manager_jobs_migrations_inner(conn, service_migrator)
        .map_err(pplx_space_sqlite_migrations::MigrationCompatibilityError::new)
}

fn prepare_build_manager_jobs_migrations_inner(
    conn: &Connection,
    service_migrator: &Migrator,
) -> Result<(), PrepareJobsMigrationsError> {
    if baselines::is_public(service_migrator) || !job_lease_columns_complete(conn)? {
        return Ok(());
    }

    // Migration 4 creates the index; recreating it here would undo migration 5.
    Ok(stamp_sqlite_migration(conn, service_migrator, 3)?)
}

async fn sqlite_pool(database_path: &Path) -> Result<SqlitePool, RunDbMigrateError> {
    let connect_options = SqliteConnectOptions::new()
        .filename(database_path)
        .create_if_missing(true);
    SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(connect_options)
        .await
        .map_err(|source| RunDbMigrateError::ConnectSqlite {
            path: database_path.to_path_buf(),
            source,
        })
}

async fn reset_postgres_schema(pool: &PgPool) -> Result<(), RunDbMigrateError> {
    sqlx::query(sql!("DROP SCHEMA IF EXISTS public CASCADE"))
        .execute(pool)
        .await
        .map_err(RunDbMigrateError::DropPublicSchema)?;
    sqlx::query(sql!("CREATE SCHEMA public"))
        .execute(pool)
        .await
        .map_err(RunDbMigrateError::CreatePublicSchema)?;
    sqlx::query(sql!("GRANT ALL ON SCHEMA public TO public"))
        .execute(pool)
        .await
        .map_err(RunDbMigrateError::GrantPublicSchema)?;
    Ok(())
}

async fn ensure_sqlx_migrations_table_postgres(pool: &PgPool) -> Result<(), RunDbMigrateError> {
    let mut conn = pool
        .acquire()
        .await
        .map_err(RunDbMigrateError::AcquirePostgresConnection)?;
    ensure_sqlx_migrations_table_postgres_conn(&mut conn).await
}

async fn ensure_sqlx_migrations_table_postgres_conn(
    conn: &mut PgConnection,
) -> Result<(), RunDbMigrateError> {
    sqlx::query(sql!(
        r"
        CREATE TABLE IF NOT EXISTS _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMPTZ NOT NULL DEFAULT now(),
            success BOOLEAN NOT NULL,
            checksum BYTEA NOT NULL,
            execution_time BIGINT NOT NULL
        )
        "
    ))
    .execute(conn)
    .await
    .map_err(RunDbMigrateError::CreatePostgresMigrationsTable)?;
    Ok(())
}

async fn ensure_sqlx_migrations_table_sqlite(pool: &SqlitePool) -> Result<(), RunDbMigrateError> {
    sqlx::query(sql!(
        r"
        CREATE TABLE IF NOT EXISTS _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL,
            execution_time BIGINT NOT NULL
        )
        "
    ))
    .execute(pool)
    .await
    .map_err(RunDbMigrateError::CreateSqliteMigrationsTable)?;
    Ok(())
}

/// Description sqlx assigns to the orphan-on-delete migration. It briefly
/// shared version 68 with another migration on `main`; the rename to v69
/// leaves any database that recorded it under v68 with a stale row whose
/// checksum no longer matches the file sqlx finds at v68. The repair below
/// keys off this description string.
const COLLIDED_V68_ORPHAN_DESCRIPTION: &str = "snapshot storage locations orphan on delete";

/// Delete the stale `_sqlx_migrations` row left when the orphan-on-delete
/// migration briefly shared version 68 with another migration, so the
/// current v68 (`snapshots state check and latest index`) can pass sqlx's
/// checksum validation and the renamed v69 can re-apply idempotently.
///
/// Safe to call on every Up: on a fresh database the table check
/// short-circuits, on an already-clean database the v68 description compare
/// short-circuits, and the targeted DELETE is a no-op outside the
/// collision case.
async fn repair_v68_collision_postgres(pool: &PgPool) -> Result<(), RunDbMigrateError> {
    let mut conn = pool.acquire().await.map_err(|source| {
        RunDbMigrateError::AcquireCollisionRepairConnection {
            version: 68,
            source,
        }
    })?;

    let table_exists: bool =
        sqlx::query_scalar(sql!("SELECT to_regclass('_sqlx_migrations') IS NOT NULL"))
            .fetch_one(&mut *conn)
            .await
            .map_err(RunDbMigrateError::CheckMigrationsTable)?;
    if !table_exists {
        return Ok(());
    }

    let description: Option<String> = sqlx::query_scalar(sql!(
        "SELECT description FROM _sqlx_migrations WHERE version = 68"
    ))
    .fetch_optional(&mut *conn)
    .await
    .map_err(|source| RunDbMigrateError::ReadCollidedDescription {
        version: 68,
        source,
    })?;

    let Some(description) = description else {
        return Ok(());
    };
    if description != COLLIDED_V68_ORPHAN_DESCRIPTION {
        return Ok(());
    }

    tracing::warn!(
        version = 68,
        description = %description,
        "found stale v68 migration row from a prior version collision; deleting it so the current v68 and v69 migrations can apply"
    );
    sqlx::query(sql!(
        "DELETE FROM _sqlx_migrations WHERE version = 68 AND description = $1"
    ))
    .bind(COLLIDED_V68_ORPHAN_DESCRIPTION)
    .execute(&mut *conn)
    .await
    .map_err(RunDbMigrateError::DeleteCollidedV68Row)?;
    Ok(())
}

/// Description sqlx assigns to the warm-pool pacing migration that was
/// renumbered from v82 to v84 after some databases had already recorded it at
/// v82. The repair below keys off this description string.
const COLLIDED_V82_WARM_POOL_DESCRIPTION: &str = "warm pool policy pacing";

/// Re-key the already-applied warm-pool pacing migration from v82 to v84 when
/// a database recorded it before the snapshots index migrations took v82/v83.
/// This leaves v82/v83 absent so sqlx can physically apply the covering-index
/// create/drop pair, while preserving the warm-pool row so v84 is not re-run.
///
/// Safe to call on every Up: on a fresh database the table check
/// short-circuits, on an already-clean database the v82 description compare
/// short-circuits, and the targeted UPDATE is guarded by the source
/// description and absence of a v84 row.
async fn repair_v82_collision_postgres(pool: &PgPool) -> Result<(), RunDbMigrateError> {
    let mut conn = pool.acquire().await.map_err(|source| {
        RunDbMigrateError::AcquireCollisionRepairConnection {
            version: 82,
            source,
        }
    })?;

    let table_exists: bool =
        sqlx::query_scalar(sql!("SELECT to_regclass('_sqlx_migrations') IS NOT NULL"))
            .fetch_one(&mut *conn)
            .await
            .map_err(RunDbMigrateError::CheckMigrationsTable)?;
    if !table_exists {
        return Ok(());
    }

    let description: Option<String> = sqlx::query_scalar(sql!(
        "SELECT description FROM _sqlx_migrations WHERE version = 82"
    ))
    .fetch_optional(&mut *conn)
    .await
    .map_err(|source| RunDbMigrateError::ReadCollidedDescription {
        version: 82,
        source,
    })?;

    let Some(description) = description else {
        return Ok(());
    };
    if description != COLLIDED_V82_WARM_POOL_DESCRIPTION {
        return Ok(());
    }

    let v84_exists: bool = sqlx::query_scalar(sql!(
        "SELECT EXISTS (SELECT 1 FROM _sqlx_migrations WHERE version = 84)"
    ))
    .fetch_one(&mut *conn)
    .await
    .map_err(RunDbMigrateError::CheckV84Row)?;
    if v84_exists {
        tracing::warn!(
            version = 82,
            target_version = 84,
            description = %description,
            "found stale v82 migration row from a prior version collision but v84 already exists; leaving migration history unchanged for manual inspection"
        );
        return Ok(());
    }

    tracing::warn!(
        version = 82,
        target_version = 84,
        description = %description,
        "found stale v82 migration row from a prior version collision; re-keying it to v84 so the current v82 and v83 migrations can apply"
    );
    sqlx::query(sql!(
        r"
        UPDATE _sqlx_migrations
        SET version = 84
        WHERE version = 82
          AND description = $1
          AND NOT EXISTS (SELECT 1 FROM _sqlx_migrations WHERE version = 84)
        "
    ))
    .bind(COLLIDED_V82_WARM_POOL_DESCRIPTION)
    .execute(&mut *conn)
    .await
    .map_err(RunDbMigrateError::RekeyCollidedV82Row)?;
    Ok(())
}

async fn prepare_postgres_baseline(
    pool: &PgPool,
    migrator: &Migrator,
    baseline_version: i64,
) -> Result<(), RunDbMigrateError> {
    let mut tx = pool
        .begin()
        .await
        .map_err(RunDbMigrateError::BeginBaselineTransaction)?;
    let conn = &mut *tx;

    sqlx::query(sql!("SELECT pg_advisory_xact_lock($1)"))
        .bind(POSTGRES_BASELINE_ADVISORY_LOCK)
        .execute(&mut *conn)
        .await
        .map_err(RunDbMigrateError::BaselineAdvisoryLock)?;
    ensure_sqlx_migrations_table_postgres_conn(&mut *conn).await?;

    let applied_versions = applied_versions_postgres_with_legacy_conn(&mut *conn).await?;
    if applied_versions.is_empty() {
        let object_count = postgres_application_object_count_conn(&mut *conn).await?;
        if object_count > 0 {
            return Err(RunDbMigrateError::SchemaWithoutHistory);
        }
        tx.commit()
            .await
            .map_err(RunDbMigrateError::CommitEmptyBaselineTransaction)?;
        return Ok(());
    }

    let plan = baseline_history_plan(
        "control-plane Postgres",
        &applied_versions,
        migrator,
        baseline_version,
    )?;

    sqlx::query(sql!("DELETE FROM _sqlx_migrations WHERE version < $1"))
        .bind(baseline_version)
        .execute(&mut *conn)
        .await
        .map_err(RunDbMigrateError::PruneBaselineHistory)?;

    sqlx::query(sql!(
        r"
        INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time)
        VALUES ($1, $2, TRUE, $3, 0)
        ON CONFLICT(version) DO UPDATE SET
            description = EXCLUDED.description,
            success = TRUE,
            checksum = EXCLUDED.checksum,
            execution_time = 0
        "
    ))
    .bind(plan.baseline.version)
    .bind(plan.baseline.description.as_ref())
    .bind(plan.baseline.checksum.as_ref())
    .execute(&mut *conn)
    .await
    .map_err(RunDbMigrateError::RestampBaseline)?;

    for migration in plan.preserved_post_baseline {
        sqlx::query(sql!(
            r"
            INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time)
            VALUES ($1, $2, TRUE, $3, 0)
            ON CONFLICT(version) DO NOTHING
            "
        ))
        .bind(migration.version)
        .bind(migration.description.as_ref())
        .bind(migration.checksum.as_ref())
        .execute(&mut *conn)
        .await
        .map_err(|source| RunDbMigrateError::ImportBaselineHistory {
            version: migration.version,
            source,
        })?;
    }

    tx.commit()
        .await
        .map_err(RunDbMigrateError::CommitBaselineTransaction)?;
    Ok(())
}

struct BaselineHistoryPlan<'a> {
    baseline: &'a Migration,
    preserved_post_baseline: Vec<&'a Migration>,
}

fn baseline_history_plan<'a>(
    db_name: &'static str,
    applied_versions: &[i64],
    migrator: &'a Migrator,
    baseline_version: i64,
) -> Result<BaselineHistoryPlan<'a>, RunDbMigrateError> {
    let max_applied = applied_versions.iter().copied().max().unwrap_or_default();
    if max_applied < baseline_version {
        return Err(RunDbMigrateError::BelowBaseline {
            db_name,
            max_applied,
            baseline_version,
        });
    }

    let migrations_by_version = migrations_by_version(migrator);
    let max_known = migrations_by_version
        .keys()
        .copied()
        .max()
        .unwrap_or_default();
    if max_applied > max_known {
        return Err(RunDbMigrateError::AheadOfBundledMigrations {
            db_name,
            max_applied,
            max_known,
        });
    }

    let baseline = migrations_by_version
        .get(&baseline_version)
        .copied()
        .ok_or(RunDbMigrateError::BaselineNotBundled {
            db_name,
            baseline_version,
        })?;

    let mut preserved_post_baseline = Vec::new();
    for version in applied_versions
        .iter()
        .copied()
        .filter(|version| *version > baseline_version)
    {
        let migration = migrations_by_version
            .get(&version)
            .copied()
            .ok_or(RunDbMigrateError::AppliedMigrationNotBundled { db_name, version })?;
        preserved_post_baseline.push(migration);
    }

    Ok(BaselineHistoryPlan {
        baseline,
        preserved_post_baseline,
    })
}

async fn postgres_application_object_count_conn(
    conn: &mut PgConnection,
) -> Result<i64, RunDbMigrateError> {
    sqlx::query_scalar(sql!(
        r"
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name NOT IN ('_sqlx_migrations', 'goose_db_version', '_schema_version')
        "
    ))
    .fetch_one(conn)
    .await
    .map_err(RunDbMigrateError::InspectPostgresSchema)
}

async fn applied_versions_postgres_with_legacy_conn(
    conn: &mut PgConnection,
) -> Result<Vec<i64>, RunDbMigrateError> {
    let mut versions: BTreeSet<i64> = applied_versions_postgres_conn(&mut *conn)
        .await?
        .into_iter()
        .collect();
    let has_legacy_table: bool =
        sqlx::query_scalar(sql!("SELECT to_regclass('goose_db_version') IS NOT NULL"))
            .fetch_one(&mut *conn)
            .await
            .map_err(RunDbMigrateError::CheckLegacyMigrationTable)?;

    if has_legacy_table {
        let legacy_versions: Vec<i64> = sqlx::query_scalar(sql!(
            r"
            SELECT g.version_id
            FROM goose_db_version g
            JOIN (
                SELECT version_id, MAX(id) AS id
                FROM goose_db_version
                WHERE version_id > 0
                GROUP BY version_id
            ) latest ON latest.version_id = g.version_id AND latest.id = g.id
            WHERE g.is_applied = TRUE
            ORDER BY g.version_id
            "
        ))
        .fetch_all(&mut *conn)
        .await
        .map_err(RunDbMigrateError::LoadLegacyHistory)?;
        versions.extend(legacy_versions);
    }

    Ok(versions.into_iter().collect())
}

async fn applied_versions_postgres(pool: &PgPool) -> Result<Vec<i64>, RunDbMigrateError> {
    sqlx::query_scalar(sql!(
        "SELECT version FROM _sqlx_migrations WHERE success = TRUE ORDER BY version"
    ))
    .fetch_all(pool)
    .await
    .map_err(RunDbMigrateError::LoadPostgresHistory)
}

async fn applied_versions_postgres_conn(
    conn: &mut PgConnection,
) -> Result<Vec<i64>, RunDbMigrateError> {
    sqlx::query_scalar(sql!(
        "SELECT version FROM _sqlx_migrations WHERE success = TRUE ORDER BY version"
    ))
    .fetch_all(conn)
    .await
    .map_err(RunDbMigrateError::LoadPostgresHistory)
}

async fn applied_versions_sqlite(pool: &SqlitePool) -> Result<Vec<i64>, RunDbMigrateError> {
    sqlx::query_scalar(sql!(
        "SELECT version FROM _sqlx_migrations WHERE success = TRUE ORDER BY version"
    ))
    .fetch_all(pool)
    .await
    .map_err(RunDbMigrateError::LoadSqliteHistory)
}

async fn rollback_last_postgres(
    pool: &PgPool,
    migrator: &Migrator,
) -> Result<(), RunDbMigrateError> {
    ensure_sqlx_migrations_table_postgres(pool).await?;
    let applied_versions = applied_versions_postgres(pool).await?;
    rollback_last(migrator, &applied_versions, |target| async move {
        migrator
            .undo(pool, target)
            .await
            .map_err(RunDbMigrateError::RollbackPostgres)
    })
    .await
}

async fn rollback_last_sqlite(
    pool: &SqlitePool,
    migrator: &Migrator,
) -> Result<(), RunDbMigrateError> {
    ensure_sqlx_migrations_table_sqlite(pool).await?;
    let applied_versions = applied_versions_sqlite(pool).await?;
    rollback_last(migrator, &applied_versions, |target| async move {
        migrator
            .undo(pool, target)
            .await
            .map_err(RunDbMigrateError::RollbackSqlite)
    })
    .await
}

async fn rollback_last_sqlite_database(
    database: SqliteDatabase,
    database_path: &Path,
) -> Result<(), RunDbMigrateError> {
    if let Some(admit) = database.downgrade_admission {
        let conn = open_sqlite_connection(database_path)?;
        admit(&conn)?;
    }
    let pool = sqlite_pool(database_path).await?;
    ensure_sqlx_migrations_table_sqlite(&pool).await?;

    // A public service baseline depends on the fully migrated legacy jobs schema.
    if !database.common_schema
        || (baselines::is_public(database.migrator)
            && !baselines::is_public(&COMMON_SCHEMA_MIGRATOR))
    {
        return rollback_last_sqlite(&pool, database.migrator).await;
    }

    let mut conn = open_sqlite_connection(database_path)?;
    sqlite::ensure_common_schema_migrations_table(&conn)?;
    if !sqlite::applied_common_schema_migrations(&conn)?.is_empty() {
        return rollback_last_common_schema(&mut conn);
    }

    rollback_last_sqlite(&pool, database.migrator).await
}

fn open_sqlite_connection(database_path: &Path) -> Result<Connection, RunDbMigrateError> {
    Connection::open(database_path).map_err(|source| RunDbMigrateError::OpenSqlite {
        path: database_path.to_path_buf(),
        source,
    })
}

fn rollback_last_common_schema(conn: &mut Connection) -> Result<(), RunDbMigrateError> {
    sqlite::ensure_common_schema_migrations_table(conn)?;
    let applied = sqlite::applied_common_schema_migrations(conn)?;
    let Some(current_version) = applied.keys().copied().max() else {
        println!("no applied migrations to roll back");
        return Ok(());
    };

    sqlite::rollback_common_schema_migration(conn, &COMMON_SCHEMA_MIGRATOR, current_version)?;
    let target_version = applied
        .keys()
        .copied()
        .filter(|version| *version < current_version)
        .max()
        .unwrap_or(0);
    println!("rolled back common schema migration {current_version} to {target_version}");
    Ok(())
}

async fn rollback_last<F, Fut>(
    migrator: &Migrator,
    applied_versions: &[i64],
    undo: F,
) -> Result<(), RunDbMigrateError>
where
    F: FnOnce(i64) -> Fut,
    Fut: std::future::Future<Output = Result<(), RunDbMigrateError>>,
{
    ensure_down_migration_pairs(migrator)?;

    let Some(current_version) = applied_versions.iter().copied().max() else {
        println!("no applied migrations to roll back");
        return Ok(());
    };
    let target_version = applied_versions
        .iter()
        .copied()
        .filter(|version| *version < current_version)
        .max()
        .unwrap_or(0);

    undo(target_version).await?;
    println!("rolled back migration {current_version} to {target_version}");
    Ok(())
}

fn ensure_down_migration_pairs(migrator: &Migrator) -> Result<(), RunDbMigrateError> {
    let up_versions: BTreeSet<i64> = migrator
        .iter()
        .filter(|migration| migration.migration_type == MigrationType::ReversibleUp)
        .map(|migration| migration.version)
        .collect();
    let down_versions: BTreeSet<i64> = migrator
        .iter()
        .filter(|migration| migration.migration_type == MigrationType::ReversibleDown)
        .map(|migration| migration.version)
        .collect();

    if let Some(version) = up_versions.difference(&down_versions).next() {
        return Err(RunDbMigrateError::MissingDownMigration { version: *version });
    }

    Ok(())
}

async fn print_status_postgres(
    pool: &PgPool,
    migrator: &Migrator,
) -> Result<(), RunDbMigrateError> {
    ensure_sqlx_migrations_table_postgres(pool).await?;
    print_status("service", migrator, applied_versions_postgres(pool).await?);
    Ok(())
}

async fn print_status_sqlite_database(
    database: SqliteDatabase,
    database_path: &Path,
) -> Result<(), RunDbMigrateError> {
    let pool = sqlite_pool(database_path).await?;
    ensure_sqlx_migrations_table_sqlite(&pool).await?;

    if database.common_schema {
        let conn = open_sqlite_connection(database_path)?;
        sqlite::ensure_common_schema_migrations_table(&conn)?;
        let applied = sqlite::applied_common_schema_migrations(&conn)?
            .keys()
            .copied()
            .collect::<Vec<_>>();
        print_status("common", &COMMON_SCHEMA_MIGRATOR, applied);
    }

    print_status(
        "service",
        database.migrator,
        applied_versions_sqlite(&pool).await?,
    );
    Ok(())
}

fn print_status(scope: &str, migrator: &Migrator, applied_versions: Vec<i64>) {
    let applied_versions: BTreeSet<i64> = applied_versions.into_iter().collect();
    for migration in migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
    {
        let status = if applied_versions.contains(&migration.version) {
            "applied"
        } else {
            "pending"
        };
        println!(
            "{scope}\t{status}\t{}\t{}",
            migration.version,
            migration.description.as_ref()
        );
    }
}

/// SQLSTATE of a server-side failure, or `None` when the error never
/// reached Postgres.
///
/// Borrowed rather than owned: every caller compares it against literals
/// through `as_deref`, so there is nothing to allocate.
pub(crate) fn sqlstate(error: &sqlx::Error) -> Option<Cow<'_, str>> {
    error.as_database_error().and_then(|db| db.code())
}

fn migrations_by_version(migrator: &Migrator) -> HashMap<i64, &Migration> {
    migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| (migration.version, migration))
        .collect()
}

#[cfg(test)]
mod tests;
