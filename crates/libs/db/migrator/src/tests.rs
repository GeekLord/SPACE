use rusqlite::params;

use pplx_space_sqlite_migrations::job_column_exists;

use super::*;

const COMMON_JOBS_CANCELLATION_VERSION: i64 = 6;

static ALL_MIGRATORS: &[(&str, &Migrator)] = &[
    ("common", &COMMON_SCHEMA_MIGRATOR),
    ("postgres", &POSTGRES_MIGRATOR),
    ("sandbox-manager", &SANDBOX_MANAGER_MIGRATOR),
    ("template-manager", &TEMPLATE_MANAGER_MIGRATOR),
    ("node-manager", &NODE_MANAGER_MIGRATOR),
    ("node-ctl", &NODE_CTL_MIGRATOR),
    ("runtime-manager", &RUNTIME_MANAGER_MIGRATOR),
    ("volume-manager", &VOLUME_MANAGER_MIGRATOR),
    ("build-manager", &BUILD_MANAGER_MIGRATOR),
];

#[tokio::test]
async fn sandbox_cutover_refuses_down_before_shared_schema_or_history_writes() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("sandbox.sqlite");
    let database = sqlite_sandbox_manager();
    migrate_sqlite_up(database, &path, MigrationFailurePolicy::Fail)
        .await
        .unwrap();
    let conn = Connection::open(&path).unwrap();
    conn.execute(
        "INSERT INTO jobs (job_id, kind, status) VALUES ('cancelled-witness', 'test', 'cancelled')",
        [],
    )
    .unwrap();
    // Exercise the preparation command's forward-floor refusal as well as the
    // final binary's refusal to reverse its otherwise-readable common schema.
    for required in [2, 3] {
        conn.pragma_update(None, "user_version", required).unwrap();
        let before = sqlite::applied_common_schema_migrations(&conn).unwrap();
        let schema_before: i64 = conn
            .pragma_query_value(None, "schema_version", |row| row.get(0))
            .unwrap();
        let error = rollback_last_sqlite_database(database, &path)
            .await
            .unwrap_err();
        assert!(matches!(error, RunDbMigrateError::DowngradeAdmission(_)));
        assert_eq!(
            sqlite::applied_common_schema_migrations(&conn).unwrap(),
            before
        );
        assert_eq!(
            conn.pragma_query_value(None, "schema_version", |row| row.get::<_, i64>(0))
                .unwrap(),
            schema_before
        );
        assert_eq!(
            conn.query_row(
                "SELECT status FROM jobs WHERE job_id = 'cancelled-witness'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
            "cancelled"
        );
    }
}

fn migration_applied(conn: &Connection, version: i64) -> rusqlite::Result<bool> {
    let table_exists: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map(|count| count > 0)?;
    if !table_exists {
        return Ok(false);
    }

    conn.query_row(
        "SELECT COUNT(*) FROM _sqlx_migrations WHERE version = ?1 AND success = TRUE",
        [version],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
}

fn migrate_common_schema_up(conn: &mut Connection) -> Result<(), SqliteError> {
    sqlite::migrate_common_schema_up(conn, &COMMON_SCHEMA_MIGRATOR)
}

#[test]
fn embedded_migrations_have_unique_versions() {
    for (name, migrator) in ALL_MIGRATORS {
        assert_unique_migration_versions(name, migrator);
    }
}

/// `-- no-transaction` migrations run outside a transaction so they can
/// hold statements like CREATE INDEX CONCURRENTLY — but sqlx still sends
/// the whole file to Postgres as one simple-query batch, and Postgres
/// wraps a multi-statement batch in an implicit transaction, which
/// rejects CONCURRENTLY at runtime. Enforce one statement per
/// no-transaction file so the mistake fails at PR time, not deploy time.
#[test]
fn no_transaction_migrations_are_single_statement() {
    for (name, migrator) in ALL_MIGRATORS {
        for migration in migrator.iter().filter(|migration| migration.no_tx) {
            let statements = count_sql_statements(migration.sql.as_ref());
            assert_eq!(
                statements, 1,
                "{name} migration {} ({}) is no-transaction but holds {statements} \
                 statements; Postgres runs a multi-statement simple-query batch in an \
                 implicit transaction, so keep no-transaction files to one statement",
                migration.version, migration.description,
            );
        }
    }
}

/// Counts SQL statements after stripping `--` line comments. Good enough
/// for migration files; would miscount a `--` or `;` inside a string
/// literal, which no bundled migration uses in a no-transaction file.
fn count_sql_statements(sql: &str) -> usize {
    sql.lines()
        .map(|line| line.split_once("--").map_or(line, |(code, _)| code))
        .collect::<Vec<_>>()
        .join("\n")
        .split(';')
        .filter(|chunk| !chunk.trim().is_empty())
        .count()
}

#[tokio::test]
async fn common_schema_converges_on_fresh_consumer_databases() {
    for database in sqlite_databases_with_common_schema() {
        let temp = tempfile::tempdir().unwrap();
        let db_path = temp.path().join(format!("{}.db", database.name));

        migrate_sqlite_up(database, &db_path, MigrationFailurePolicy::Fail)
            .await
            .unwrap();
        assert_common_jobs_table_matches_reader(&db_path);
        assert_common_schema_migration_applied(
            &db_path,
            COMMON_SCHEMA_MIGRATOR
                .iter()
                .filter(|migration| migration.migration_type.is_up_migration())
                .map(|migration| migration.version)
                .max()
                .unwrap(),
        );

        migrate_sqlite_up(database, &db_path, MigrationFailurePolicy::Fail)
            .await
            .unwrap();
        assert_common_jobs_table_matches_reader(&db_path);
        if database.name == "build-manager" {
            assert!(!index_exists(&db_path, "idx_build_jobs_active_template"));
        }
    }
}

#[test]
fn common_schema_allows_database_newer_than_bundled_migrations() {
    if pplx_space_common_svc::sql::baselines::is_public(&COMMON_SCHEMA_MIGRATOR) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("common.db");
    let mut conn = Connection::open(&db_path).unwrap();
    migrate_common_schema_up(&mut conn).unwrap();
    let future_version = COMMON_SCHEMA_MIGRATOR
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| migration.version)
        .max()
        .unwrap()
        + 1;
    conn.execute(
        r"
        INSERT INTO _space_common_schema_migrations
            (version, description, success, checksum, execution_time)
        VALUES (?1, 'newer', TRUE, x'00', 0)
        ",
        [future_version],
    )
    .unwrap();

    migrate_common_schema_up(&mut conn).unwrap();

    assert_common_schema_migration_applied(&db_path, future_version);
}

#[tokio::test]
async fn common_schema_converges_from_traceparent_only_databases() {
    if pplx_space_common_svc::sql::baselines::is_public(&COMMON_SCHEMA_MIGRATOR) {
        return;
    }
    for database in [sqlite_sandbox_manager(), sqlite_volume_manager()]
        .into_iter()
        .filter(|database| !baselines::is_public(database.migrator))
    {
        let temp = tempfile::tempdir().unwrap();
        let db_path = temp.path().join(format!("{}.db", database.name));

        create_traceparent_only_db(database, &db_path);
        assert!(job_column_exists_in_path(&db_path, "traceparent"));
        assert!(!job_column_exists_in_path(&db_path, "lease_owner"));

        migrate_sqlite_up(database, &db_path, MigrationFailurePolicy::Fail)
            .await
            .unwrap();
        assert_common_jobs_table_matches_reader(&db_path);
    }
}

#[tokio::test]
async fn volume_manager_converges_unstamped_legacy_jobs_columns() {
    if pplx_space_common_svc::sql::baselines::is_public(&VOLUME_MANAGER_MIGRATOR) {
        return;
    }
    let database = sqlite_volume_manager();
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("volume-manager.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch(historical_migration_sql(
        &VOLUME_MANAGER_MIGRATOR,
        1,
        sqlx::migrate::MigrationType::ReversibleUp,
    ))
    .unwrap();
    stamp_sqlite_migration(&conn, database.migrator, 1).unwrap();
    conn.execute_batch(historical_migration_sql(
        &VOLUME_MANAGER_MIGRATOR,
        2,
        sqlx::migrate::MigrationType::ReversibleUp,
    ))
    .unwrap();
    conn.execute_batch(historical_migration_sql(
        &VOLUME_MANAGER_MIGRATOR,
        3,
        sqlx::migrate::MigrationType::ReversibleUp,
    ))
    .unwrap();
    drop(conn);

    migrate_sqlite_up(database, &db_path, MigrationFailurePolicy::Fail)
        .await
        .unwrap();

    let conn = Connection::open(&db_path).unwrap();
    assert!(migration_applied(&conn, 2).unwrap());
    assert!(migration_applied(&conn, 3).unwrap());
    assert_common_jobs_table_matches_reader(&db_path);
}

#[tokio::test]
async fn compatibility_hook_creates_a_missing_database_parent() {
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("new/directory/volume-manager.db");

    migrate_sqlite_up(
        sqlite_volume_manager(),
        &db_path,
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();

    assert!(db_path.exists());
    assert_common_jobs_table_matches_reader(&db_path);
}

#[test]
fn common_schema_cancellation_adds_missing_traceparent_column() {
    if pplx_space_common_svc::sql::baselines::is_public(&COMMON_SCHEMA_MIGRATOR) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("legacy.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch(
        r#"
        CREATE TABLE jobs (
            job_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            payload TEXT NOT NULL DEFAULT '',
            subject_id TEXT,
            dedup_key TEXT,
            error_kind TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            max_attempts INTEGER NOT NULL DEFAULT 5,
            bytes_processed INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            started_at TEXT,
            completed_at TEXT,
            next_attempt_at TEXT
        );
        "#,
    )
    .unwrap();
    drop(conn);

    let mut conn = Connection::open(&db_path).unwrap();
    migrate_common_schema_up(&mut conn).unwrap();

    assert!(job_column_exists(&conn, "traceparent").unwrap());
    assert_common_schema_migration_applied(&db_path, COMMON_JOBS_CANCELLATION_VERSION);
}

#[tokio::test]
async fn sandbox_manager_pre_failure_reason_job_is_readable_and_recoverable_after_upgrade() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let database = sqlite_sandbox_manager();
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("sandbox-manager.db");

    sqlite::migrate(
        database.name,
        &db_path,
        database.migrator,
        Some(database.store.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();
    let conn = Connection::open(&db_path).unwrap();
    assert!(!job_column_exists(&conn, "failure_reason").unwrap());
    pplx_space_common_jobs::db::insert_job(
        &conn,
        pplx_space_common_jobs::db::InsertJob {
            job_id: &"019d84bd-280d-7331-99c6-b63377f3a3a2".parse().unwrap(),
            kind: "snapshot_upload",
            // This exercises shared job-column recovery, not an old inline
            // upload crossing the forward-only format gate. The queued job
            // must carry the preparation release's staged-metadata witness.
            payload: r#"{"sandbox_id":"sandbox-existing","local_artifact_id":"artifact-existing","includes_metadata_job":true}"#,
            subject_id: Some("sandbox-existing"),
            dedup_key: None,
            max_attempts: 5,
            traceparent: None,
            priority: pplx_space_common_jobs::JobPriority::default(),
        },
    )
    .unwrap();
    pplx_space_common_jobs::db::mark_job_running(
        &conn,
        &"019d84bd-280d-7331-99c6-b63377f3a3a2".parse().unwrap(),
    )
    .unwrap();
    drop(conn);

    migrate_sqlite_up(database, &db_path, MigrationFailurePolicy::Fail)
        .await
        .unwrap();

    let conn = Connection::open(&db_path).unwrap();
    assert!(job_column_exists(&conn, "failure_reason").unwrap());
    assert_common_schema_migration_applied(&db_path, 5);
    let recovered = pplx_space_common_jobs::db::recover_interrupted_jobs(
        &conn,
        &["snapshot_upload".to_string()],
    )
    .unwrap();
    assert_eq!(
        recovered,
        vec![(
            "019d84bd-280d-7331-99c6-b63377f3a3a2"
                .parse::<pplx_space_common_jobs::JobId>()
                .unwrap(),
            "snapshot_upload".to_string(),
            pplx_space_common_jobs::JobPriority::default(),
            0,
        )]
    );
    let job = pplx_space_common_jobs::db::get_job(
        &conn,
        &"019d84bd-280d-7331-99c6-b63377f3a3a2".parse().unwrap(),
    )
    .unwrap()
    .expect("migrated snapshot-upload job must remain readable");
    assert_eq!(job.subject_id.as_deref(), Some("sandbox-existing"));
    assert_eq!(job.status, "pending");
}

#[tokio::test]
async fn sandbox_manager_service_migrations_support_priority_jobs() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("sandbox-manager.db");
    sqlite::migrate(
        "sandbox-manager",
        &db_path,
        &SANDBOX_MANAGER_MIGRATOR,
        Some(baselines::SANDBOX_MANAGER.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();

    let conn = Connection::open(&db_path).unwrap();
    assert!(job_column_exists(&conn, "priority").unwrap());
    assert!(index_exists(&db_path, "idx_jobs_pending_priority"));
    pplx_space_common_jobs::db::insert_job(
        &conn,
        pplx_space_common_jobs::db::InsertJob {
            job_id: &"019d84bd-280d-7331-99c6-b63377f3a3a3".parse().unwrap(),
            kind: "snapshot_upload",
            payload: "{}",
            subject_id: Some("sandbox-priority"),
            dedup_key: None,
            max_attempts: 5,
            traceparent: None,
            priority: pplx_space_common_jobs::JobPriority::default(),
        },
    )
    .unwrap();
}

#[tokio::test]
async fn sandbox_manager_v44_database_allows_v43_migrator() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let database = sqlite_sandbox_manager();
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("sandbox-manager.db");
    migrate_sqlite_up(database, &db_path, MigrationFailurePolicy::Fail)
        .await
        .unwrap();
    let v43_migrator = Migrator::with_migrations(
        database
            .migrator
            .iter()
            .filter(|migration| migration.version <= 43)
            .cloned()
            .collect(),
    );

    sqlite::migrate(
        database.name,
        &db_path,
        &v43_migrator,
        Some(database.store.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();
    let mut conn = Connection::open(&db_path).unwrap();
    migrate_common_schema_up(&mut conn).unwrap();

    assert!(migration_applied(&conn, 44).unwrap());
    assert!(migration_applied(&conn, 45).unwrap());
    assert!(
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('sandboxes') WHERE name = 'last_observed_execution_generation'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap()
            > 0
    );
    assert!(
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('sandboxes') WHERE name = 'last_observed_route_substrate_kind'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap()
            > 0
    );
}

#[tokio::test]
async fn sandbox_manager_common_priority_schema_is_stamped_before_service_migration() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let sandbox_manager = sqlite_sandbox_manager();
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("sandbox-manager.db");
    create_traceparent_only_db(sandbox_manager, &db_path);
    let mut conn = Connection::open(&db_path).unwrap();
    migrate_common_schema_up(&mut conn).unwrap();
    drop(conn);
    assert!(job_column_exists_in_path(&db_path, "priority"));
    assert!(!migration_applied(&Connection::open(&db_path).unwrap(), 37).unwrap());

    migrate_sqlite_up(sandbox_manager, &db_path, MigrationFailurePolicy::Fail)
        .await
        .unwrap();

    assert!(migration_applied(&Connection::open(&db_path).unwrap(), 37).unwrap());
    assert_common_jobs_table_matches_reader(&db_path);
}

#[tokio::test]
async fn sandbox_manager_lifecycle_validation_preserves_history_and_survives_binary_rollback() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let database = sqlite_sandbox_manager();
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("sandbox-manager.db");
    let predecessor = Migrator::with_migrations(
        database
            .migrator
            .iter()
            .filter(|migration| migration.version <= 58)
            .cloned()
            .collect(),
    );
    sqlite::migrate(
        database.name,
        &db_path,
        &predecessor,
        Some(database.store.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();
    {
        let conn = Connection::open(&db_path).unwrap();
        conn.execute(
            "INSERT INTO sandboxes (id, uuid8, state, template, created_at, updated_at)
             VALUES ('historical', 'sandbox1', 'future_state', 'template', '0', '0')",
            [],
        )
        .unwrap();
    }

    migrate_sqlite_up(database, &db_path, MigrationFailurePolicy::Fail)
        .await
        .unwrap();
    // An older daemon's startup migrator accepts the expanded database, but
    // must not remove the successor's write validation or migration history.
    sqlite::migrate(
        database.name,
        &db_path,
        &predecessor,
        Some(database.store.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();
    let mut conn = Connection::open(&db_path).unwrap();
    migrate_common_schema_up(&mut conn).unwrap();
    assert!(migration_applied(&conn, 59).unwrap());
    conn.execute(
        "UPDATE sandboxes SET template = 'maintained' WHERE id = 'historical'",
        [],
    )
    .unwrap();
    assert_eq!(
        conn.query_row(
            "SELECT state FROM sandboxes WHERE id = 'historical'",
            [],
            |row| { row.get::<_, String>(0) }
        )
        .unwrap(),
        "future_state"
    );
    let error = conn
        .execute(
            "UPDATE sandboxes SET state = state WHERE id = 'historical'",
            [],
        )
        .unwrap_err();
    assert_eq!(
        error.sqlite_error().unwrap().extended_code,
        rusqlite::ffi::SQLITE_CONSTRAINT_TRIGGER,
    );
    let error = conn
        .execute(
            "INSERT INTO sandboxes (id, uuid8, state, template, created_at, updated_at)
             VALUES ('unknown', 'sandbox1', 'future_state', 'template', '0', '0')",
            [],
        )
        .unwrap_err();
    assert_eq!(
        error.sqlite_error().unwrap().extended_code,
        rusqlite::ffi::SQLITE_CONSTRAINT_TRIGGER,
    );
    // Older writers still use this retained terminal label.
    conn.execute(
        "UPDATE sandboxes SET state = 'failed' WHERE id = 'historical'",
        [],
    )
    .unwrap();
}

#[tokio::test]
async fn sandbox_manager_unused_columns_preserve_active_rows_and_predecessor_writers() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let database = sqlite_sandbox_manager();
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("sandbox-manager.db");
    let predecessor = Migrator::with_migrations(
        database
            .migrator
            .iter()
            .filter(|migration| migration.version <= 59)
            .cloned()
            .collect(),
    );
    sqlite::migrate(
        database.name,
        &path,
        &predecessor,
        Some(database.store.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();
    {
        let mut conn = Connection::open(&path).unwrap();
        migrate_common_schema_up(&mut conn).unwrap();
        conn.execute_batch(
            "INSERT INTO sandboxes (id, uuid8, state, template, runtime, created_at, updated_at)
             VALUES ('quarantine', 'quarant1', 'quarantined', 'template', 'fc', '1', '1'),
                    ('cleanup', 'cleanup1', 'creating', 'template', 'fc', '1', '1');
             INSERT INTO sandbox_quarantine_state
                 (sandbox_id, quarantine_id, entered_at, updated_at, source, reason_code,
                  next_action, claim_token, claim_expires_at)
             VALUES ('quarantine', 'episode', '1', '2', 'sbx_manager', 'orphaned_sandbox_row_missing',
                     'requires_operator_attention', 'claim', '2000000000');
             INSERT INTO sandbox_cleanup_episodes
                 (sandbox_id, cleanup_id, completion, keep_filesystem, phase, activation_state,
                  requested_at, execution_generation, attempt_count, created_at)
             VALUES ('cleanup', 'cleanup-episode', 'delete_row', 0, 'requested', 'creating',
                     1, 7, 3, 1);"
        ).unwrap();
    }
    let preparation = Migrator::with_migrations(
        database
            .migrator
            .iter()
            .filter(|migration| migration.version <= 60)
            .cloned()
            .collect(),
    );
    sqlite::migrate(
        database.name,
        &path,
        &preparation,
        Some(database.store.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();
    // Binary rollback uses the predecessor catalog without reversing schema.
    sqlite::migrate(
        database.name,
        &path,
        &predecessor,
        Some(database.store.baseline_version),
        MigrationFailurePolicy::Fail,
    )
    .await
    .unwrap();
    let conn = Connection::open(&path).unwrap();
    assert!(migration_applied(&conn, 60).unwrap());

    let up = historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        60,
        sqlx::migrate::MigrationType::ReversibleUp,
    );
    let down = historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        60,
        sqlx::migrate::MigrationType::ReversibleDown,
    );
    // The schema downgrade restores only unused columns/defaults. Reapplying
    // must retain ownership rows and lifecycle guards, not merely fresh DDL.
    conn.execute_batch(down).unwrap();
    let partial: bool = conn
        .query_row(
            "SELECT partial FROM pragma_index_list('sandbox_quarantine_state')
             WHERE name = 'idx_sandbox_quarantine_state_last_observed_node'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(
        partial,
        "downgrade must preserve the sparse quarantine index"
    );
    conn.execute(
        "UPDATE sandbox_quarantine_state SET last_observed_node_id = 'node'
         WHERE sandbox_id = 'quarantine'",
        [],
    )
    .unwrap();
    let indexed_sandbox: String = conn
        .query_row(
            "SELECT sandbox_id FROM sandbox_quarantine_state
             INDEXED BY idx_sandbox_quarantine_state_last_observed_node
             WHERE last_observed_node_id IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(indexed_sandbox, "quarantine");
    conn.execute_batch(up).unwrap();
    for (table, column) in [
        ("sandboxes", "compiled_network_policy_json"),
        ("sandboxes", "compiled_network_policy_sha256"),
        ("sandbox_cleanup_episodes", "rollback_failure_reason"),
        ("sandbox_quarantine_state", "last_observed_node_id"),
    ] {
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
                [table, column],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "{table}.{column}");
    }

    // These redundant projections are still written by the supported
    // predecessor, so they deliberately survive the narrower contraction.
    conn.execute_batch(
        "UPDATE sandboxes SET runtime_version = '1.15.1', guest_os = 'linux',
            guest_arch = 'aarch64', state_format_name = 'firecracker-snapshot',
            state_format_version = '9.0.0', execution_metadata_json = '{}'
         WHERE id = 'quarantine';
         INSERT INTO sandbox_execution_components (sandbox_id, kind, role_key, version)
         VALUES ('quarantine', 'kernel', '', '6.10.14');
         UPDATE sandbox_quarantine_state SET legacy_recovery_eligible = 0
         WHERE sandbox_id = 'quarantine';",
    )
    .unwrap();
    let quarantine: (String, String, String, String) = conn
        .query_row(
            "SELECT s.state, q.quarantine_id, q.claim_token, q.claim_expires_at
         FROM sandboxes s JOIN sandbox_quarantine_state q ON q.sandbox_id = s.id
         WHERE s.id = 'quarantine'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(
        quarantine,
        (
            "quarantined".into(),
            "episode".into(),
            "claim".into(),
            "2000000000".into()
        )
    );
    let cleanup: (String, String, i64, i64) = conn
        .query_row(
            "SELECT cleanup_id, phase, execution_generation, attempt_count
         FROM sandbox_cleanup_episodes WHERE sandbox_id = 'cleanup'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(
        cleanup,
        ("cleanup-episode".into(), "requested".into(), 7, 3)
    );
    let error = conn
        .execute("UPDATE sandboxes SET state = 'unknown'", [])
        .unwrap_err();
    assert_eq!(
        error.sqlite_error().unwrap().extended_code,
        rusqlite::ffi::SQLITE_CONSTRAINT_TRIGGER
    );
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap(),
        0
    );
}

#[test]
fn sandbox_manager_forward_cutover_preserves_authoritative_and_recovery_evidence() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let conn = Connection::open_in_memory().unwrap();
    for migration in SANDBOX_MANAGER_MIGRATOR
        .iter()
        .filter(|migration| migration.version <= 63 && migration.migration_type.is_up_migration())
    {
        conn.execute_batch(migration.sql.as_ref()).unwrap();
    }
    for (id, status, payload) in [
        ("old-running", "running", "{}"),
        ("bad-pending", "pending", "malformed"),
    ] {
        conn.execute("INSERT INTO jobs (job_id, kind, status, payload) VALUES (?1, 'snapshot_upload', ?2, ?3)", [id, status, payload]).unwrap();
        let tx = conn.unchecked_transaction().unwrap();
        let error = tx
            .execute_batch(historical_migration_sql(
                &SANDBOX_MANAGER_MIGRATOR,
                64,
                sqlx::migrate::MigrationType::ReversibleUp,
            ))
            .unwrap_err();
        assert!(error.to_string().contains("require staged metadata"));
        tx.rollback().unwrap();
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        // A completed historical obligation is preserved, not rewritten or
        // deleted simply to satisfy the active-work admission gate.
        conn.execute(
            "UPDATE jobs SET status = 'completed' WHERE job_id = ?1",
            [id],
        )
        .unwrap();
    }
    conn.execute_batch(
        "INSERT INTO sandboxes
            (id, uuid8, state, template, runtime, created_at, updated_at,
             execution_metadata_json, runtime_version, guest_arch)
         VALUES ('active', 'active01', 'quarantined', 'template', 'fc', '1', '1',
                 '{\"authoritative\":true}', 'obsolete', 'obsolete');
         INSERT INTO sandbox_execution_components (sandbox_id, kind, version)
         VALUES ('active', 'kernel', 'obsolete');
         INSERT INTO sandbox_quarantine_state
            (sandbox_id, quarantine_id, entered_at, updated_at, source, reason_code,
             next_action, claim_token, claim_expires_at, legacy_recovery_eligible)
         VALUES ('active', 'episode', 'malformed-time', '2', 'sbx_manager',
                 'restore_prepare_failed', 'requires_operator_attention', 'claim',
                 '2000000000', 1);
         INSERT INTO sandbox_quarantine_history
            (id, quarantine_id, sandbox_id, occurred_at, source, action, evidence_json)
         VALUES ('history', 'episode', 'active', 'malformed-time', 'sbx_manager',
                 'entered', 'malformed-evidence');",
    )
    .unwrap();
    // Historical invalid lifecycle cells remain inspectable. Contraction must
    // neither remove them nor weaken the trigger against subsequent writes.
    conn.execute_batch(historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        59,
        sqlx::migrate::MigrationType::ReversibleDown,
    ))
    .unwrap();
    conn.execute("UPDATE sandboxes SET state = 'historical-label'", [])
        .unwrap();
    conn.execute_batch(historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        59,
        sqlx::migrate::MigrationType::ReversibleUp,
    ))
    .unwrap();
    let tx = conn.unchecked_transaction().unwrap();
    tx.execute_batch(historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        64,
        sqlx::migrate::MigrationType::ReversibleUp,
    ))
    .unwrap();
    tx.commit().unwrap();
    assert_eq!(
        conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        2
    );
    assert_eq!(
        conn.query_row(
            "SELECT execution_metadata_json, state FROM sandboxes WHERE id = 'active'",
            [],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .unwrap(),
        ("{\"authoritative\":true}".into(), "historical-label".into())
    );
    assert_eq!(
        conn.query_row(
            "SELECT quarantine_id, entered_at, claim_token, claim_expires_at
         FROM sandbox_quarantine_state WHERE sandbox_id = 'active'",
            [],
            |row| Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?
            )),
        )
        .unwrap(),
        (
            "episode".into(),
            "malformed-time".into(),
            "claim".into(),
            "2000000000".into()
        )
    );
    assert_eq!(
        conn.query_row(
            "SELECT evidence_json FROM sandbox_quarantine_history WHERE id = 'history'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap(),
        "malformed-evidence"
    );
    for (table, column) in [
        ("sandboxes", "runtime_version"),
        ("sandboxes", "guest_os"),
        ("sandboxes", "guest_arch"),
        ("sandboxes", "state_format_name"),
        ("sandboxes", "state_format_version"),
        ("sandbox_quarantine_state", "legacy_recovery_eligible"),
    ] {
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
                [table, column],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            0,
            "{table}.{column}"
        );
    }
    assert_eq!(
        conn.query_row(
            "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'sandbox_execution_components'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap(),
        0
    );
    for index in [
        "idx_sandboxes_execution",
        "idx_sandbox_quarantine_state_due",
        "idx_sandbox_quarantine_state_claim_expires",
    ] {
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'index' AND name = ?1",
                [index],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
    }
    for (id, payload) in [("old-running", "{}"), ("bad-pending", "malformed")] {
        assert_eq!(
            conn.query_row(
                "SELECT payload FROM jobs WHERE job_id = ?1 AND status = 'completed'",
                [id],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
            payload
        );
    }
    conn.execute("UPDATE sandboxes SET state = 'another-invalid-state'", [])
        .unwrap_err();
    conn.pragma_update(None, "ignore_check_constraints", true)
        .unwrap();
    let tx = conn.unchecked_transaction().unwrap();
    let error = tx
        .execute_batch(historical_migration_sql(
            &SANDBOX_MANAGER_MIGRATOR,
            64,
            sqlx::migrate::MigrationType::ReversibleDown,
        ))
        .unwrap_err();
    assert!(error.to_string().contains("use a forward migration"));
    tx.rollback().unwrap();
    assert_eq!(
        conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        2
    );
}

#[tokio::test]
async fn sandbox_cutover_preserves_conflicting_development_history() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    use std::error::Error;

    for legacy_floor in [None, Some(2), Some(3)] {
        let database = sqlite_sandbox_manager();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("sandbox.sqlite");
        // Main owns version 62. Pre-merge development builds used that version
        // for contraction instead; never reinterpret or restamp that history.
        let predecessor = Migrator::with_migrations(
            database
                .migrator
                .iter()
                .filter(|migration| match legacy_floor {
                    None => migration.version <= 63,
                    Some(floor) => {
                        migration.version < 62
                            || (migration.version >= 64 && migration.version <= floor + 62)
                    }
                })
                .cloned()
                .map(|mut migration| {
                    if legacy_floor.is_some() && migration.version >= 64 {
                        migration.version -= 2;
                    }
                    migration
                })
                .collect(),
        );
        sqlite::migrate(
            database.name,
            &path,
            &predecessor,
            Some(database.store.baseline_version),
            MigrationFailurePolicy::Fail,
        )
        .await
        .unwrap();
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "INSERT INTO sandboxes (id, uuid8, state, template, runtime, created_at, updated_at)
             VALUES ('retained', 'retained', 'suspended', 'seed', 'fc', '1', '1')",
        )
        .unwrap();
        let checksum_before: Vec<u8> = conn
            .query_row(
                "SELECT checksum FROM _sqlx_migrations WHERE version = 62",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let schema_before: String = conn
            .query_row(
                "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'sandboxes'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let result = migrate_sqlite_up(database, &path, MigrationFailurePolicy::Fail).await;
        if let Some(floor) = legacy_floor {
            let error = result.unwrap_err();
            let mut cause: &(dyn Error + 'static) = &error;
            while let Some(source) = cause.source() {
                cause = source;
            }
            assert!(matches!(
                cause.downcast_ref::<sqlx::migrate::MigrateError>(),
                Some(sqlx::migrate::MigrateError::VersionMismatch(62))
            ));
            assert_eq!(
                conn.query_row(
                    "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'sandboxes'",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
                schema_before
            );
            assert_eq!(
                conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                    .unwrap(),
                floor
            );
        } else {
            result.unwrap();
            assert_eq!(
                conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                    .unwrap(),
                3
            );
            conn.query_row(
                "SELECT auto_lifecycle_delete_mode FROM sandboxes WHERE id = 'retained'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap_err();
        }
        assert_eq!(
            conn.query_row(
                "SELECT checksum FROM _sqlx_migrations WHERE version = 62",
                [],
                |row| row.get::<_, Vec<u8>>(0)
            )
            .unwrap(),
            checksum_before
        );
        assert_eq!(
            conn.query_row(
                "SELECT state FROM sandboxes WHERE id = 'retained'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
            "suspended"
        );
    }
}

#[test]
fn delete_mode_cutover_preserves_blocked_rows_and_receipt_ownership() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let conn = Connection::open_in_memory().unwrap();
    for migration in SANDBOX_MANAGER_MIGRATOR
        .iter()
        .filter(|migration| migration.version <= 64 && migration.migration_type.is_up_migration())
    {
        conn.execute_batch(migration.sql.as_ref()).unwrap();
    }
    for (id, mode, receipt_state) in [
        ("unproven", "legacy", "pending"),
        ("fenced", "strict", "completed"),
    ] {
        conn.execute(
            "INSERT INTO sandboxes
             (id, uuid8, state, template, runtime, created_at, updated_at,
              auto_lifecycle_delete_mode, auto_lifecycle_delete_block_reason,
              auto_lifecycle_delete_blocked_at, last_observed_execution_generation,
              last_observed_route_activation_id, last_observed_route_substrate_kind,
              last_observed_route_identity_provenance)
             VALUES (?1, ?1, 'suspended', 'seed', 'fc', '1', '1', ?2,
                     'missing_route_identity', '2', 7, 'attempt', 'k8s', 'cluster_fenced')",
            [id, mode],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO auto_lifecycle_delete_outbox
             (receipt_id, sandbox_id, execution_generation, route_activation_id,
              auto_lifecycle_policy_fingerprint, state, created_at, completed_at)
             VALUES (?1, ?1, 7, 'attempt', 'policy', ?2, '1',
                     CASE WHEN ?2 = 'completed' THEN '2' ELSE NULL END)",
            [id, receipt_state],
        )
        .unwrap();
    }
    let tx = conn.unchecked_transaction().unwrap();
    tx.execute_batch(historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        65,
        sqlx::migrate::MigrationType::ReversibleUp,
    ))
    .unwrap();
    tx.commit().unwrap();
    assert_eq!(
        conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        3
    );
    conn.prepare("SELECT auto_lifecycle_delete_mode FROM sandboxes")
        .unwrap_err();
    assert_eq!(conn.query_row(
        "SELECT COUNT(*) FROM sandboxes WHERE auto_lifecycle_delete_block_reason = 'missing_route_identity'
         AND auto_lifecycle_delete_blocked_at = '2' AND last_observed_execution_generation = 7
         AND last_observed_route_activation_id = 'attempt' AND last_observed_route_substrate_kind = 'k8s'
         AND last_observed_route_identity_provenance = 'cluster_fenced'", [], |row| row.get::<_, i64>(0)
    ).unwrap(), 2);
    assert_eq!(
        conn.execute("DELETE FROM sandboxes WHERE id = 'unproven'", [])
            .unwrap_err()
            .sqlite_error()
            .unwrap()
            .extended_code,
        rusqlite::ffi::SQLITE_CONSTRAINT_TRIGGER
    );
    assert_eq!(
        conn.execute("DELETE FROM sandboxes WHERE id = 'fenced'", [])
            .unwrap(),
        1
    );
    assert_eq!(
        conn.query_row(
            "SELECT COUNT(*) FROM auto_lifecycle_delete_outbox",
            [],
            |row| row.get::<_, i64>(0)
        )
        .unwrap(),
        2
    );
    let tx = conn.unchecked_transaction().unwrap();
    let error = tx
        .execute_batch(historical_migration_sql(
            &SANDBOX_MANAGER_MIGRATOR,
            65,
            sqlx::migrate::MigrationType::ReversibleDown,
        ))
        .unwrap_err();
    assert!(error.to_string().contains("use a forward migration"));
    tx.rollback().unwrap();
    assert_eq!(
        conn.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        3
    );
}

#[test]
fn common_schema_down_round_trip_removes_and_restores_lease_columns() {
    if pplx_space_common_svc::sql::baselines::is_public(&COMMON_SCHEMA_MIGRATOR) {
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let db_path = temp.path().join("common.db");
    let mut conn = Connection::open(&db_path).unwrap();

    migrate_common_schema_up(&mut conn).unwrap();
    assert!(job_column_exists(&conn, "lease_owner").unwrap());
    assert!(job_column_exists(&conn, "priority").unwrap());
    assert!(job_column_exists(&conn, "failure_reason").unwrap());
    assert!(index_exists(&db_path, "idx_jobs_created_at"));
    assert!(index_exists(&db_path, "idx_jobs_pending_priority"));

    // Newer common-schema migrations may be added above failure_reason.
    // Roll them all back without making this feature-boundary test depend
    // on whichever version happens to be latest.
    rollback_common_schema_to(&mut conn, 5);
    assert!(job_column_exists(&conn, "lease_owner").unwrap());
    assert!(job_column_exists(&conn, "priority").unwrap());
    assert!(job_column_exists(&conn, "failure_reason").unwrap());
    assert!(index_exists(&db_path, "idx_jobs_created_at"));
    assert!(index_exists(&db_path, "idx_jobs_pending_priority"));
    assert_common_schema_migration_applied(&db_path, 5);

    rollback_last_common_schema(&mut conn).unwrap();
    assert!(job_column_exists(&conn, "lease_owner").unwrap());
    assert!(job_column_exists(&conn, "priority").unwrap());
    assert!(!job_column_exists(&conn, "failure_reason").unwrap());
    assert!(index_exists(&db_path, "idx_jobs_created_at"));
    assert!(index_exists(&db_path, "idx_jobs_pending_priority"));
    assert_common_schema_migration_applied(&db_path, 4);

    rollback_last_common_schema(&mut conn).unwrap();
    assert!(job_column_exists(&conn, "lease_owner").unwrap());
    assert!(!job_column_exists(&conn, "priority").unwrap());
    assert!(index_exists(&db_path, "idx_jobs_created_at"));
    assert!(!index_exists(&db_path, "idx_jobs_pending_priority"));
    assert_common_schema_migration_applied(&db_path, 3);

    rollback_last_common_schema(&mut conn).unwrap();
    assert!(job_column_exists(&conn, "lease_owner").unwrap());
    assert!(!index_exists(&db_path, "idx_jobs_created_at"));
    assert_common_schema_migration_applied(&db_path, 2);

    rollback_last_common_schema(&mut conn).unwrap();
    assert!(!job_column_exists(&conn, "lease_owner").unwrap());
    assert_common_schema_migration_applied(&db_path, 1);

    migrate_common_schema_up(&mut conn).unwrap();
    assert!(job_column_exists(&conn, "lease_owner").unwrap());
    assert!(job_column_exists(&conn, "priority").unwrap());
    assert!(job_column_exists(&conn, "failure_reason").unwrap());
    assert_common_schema_migration_applied(&db_path, 2);
    assert_common_schema_migration_applied(&db_path, 3);
    assert_common_schema_migration_applied(&db_path, 4);
    assert_common_schema_migration_applied(&db_path, 5);
    assert_common_schema_migration_applied(&db_path, latest_common_schema_version());
    assert!(index_exists(&db_path, "idx_jobs_created_at"));
    assert!(index_exists(&db_path, "idx_jobs_pending_priority"));
}

fn sqlite_databases_with_common_schema() -> [SqliteDatabase; 5] {
    [
        sqlite_sandbox_manager(),
        sqlite_template_manager(),
        sqlite_volume_manager(),
        sqlite_build_manager(),
        sqlite_runtime_manager(),
    ]
}

/// Build the schema state of a node-local DB last migrated before the
/// service bundled its jobs-leases migration: every service migration up
/// to (but excluding) "jobs leases" is applied and stamped, so the jobs
/// table has `traceparent` but none of the lease columns.
fn create_traceparent_only_db(database: SqliteDatabase, db_path: &Path) {
    let lease_version = database
        .migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .find(|migration| migration.description.as_ref() == "jobs leases")
        .expect("service migrator must bundle a jobs leases migration")
        .version;

    let conn = Connection::open(db_path).unwrap();
    for migration in database.migrator.iter().filter(|migration| {
        migration.migration_type.is_up_migration() && migration.version < lease_version
    }) {
        conn.execute_batch(migration.sql.as_ref()).unwrap();
        stamp_sqlite_migration(&conn, database.migrator, migration.version).unwrap();
    }
}

fn assert_common_jobs_table_matches_reader(db_path: &Path) {
    let expected = pplx_space_common_jobs::db::JOB_TABLE_COLUMNS
        .iter()
        .map(|column| column.to_string())
        .collect::<Vec<_>>();
    assert_eq!(jobs_columns(db_path), expected);

    let actual = expected.iter().map(String::as_str).collect::<BTreeSet<_>>();
    for column in pplx_space_common_jobs::db::selected_job_columns() {
        assert!(
            actual.contains(column),
            "jobs schema is missing selected column {column}"
        );
    }
    assert!(index_exists(db_path, "idx_jobs_lease_expiry"));
    assert!(index_exists(db_path, "idx_jobs_dedup_latest"));
    assert!(index_exists(db_path, "idx_jobs_created_at"));
    assert!(index_exists(db_path, "idx_jobs_status_created_at"));
    assert!(index_exists(db_path, "idx_jobs_subject_created_at"));
    assert!(index_exists(db_path, "idx_jobs_active_kind_status"));
    assert!(index_exists(db_path, "idx_jobs_pending_priority"));
}

fn assert_common_schema_migration_applied(db_path: &Path, version: i64) {
    let conn = Connection::open(db_path).unwrap();
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM _space_common_schema_migrations WHERE version = ?1 AND success = TRUE",
            params![version],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
}

fn jobs_columns(db_path: &Path) -> Vec<String> {
    let conn = Connection::open(db_path).unwrap();
    let mut stmt = conn
        .prepare("SELECT name FROM pragma_table_info('jobs') ORDER BY cid")
        .unwrap();
    stmt.query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

fn job_column_exists_in_path(db_path: &Path, column: &str) -> bool {
    let conn = Connection::open(db_path).unwrap();
    job_column_exists(&conn, column).unwrap()
}

fn index_exists(db_path: &Path, index: &str) -> bool {
    let conn = Connection::open(db_path).unwrap();
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1",
        params![index],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .unwrap()
}

#[test]
fn sandbox_manager_migration_22_stays_jobs() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let sandbox_migrations = migrations_by_version(&SANDBOX_MANAGER_MIGRATOR);
    assert_eq!(
        sandbox_migrations
            .get(&22)
            .expect("sandbox-manager migration 22 must exist")
            .description
            .as_ref(),
        "jobs"
    );
    assert_eq!(
        sandbox_migrations
            .get(&23)
            .expect("sandbox-manager migration 23 must exist")
            .description
            .as_ref(),
        "policy authority"
    );
}

#[test]
fn v68_collision_repair_constant_matches_renamed_orphan() {
    if baselines::is_public(&POSTGRES_MIGRATOR) {
        return;
    }
    let orphan = POSTGRES_MIGRATOR
        .iter()
        .find(|migration| migration.description.as_ref() == COLLIDED_V68_ORPHAN_DESCRIPTION)
        .expect("orphan-on-delete migration must remain bundled");
    assert_eq!(
        orphan.version, 69,
        "orphan-on-delete must stay at v69 — the v68 collision repair keys off its description being absent from v68"
    );
}

#[test]
fn v82_collision_repair_assumptions_match_warm_pool_renumbering() {
    if baselines::is_public(&POSTGRES_MIGRATOR) {
        return;
    }
    let postgres_migrations = migrations_by_version(&POSTGRES_MIGRATOR);
    assert_eq!(
        postgres_migrations
            .get(&82)
            .expect("Postgres migration 82 must exist")
            .description
            .as_ref(),
        "snapshots ready latest covering index"
    );
    assert_eq!(
        postgres_migrations
            .get(&84)
            .expect("Postgres migration 84 must exist")
            .description
            .as_ref(),
        COLLIDED_V82_WARM_POOL_DESCRIPTION,
        "warm-pool pacing must stay at v84 so the v82 collision repair can re-key stale history to it"
    );
}

#[test]
fn postgres_migrations_start_at_baseline_for_fresh_databases() {
    if baselines::is_public(&POSTGRES_MIGRATOR) {
        return;
    }
    let first_postgres_version = POSTGRES_MIGRATOR
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| migration.version)
        .min()
        .unwrap();
    assert_eq!(first_postgres_version, baselines::POSTGRES);
}

#[test]
fn postgres_baseline_plan_preserves_testing_history() {
    if baselines::is_public(&POSTGRES_MIGRATOR) {
        return;
    }
    assert_postgres_baseline_plan(1..=60, 45..=60);
}

#[test]
fn postgres_baseline_plan_preserves_prod_history() {
    if baselines::is_public(&POSTGRES_MIGRATOR) {
        return;
    }
    assert_postgres_baseline_plan(1..=54, 45..=54);
}

fn assert_postgres_baseline_plan(
    applied: std::ops::RangeInclusive<i64>,
    preserved: std::ops::RangeInclusive<i64>,
) {
    let applied_versions = applied.collect::<Vec<_>>();
    let plan = baseline_history_plan(
        "control-plane Postgres",
        &applied_versions,
        &POSTGRES_MIGRATOR,
        baselines::POSTGRES,
    )
    .unwrap();
    assert_eq!(plan.baseline.version, baselines::POSTGRES);
    let preserved_versions = plan
        .preserved_post_baseline
        .iter()
        .map(|migration| migration.version)
        .collect::<Vec<_>>();
    assert_eq!(preserved_versions, preserved.collect::<Vec<_>>());
}

mod postgres_baseline_tests;
mod postgres_collision_repair_tests;
mod public_baseline_rollback_tests;

fn assert_unique_migration_versions(name: &str, migrator: &Migrator) {
    let mut up_versions = BTreeSet::new();
    let mut down_versions = BTreeSet::new();

    for migration in migrator.iter() {
        if migration.migration_type.is_up_migration() {
            assert!(
                up_versions.insert(migration.version),
                "{name} has duplicate up migration version {}",
                migration.version
            );
            continue;
        }

        assert!(
            down_versions.insert(migration.version),
            "{name} has duplicate down migration version {}",
            migration.version
        );
    }
}

fn historical_migration_sql(
    migrator: &sqlx::migrate::Migrator,
    version: i64,
    kind: sqlx::migrate::MigrationType,
) -> &str {
    migrator
        .iter()
        .find(|migration| migration.version == version && migration.migration_type == kind)
        .expect("historical migration must remain bundled until cutover")
        .sql
        .as_ref()
}

#[test]
fn prepared_clone_migration_preserves_episodes_and_blocks_unsafe_downgrade() {
    if pplx_space_common_svc::sql::baselines::is_public(&SANDBOX_MANAGER_MIGRATOR) {
        return;
    }
    let mut conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
    for migration in SANDBOX_MANAGER_MIGRATOR
        .iter()
        .filter(|migration| migration.version <= 51 && migration.migration_type.is_up_migration())
    {
        conn.execute_batch(migration.sql.as_ref()).unwrap();
    }
    conn.execute_batch(
        "INSERT INTO sandboxes (id,uuid8,state,template,user,runtime,created_at,updated_at)
         VALUES ('migration-fixture','fixture','creating','seed','deploy','fc','now','now');
         INSERT INTO sandbox_cleanup_episodes
         (sandbox_id,cleanup_id,completion,keep_filesystem,phase,activation_state,
          requested_at,failure_message,last_cleanup_error,created_at,execution_generation,activation_attempt_id,attempt_count)
         VALUES ('migration-fixture','cleanup-fixture','delete_row',0,'requested','creating',123,
          'retained failure','retained cleanup error',122,17,'attempt-fixture',3);"
    ).unwrap();
    let columns: Vec<String> = conn
        .prepare("SELECT name FROM pragma_table_info('sandbox_cleanup_episodes')")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    let read = |conn: &Connection| -> Vec<rusqlite::types::Value> {
        conn.query_row(
            &format!("SELECT {} FROM sandbox_cleanup_episodes", columns.join(",")),
            [],
            |row| (0..columns.len()).map(|i| row.get(i)).collect(),
        )
        .unwrap()
    };
    let before = read(&conn);
    let up = historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        52,
        sqlx::migrate::MigrationType::ReversibleUp,
    );
    let down = historical_migration_sql(
        &SANDBOX_MANAGER_MIGRATOR,
        52,
        sqlx::migrate::MigrationType::ReversibleDown,
    );
    for migration in [up, down, up] {
        let tx = conn.transaction().unwrap();
        tx.execute_batch(migration).unwrap();
        tx.commit().unwrap();
        assert_eq!(read(&conn), before);
    }
    let identity = r#"{"device":7,"inode":18446744073709551615}"#;
    conn.execute(
        "UPDATE sandbox_cleanup_episodes SET completion='delete_pool_clone',
        execution_generation=NULL, activation_attempt_id=NULL, prepared_clone_root=?1",
        [identity],
    )
    .unwrap();
    {
        let tx = conn.transaction().unwrap();
        tx.execute_batch(down)
            .expect_err("downgrade must retain pending disposal authority");
    }
    assert_eq!(
        conn.query_row(
            "SELECT prepared_clone_root FROM sandbox_cleanup_episodes",
            [],
            |row| row.get::<_, String>(0)
        )
        .unwrap(),
        identity
    );
    assert_eq!(
        conn.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap(),
        0
    );
}

fn latest_common_schema_version() -> i64 {
    COMMON_SCHEMA_MIGRATOR
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| migration.version)
        .max()
        .expect("common schema migrator contains an up migration")
}

fn rollback_common_schema_to(conn: &mut Connection, target_version: i64) {
    loop {
        let current_version = sqlite::applied_common_schema_migrations(conn)
            .unwrap()
            .keys()
            .copied()
            .max()
            .expect("common schema has at least its baseline migration");
        assert!(
            current_version >= target_version,
            "common schema already rolled past target version {target_version}"
        );
        if current_version == target_version {
            break;
        }
        rollback_last_common_schema(conn).unwrap();
    }
}
