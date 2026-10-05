CREATE TABLE network_pool_meta (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  INTEGER NOT NULL
);

CREATE TABLE network_slots (
    slot_id                    INTEGER PRIMARY KEY,
    slot_label                 TEXT NOT NULL,
    generation                 INTEGER NOT NULL DEFAULT 0,
    schema_version             INTEGER NOT NULL,
    state                      TEXT NOT NULL,
    health                     TEXT NOT NULL,
    sandbox_id                 TEXT,
    sandbox_uid                INTEGER,
    pod_netns_path             TEXT,
    lease_kind                 TEXT NOT NULL DEFAULT 'pooled',
    pid                        INTEGER,
    last_error                 TEXT,
    reuse_count                INTEGER NOT NULL DEFAULT 0,
    quarantine_count           INTEGER NOT NULL DEFAULT 0,
    created_at                 INTEGER NOT NULL,
    updated_at                 INTEGER NOT NULL,
    last_reset_at              INTEGER,
    last_schema_migration_at   INTEGER,
    memory_reservation_mib     INTEGER,
    cleanup_reset_attempts     INTEGER NOT NULL DEFAULT 0,
    last_reset_retry_at        INTEGER
);

CREATE TABLE sandbox_executions (
    sandbox_id TEXT PRIMARY KEY NOT NULL,
    execution_id TEXT NOT NULL,
    previous_id TEXT CHECK (previous_id IS NULL OR previous_id != execution_id)
);

CREATE UNIQUE INDEX idx_network_slots_active_sandbox
    ON network_slots(sandbox_id)
    WHERE sandbox_id IS NOT NULL
      AND state IN ('leasing', 'leased');
