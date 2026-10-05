//! Current SQL migration baseline versions for each SPACE-owned store.

#[cfg(feature = "sqlite")]
use super::sqlite::MigrationFailurePolicy;

pub const POSTGRES: i64 = 44;

#[cfg(feature = "sqlite")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SqliteStoreConfig {
    pub baseline_version: i64,
    pub migration_failure_policy: MigrationFailurePolicy,
}

#[cfg(feature = "sqlite")]
pub const SANDBOX_MANAGER: SqliteStoreConfig = SqliteStoreConfig {
    baseline_version: 20,
    // The sandbox-manager DB tracks live local VM state and must fail closed.
    migration_failure_policy: MigrationFailurePolicy::Fail,
};

#[cfg(feature = "sqlite")]
pub const TEMPLATE_MANAGER: SqliteStoreConfig = SqliteStoreConfig {
    baseline_version: 1,
    // Local-authority policies and their generation sequence cannot be reconstructed.
    migration_failure_policy: MigrationFailurePolicy::Fail,
};

#[cfg(feature = "sqlite")]
pub const NODE_MANAGER: SqliteStoreConfig = SqliteStoreConfig {
    baseline_version: 1,
    // Runtime probes cannot reconstruct erased lease identities and generations.
    migration_failure_policy: MigrationFailurePolicy::Fail,
};

#[cfg(feature = "sqlite")]
pub const NODE_CTL: SqliteStoreConfig = SqliteStoreConfig {
    baseline_version: 4,
    // Node controller state is rebuilt by periodic cluster/node reconciliation.
    migration_failure_policy: MigrationFailurePolicy::Recreate,
};

#[cfg(feature = "sqlite")]
pub const VOLUME_MANAGER: SqliteStoreConfig = SqliteStoreConfig {
    baseline_version: 1,
    // Volume manager state (attachments + transfer jobs) survives restarts and
    // tracks in-flight S3 transfers; treat it as authoritative and fail closed.
    migration_failure_policy: MigrationFailurePolicy::Fail,
};

#[cfg(feature = "sqlite")]
pub const BUILD_MANAGER: SqliteStoreConfig = SqliteStoreConfig {
    baseline_version: 1,
    // Build-manager jobs are the authoritative daemon-side state for active
    // template builds. A migration failure would make status polling lie.
    migration_failure_policy: MigrationFailurePolicy::Fail,
};

#[cfg(feature = "sqlite")]
pub const RUNTIME_MANAGER: SqliteStoreConfig = SqliteStoreConfig {
    baseline_version: 1,
    // Install records are the only evidence of which kernels the runtime
    // manager owns; recreating the database would disown them.
    migration_failure_policy: MigrationFailurePolicy::Fail,
};

/// First supported public SQLite migration epoch.
#[cfg(feature = "sqlite")]
pub const PUBLIC_SQLITE_BASELINE: i64 = 20260930000000;

/// Legacy admission remains active until the bundled catalog starts at a public baseline.
#[cfg(feature = "sqlite")]
pub fn is_public(migrator: &sqlx::migrate::Migrator) -> bool {
    migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| migration.version)
        .min()
        .is_some_and(|version| version >= PUBLIC_SQLITE_BASELINE)
}
