CREATE TABLE auto_lifecycle_delete_outbox (
    receipt_id TEXT PRIMARY KEY,
    sandbox_id TEXT NOT NULL UNIQUE,
    execution_generation INTEGER NOT NULL CHECK (execution_generation > 0),
    route_activation_id TEXT NOT NULL,
    auto_lifecycle_policy_fingerprint TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'completed')),
    created_at TEXT NOT NULL,
    completed_at TEXT,
    last_attempted_at TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    CHECK (
        (state = 'pending' AND completed_at IS NULL)
        OR (state = 'completed' AND completed_at IS NOT NULL)
    )
);

CREATE TABLE local_artifacts (
    local_artifact_id TEXT PRIMARY KEY,
    sandbox_id TEXT NOT NULL,
    artifact_kind TEXT NOT NULL CHECK (artifact_kind IN ('disk', 'full')),
    artifact_origin TEXT NOT NULL CHECK (artifact_origin IN ('stop', 'suspend', 'snapshot')),
    snapshot_name TEXT,
    local_path TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_touched_at TEXT,
    backup_completed_at TEXT,
    state TEXT NOT NULL DEFAULT 'ready'
        CHECK (state IN ('ready', 'restoring', 'deleting')),
    CHECK (
        (artifact_origin = 'snapshot' AND snapshot_name IS NOT NULL)
        OR (artifact_origin != 'snapshot' AND snapshot_name IS NULL)
    )
);

CREATE TABLE network_policy_reconcile_queue (
    sandbox_id   TEXT PRIMARY KEY,
    requested_at TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);

CREATE TABLE node_dirty_ref_revision (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    value INTEGER NOT NULL CHECK (typeof(value) = 'integer' AND value >= 0)
);

CREATE TABLE node_dirty_refs (
    facet         INTEGER NOT NULL,
    element_kind  TEXT NOT NULL,
    element_value TEXT NOT NULL,
    requested_at  TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (facet, element_kind, element_value)
);

CREATE TABLE "sandbox_cleanup_episodes" (
    sandbox_id TEXT PRIMARY KEY REFERENCES sandboxes(id) ON DELETE CASCADE,
    cleanup_id TEXT NOT NULL UNIQUE,
    completion TEXT NOT NULL CHECK (
        completion IN (
            'mark_created',
            'mark_stopped',
            'mark_suspended',
            'mark_failed',
            'delete_row',
            'delete_pool_clone'
        )
    ),
    keep_filesystem INTEGER NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('armed', 'requested')),
    entered_from_state TEXT,
    activation_state TEXT NOT NULL CHECK (
        activation_state IN ('creating', 'starting', 'restoring')
    ),
    requested_at INTEGER,
    quarantine_reason_code TEXT,
    failure_message TEXT,
    last_cleanup_error TEXT,
    execution_generation INTEGER CHECK (
        execution_generation IS NULL OR execution_generation > 0
    ),
    activation_attempt_id TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    recovery_local_artifact_id TEXT,
    recovery_execution_generation INTEGER CHECK (
        (
            recovery_local_artifact_id IS NULL
            AND recovery_execution_generation IS NULL
        )
        OR (
            recovery_local_artifact_id IS NOT NULL
            AND recovery_execution_generation IS NOT NULL
            AND recovery_execution_generation > 0
        )
    ),
    prepared_clone_root TEXT,
    operation_activation_attempt_id TEXT,
    CHECK (completion = 'delete_pool_clone' OR prepared_clone_root IS NULL),
    CHECK (completion != 'delete_pool_clone' OR (
        keep_filesystem = 0 AND activation_state = 'creating'
        AND execution_generation IS NULL AND activation_attempt_id IS NULL
        AND recovery_local_artifact_id IS NULL
    )),
    CHECK (
        (phase = 'armed' AND requested_at IS NULL)
        OR (phase = 'requested' AND requested_at IS NOT NULL)
    )
);

CREATE TABLE sandbox_execution_delete_receipts (
    sandbox_id TEXT PRIMARY KEY,
    execution_generation INTEGER NOT NULL CHECK (execution_generation > 0),
    deleted_at INTEGER NOT NULL
);

CREATE TABLE sandbox_open_route_activations (
    sandbox_id TEXT PRIMARY KEY REFERENCES sandboxes(id) ON DELETE CASCADE,
    route_generation INTEGER NOT NULL CHECK (route_generation > 0),
    node_id TEXT NOT NULL,
    execution_generation INTEGER NOT NULL CHECK (execution_generation > 0),
    pod_uid TEXT,
    substrate_kind TEXT NOT NULL CHECK (substrate_kind IN ('space', 'k8s')),
    activation_attempt_id TEXT NOT NULL,
    identity_provenance TEXT NOT NULL CHECK (
        identity_provenance IN ('unfenced', 'cluster_fenced')
    ),
    CHECK (substrate_kind != 'k8s' OR pod_uid IS NOT NULL)
);

CREATE TABLE sandbox_quarantine_history (
    id                  TEXT PRIMARY KEY,
    quarantine_id       TEXT NOT NULL,
    sandbox_id          TEXT NOT NULL,
    occurred_at         TEXT NOT NULL,
    source              TEXT NOT NULL,
    action              TEXT NOT NULL,
    reason_code         TEXT,
    message             TEXT,
    next_action         TEXT,
    next_action_after   TEXT,
    attempt_count       INTEGER,
    claim_token         TEXT,
    evidence_json       TEXT NOT NULL DEFAULT '{}',
    error               TEXT,
    CHECK (attempt_count IS NULL OR attempt_count >= 0)
);

CREATE TABLE sandbox_quarantine_state (
    sandbox_id              TEXT PRIMARY KEY,
    quarantine_id           TEXT NOT NULL UNIQUE,
    entered_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    entered_from_state      TEXT,
    source                  TEXT NOT NULL,
    reason_code             TEXT NOT NULL,
    reason_message          TEXT,
    evidence_json           TEXT NOT NULL DEFAULT '{}',
    next_action             TEXT NOT NULL,
    next_action_after       TEXT,
    next_action_owner       TEXT,
    attempt_count           INTEGER NOT NULL DEFAULT 0,
    claim_token             TEXT,
    claim_expires_at        TEXT,
    last_error              TEXT,
    FOREIGN KEY (sandbox_id) REFERENCES sandboxes(id) ON DELETE CASCADE,
    CHECK (attempt_count >= 0)
);

CREATE TABLE sandbox_restore_transfer_scopes (
    sandbox_id TEXT PRIMARY KEY,
    transfer_scope_id TEXT NOT NULL UNIQUE,
    execution_generation INTEGER
        CHECK (execution_generation IS NULL OR execution_generation > 0),
    activation_attempt_id TEXT,
    staging_dir TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE sandboxes (
    id TEXT PRIMARY KEY,
    uuid8 TEXT NOT NULL,
    state TEXT NOT NULL,
    template TEXT NOT NULL,
    template_hash TEXT,
    user TEXT NOT NULL DEFAULT '',
    runtime TEXT NOT NULL DEFAULT 'fc',
    uid INTEGER,
    slot INTEGER,
    guest_cid INTEGER,
    pid INTEGER,
    spaced_host_pid INTEGER,
    vsock_uds_path TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    netgtw_pid INTEGER,
    api_socket_path TEXT,
    snapshots_enabled BOOLEAN NOT NULL DEFAULT 0,
    pool_template TEXT,
    guest_uptime_secs INTEGER,
    process_env_json TEXT NOT NULL DEFAULT '{}',
    auto_lifecycle_json TEXT NOT NULL DEFAULT '{"wake":{"on":[]},"condition_sets":{},"stages":[]}',
    auto_lifecycle_state_json TEXT NOT NULL DEFAULT '{}',
    next_auto_event_at INTEGER,
    failure_reason TEXT,
    cleanup_completion TEXT,
    cleanup_keep_filesystem BOOLEAN,
    rootfs_size_mb INTEGER,
    network_policy_override_json TEXT,
    network_tx_bytes INTEGER NOT NULL DEFAULT 0,
    network_rx_bytes INTEGER NOT NULL DEFAULT 0,
    network_policy_generation INTEGER NOT NULL DEFAULT 0,
    applied_network_policy_generation INTEGER NOT NULL DEFAULT 0,
    applied_network_policy_source TEXT NOT NULL DEFAULT '',
    network_policy_authority TEXT NOT NULL DEFAULT 'cluster'
        CHECK (network_policy_authority IN ('cluster', 'local')),
    auto_lifecycle_authority TEXT NOT NULL DEFAULT 'cluster'
        CHECK (auto_lifecycle_authority IN ('cluster', 'local')),
    current_local_artifact_id TEXT,
    current_local_artifact_kind TEXT
        CHECK (
            current_local_artifact_kind IS NULL
            OR current_local_artifact_kind IN ('disk', 'full')
        ),
    current_local_artifact_origin TEXT
        CHECK (
            current_local_artifact_origin IS NULL
            OR current_local_artifact_origin IN ('stop', 'suspend')
        )
        CHECK (
            (
                current_local_artifact_id IS NULL
                AND current_local_artifact_kind IS NULL
                AND current_local_artifact_origin IS NULL
            )
            OR (
                current_local_artifact_id IS NOT NULL
                AND current_local_artifact_kind IS NOT NULL
                AND current_local_artifact_origin IS NOT NULL
            )
        ),
    execution_metadata_json TEXT,
    volume_encryption BOOLEAN NOT NULL DEFAULT 0,
    space_api_route_generation INTEGER,
    space_api_route_node_id TEXT,
    space_api_route_execution_generation INTEGER,
    space_api_route_pod_uid TEXT,
    restore_origin TEXT
        CHECK (restore_origin IS NULL OR restore_origin IN ('local', 'remote')),
    restore_phase TEXT
        CHECK (
            restore_phase IS NULL
            OR restore_phase IN ('metadata_staging', 'artifact_staging', 'activation')
        ),
    restore_storage_uri TEXT
        CHECK (
            (
                restore_phase IS NULL
                AND restore_origin IS NULL
                AND restore_storage_uri IS NULL
            )
            OR (
                state = 'restoring'
                AND restore_origin = 'local'
                AND restore_phase = 'activation'
                AND restore_storage_uri IS NULL
            )
            OR (
                state = 'restoring'
                AND restore_origin = 'remote'
                AND restore_phase IN ('metadata_staging', 'artifact_staging')
                AND restore_storage_uri IS NOT NULL
            )
        ),
    transition_receipt_id TEXT,
    transition_receipt_kind TEXT
    CHECK (transition_receipt_kind IS NULL OR transition_receipt_kind IN (
        'activation_completed',
        'activation_rollback',
        'quarantine_recovery'
    )),
    transition_receipt_target_state TEXT
    CHECK (transition_receipt_target_state IS NULL OR transition_receipt_target_state IN (
        'created',
        'started',
        'paused',
        'stopped',
        'suspended'
    )),
    transition_receipt_execution_generation INTEGER
    CHECK (
        transition_receipt_execution_generation IS NULL
        OR transition_receipt_execution_generation > 0
    ),
    transition_receipt_activation_attempt_id TEXT,
    transition_receipt_reason_code TEXT
    CHECK (
        (
            transition_receipt_id IS NULL
            AND transition_receipt_kind IS NULL
            AND transition_receipt_target_state IS NULL
            AND transition_receipt_execution_generation IS NULL
            AND transition_receipt_activation_attempt_id IS NULL
            AND transition_receipt_reason_code IS NULL
        )
        OR (
            transition_receipt_id IS NOT NULL
            AND transition_receipt_kind IS NOT NULL
            AND transition_receipt_target_state IS NOT NULL
            AND transition_receipt_execution_generation IS NOT NULL
            AND (
                (
                    transition_receipt_kind = 'activation_completed'
                    AND transition_receipt_target_state IN ('created', 'started', 'paused')
                    AND transition_receipt_activation_attempt_id IS NOT NULL
                    AND transition_receipt_reason_code IS NULL
                )
                OR (
                    transition_receipt_kind = 'activation_rollback'
                    AND transition_receipt_target_state IN ('created', 'stopped', 'suspended')
                    AND transition_receipt_activation_attempt_id IS NOT NULL
                    AND transition_receipt_reason_code IS NOT NULL
                )
                OR (
                    transition_receipt_kind = 'quarantine_recovery'
                    AND transition_receipt_target_state = 'suspended'
                    AND transition_receipt_reason_code IS NOT NULL
                )
            )
        )
    ),
    space_api_route_substrate_kind TEXT,
    space_api_route_activation_attempt_id TEXT,
    last_observed_execution_generation INTEGER
        CHECK (
            last_observed_execution_generation IS NULL
            OR last_observed_execution_generation > 0
        ),
    last_observed_route_activation_id TEXT,
    space_api_route_identity_provenance TEXT
        CHECK (
            space_api_route_identity_provenance IS NULL
            OR space_api_route_identity_provenance IN ('unfenced', 'cluster_fenced')
        ),
    last_observed_route_substrate_kind TEXT,
    last_observed_route_identity_provenance TEXT
        CHECK (
            last_observed_route_identity_provenance IS NULL
            OR last_observed_route_identity_provenance IN ('unfenced', 'cluster_fenced')
        ),
    auto_lifecycle_delete_block_reason TEXT
        CHECK (
            auto_lifecycle_delete_block_reason IS NULL
            OR auto_lifecycle_delete_block_reason IN (
                'node_role_unavailable',
                'node_role_not_worker',
                'partial_current_route',
                'conflicting_route_identity',
                'missing_route_identity',
                'missing_substrate',
                'unknown_substrate',
                'unknown_provenance',
                'unfenced_route'
            )
        ),
    auto_lifecycle_delete_blocked_at TEXT
        CHECK (
            (auto_lifecycle_delete_block_reason IS NULL)
            = (auto_lifecycle_delete_blocked_at IS NULL)
        ),
    last_observed_route_generation INTEGER
        CHECK (
            last_observed_route_generation IS NULL
            OR last_observed_route_generation > 0
        ),
    last_observed_route_generation_substrate_kind TEXT,
    state_changed_at TEXT NOT NULL DEFAULT '0',
    spaced_endpoint_proof_json TEXT,
    disk_io_max_operations_per_sec INTEGER NOT NULL DEFAULT 1000
        CHECK (disk_io_max_operations_per_sec > 0),
    disk_io_max_bandwidth_mib_per_sec INTEGER NOT NULL DEFAULT 100
        CHECK (disk_io_max_bandwidth_mib_per_sec > 0),
    suspend_predecessor_artifact_id TEXT,
    node_execution_id TEXT,
    previous_node_execution_id TEXT,
    node_execution_retired INTEGER NOT NULL DEFAULT 0 CHECK (node_execution_retired IN (0, 1))
);

CREATE TRIGGER arm_disarmed_inactivity_on_started
AFTER UPDATE OF state ON sandboxes
WHEN OLD.state IN ('starting', 'restoring', 'resuming')
 AND NEW.state = 'started'
 AND (
     (
         json_type(NEW.auto_lifecycle_state_json, '$.conditions.access_idle') = 'object'
         AND coalesce(
             json_extract(NEW.auto_lifecycle_state_json, '$.conditions.access_idle.armed'),
             0
         ) = 0
     )
     OR (
         json_type(NEW.auto_lifecycle_state_json, '$.conditions.command_idle') = 'object'
         AND coalesce(
             json_extract(NEW.auto_lifecycle_state_json, '$.conditions.command_idle.armed'),
             0
         ) = 0
     )
 )
BEGIN
    UPDATE sandboxes
       SET auto_lifecycle_state_json = json_set(
               auto_lifecycle_state_json,
               '$.conditions.access_idle.armed', json('true'),
               '$.conditions.access_idle.epoch_at', unixepoch(),
               '$.conditions.access_idle.last_touched_at', unixepoch(),
               '$.conditions.access_idle.last_fired_stage_index', NULL
           )
     WHERE id = NEW.id
       AND json_type(auto_lifecycle_state_json, '$.conditions.access_idle') = 'object'
       AND coalesce(
           json_extract(auto_lifecycle_state_json, '$.conditions.access_idle.armed'),
           0
       ) = 0;

    UPDATE sandboxes
       SET auto_lifecycle_state_json = json_set(
               auto_lifecycle_state_json,
               '$.conditions.command_idle.armed', json('true'),
               '$.conditions.command_idle.epoch_at', unixepoch(),
               '$.conditions.command_idle.last_touched_at', unixepoch(),
               '$.conditions.command_idle.last_fired_stage_index', NULL
           )
     WHERE id = NEW.id
       AND json_type(auto_lifecycle_state_json, '$.conditions.command_idle') = 'object'
       AND coalesce(
           json_extract(auto_lifecycle_state_json, '$.conditions.command_idle.armed'),
           0
       ) = 0;

    UPDATE sandboxes
       SET auto_lifecycle_state_json = json_set(
               auto_lifecycle_state_json,
               '$.next_auto_event_at', unixepoch()
           ),
           next_auto_event_at = unixepoch()
     WHERE id = NEW.id;
END;

CREATE TRIGGER guard_pending_auto_lifecycle_delete_receipt
BEFORE DELETE ON sandboxes
FOR EACH ROW
WHEN EXISTS (
    SELECT 1
      FROM auto_lifecycle_delete_outbox receipt
     WHERE receipt.sandbox_id = OLD.id
       AND receipt.state = 'pending'
)
BEGIN
    SELECT RAISE(ABORT, 'pending auto-lifecycle delete receipt owns sandbox deletion');
END;

CREATE INDEX idx_auto_lifecycle_delete_outbox_completed
    ON auto_lifecycle_delete_outbox (
        state,
        (attempt_count = 0),
        COALESCE(last_attempted_at, completed_at),
        completed_at,
        receipt_id
    )
    WHERE state = 'completed';

CREATE INDEX idx_jobs_kind_status ON jobs(kind, status);

CREATE INDEX idx_jobs_snapshot_upload_inflight_by_subject
  ON jobs (subject_id)
  WHERE kind = 'snapshot_upload' AND status IN ('pending', 'running');

CREATE INDEX idx_local_artifacts_backup_completed
    ON local_artifacts (backup_completed_at)
    WHERE backup_completed_at IS NOT NULL;

CREATE INDEX idx_local_artifacts_last_touched ON local_artifacts (last_touched_at);

CREATE UNIQUE INDEX idx_local_artifacts_named_snapshot
    ON local_artifacts (sandbox_id, snapshot_name)
    WHERE artifact_origin = 'snapshot';

CREATE INDEX idx_local_artifacts_path ON local_artifacts (local_path);

CREATE INDEX idx_local_artifacts_sandbox ON local_artifacts (sandbox_id);

CREATE INDEX idx_local_artifacts_state ON local_artifacts (state);

CREATE INDEX idx_sandbox_cleanup_due ON jobs (
    kind, status, priority, COALESCE(next_attempt_at, created_at), job_id
);

CREATE INDEX idx_sandbox_execution_delete_receipts_deleted_at
    ON sandbox_execution_delete_receipts (deleted_at);

CREATE INDEX idx_sandbox_quarantine_history_quarantine
    ON sandbox_quarantine_history(quarantine_id, occurred_at DESC, id DESC);

CREATE INDEX idx_sandbox_quarantine_history_sandbox
    ON sandbox_quarantine_history(sandbox_id, occurred_at DESC, id DESC);

CREATE INDEX idx_sandboxes_auto_lifecycle_delete_blocked
    ON sandboxes (auto_lifecycle_delete_block_reason, auto_lifecycle_delete_blocked_at)
    WHERE auto_lifecycle_delete_block_reason IS NOT NULL;

CREATE INDEX idx_sandboxes_created_at
    ON sandboxes(created_at, id);

CREATE INDEX idx_sandboxes_current_local_artifact ON sandboxes (current_local_artifact_id);

CREATE INDEX idx_sandboxes_eviction_candidates
  ON sandboxes (state, CAST(updated_at AS INTEGER))
  WHERE state = 'suspended';

CREATE INDEX idx_sandboxes_netgtw_process ON sandboxes (netgtw_pid, uid);

CREATE INDEX idx_sandboxes_next_auto_event_at
    ON sandboxes(next_auto_event_at, created_at)
    WHERE next_auto_event_at IS NOT NULL;

CREATE INDEX idx_sandboxes_spaced_host_process
    ON sandboxes (spaced_host_pid, uid)
    WHERE spaced_host_pid IS NOT NULL;

CREATE INDEX idx_sandboxes_suspend_predecessor_artifact
    ON sandboxes (suspend_predecessor_artifact_id);

CREATE TRIGGER node_dirty_refs_insert_revision AFTER INSERT ON node_dirty_refs
BEGIN
    UPDATE node_dirty_ref_revision SET value = value + 1 WHERE singleton = 1;
    UPDATE node_dirty_refs
    SET revision = (SELECT value FROM node_dirty_ref_revision WHERE singleton = 1)
    WHERE facet = NEW.facet AND element_kind = NEW.element_kind
      AND element_value = NEW.element_value;
END;

CREATE TRIGGER node_dirty_refs_update_revision
AFTER UPDATE OF requested_at, updated_at ON node_dirty_refs
BEGIN
    UPDATE node_dirty_ref_revision SET value = value + 1 WHERE singleton = 1;
    UPDATE node_dirty_refs
    SET revision = (SELECT value FROM node_dirty_ref_revision WHERE singleton = 1)
    WHERE facet = NEW.facet AND element_kind = NEW.element_kind
      AND element_value = NEW.element_value;
END;

CREATE TRIGGER preserve_snapshot_backup_finalization
BEFORE DELETE ON jobs
WHEN OLD.kind = 'snapshot_upload' AND OLD.status = 'completed'
BEGIN
    SELECT CASE
        WHEN NOT json_valid(OLD.payload) THEN RAISE(IGNORE)
        WHEN json_type(OLD.payload, '$.meta.local_artifact_id') IS NOT 'text'
            THEN RAISE(IGNORE)
        WHEN EXISTS (
            SELECT 1 FROM local_artifacts
            WHERE local_artifact_id = json_extract(OLD.payload, '$.meta.local_artifact_id')
              AND backup_completed_at IS NULL
        ) THEN RAISE(IGNORE)
    END;
END;

CREATE TRIGGER retain_route_identity_on_runtime_clear
AFTER UPDATE OF
    space_api_route_generation,
    space_api_route_execution_generation,
    space_api_route_activation_attempt_id,
    space_api_route_substrate_kind,
    space_api_route_identity_provenance
ON sandboxes
WHEN (
     OLD.space_api_route_generation IS NOT NULL
     OR (
         OLD.space_api_route_execution_generation IS NOT NULL
         AND OLD.space_api_route_activation_attempt_id IS NOT NULL
     )
 )
 AND (
     NEW.space_api_route_execution_generation IS NULL
     OR NEW.space_api_route_generation IS NULL
     OR NEW.space_api_route_activation_attempt_id IS NULL
     OR NEW.space_api_route_substrate_kind IS NULL
     OR NEW.space_api_route_identity_provenance IS NULL
 )
BEGIN
    UPDATE sandboxes
       SET last_observed_execution_generation = CASE
               WHEN OLD.space_api_route_execution_generation IS NULL
                    OR OLD.space_api_route_activation_attempt_id IS NULL
                   THEN last_observed_execution_generation
               WHEN last_observed_execution_generation IS NULL
                    OR OLD.space_api_route_execution_generation
                       > last_observed_execution_generation
                    OR (
                        OLD.space_api_route_execution_generation
                           = last_observed_execution_generation
                        AND (
                            last_observed_route_activation_id IS NULL
                            OR OLD.space_api_route_activation_attempt_id
                               >= last_observed_route_activation_id
                        )
                    )
                   THEN OLD.space_api_route_execution_generation
               ELSE last_observed_execution_generation
           END,
           last_observed_route_activation_id = CASE
               WHEN OLD.space_api_route_execution_generation IS NULL
                    OR OLD.space_api_route_activation_attempt_id IS NULL
                   THEN last_observed_route_activation_id
               WHEN last_observed_execution_generation IS NULL
                    OR OLD.space_api_route_execution_generation
                       > last_observed_execution_generation
                    OR (
                        OLD.space_api_route_execution_generation
                           = last_observed_execution_generation
                        AND (
                            last_observed_route_activation_id IS NULL
                            OR OLD.space_api_route_activation_attempt_id
                               >= last_observed_route_activation_id
                        )
                    )
                   THEN OLD.space_api_route_activation_attempt_id
               ELSE last_observed_route_activation_id
           END,
           last_observed_route_substrate_kind = CASE
               WHEN OLD.space_api_route_execution_generation IS NULL
                    OR OLD.space_api_route_activation_attempt_id IS NULL
                   THEN last_observed_route_substrate_kind
               WHEN last_observed_execution_generation IS NULL
                    OR OLD.space_api_route_execution_generation
                       > last_observed_execution_generation
                    OR (
                        OLD.space_api_route_execution_generation
                           = last_observed_execution_generation
                        AND (
                            last_observed_route_activation_id IS NULL
                            OR OLD.space_api_route_activation_attempt_id
                               >= last_observed_route_activation_id
                        )
                    )
                   THEN OLD.space_api_route_substrate_kind
               ELSE last_observed_route_substrate_kind
           END,
           last_observed_route_identity_provenance = CASE
               WHEN OLD.space_api_route_execution_generation IS NULL
                    OR OLD.space_api_route_activation_attempt_id IS NULL
                   THEN last_observed_route_identity_provenance
               WHEN last_observed_execution_generation IS NULL
                    OR OLD.space_api_route_execution_generation
                       > last_observed_execution_generation
                    OR (
                        OLD.space_api_route_execution_generation
                           = last_observed_execution_generation
                        AND (
                            last_observed_route_activation_id IS NULL
                            OR OLD.space_api_route_activation_attempt_id
                               >= last_observed_route_activation_id
                        )
                    )
                   THEN OLD.space_api_route_identity_provenance
               ELSE last_observed_route_identity_provenance
           END,
           last_observed_route_generation = CASE
               WHEN OLD.space_api_route_generation IS NULL
                   THEN last_observed_route_generation
               WHEN last_observed_route_generation IS NULL
                    OR OLD.space_api_route_generation >= last_observed_route_generation
                   THEN OLD.space_api_route_generation
               ELSE last_observed_route_generation
           END,
           last_observed_route_generation_substrate_kind = CASE
               WHEN OLD.space_api_route_generation IS NULL
                   THEN last_observed_route_generation_substrate_kind
               WHEN last_observed_route_generation IS NULL
                    OR OLD.space_api_route_generation >= last_observed_route_generation
                   THEN OLD.space_api_route_substrate_kind
               ELSE last_observed_route_generation_substrate_kind
           END
     WHERE id = OLD.id;
END;

CREATE INDEX sandbox_cleanup_episodes_requested ON sandbox_cleanup_episodes(phase, requested_at);

CREATE TRIGGER validate_sandbox_lifecycle_insert
BEFORE INSERT ON sandboxes
WHEN NEW.state NOT IN (
      'creating', 'created', 'starting', 'started', 'stopping', 'stopped',
      'deleting', 'pausing', 'paused', 'resuming', 'checkpointing',
      'suspending', 'suspended', 'restoring', 'cleanup_required',
      'cleanup_failed', 'quarantined', 'failed'
  )
BEGIN
    SELECT RAISE(ABORT, 'invalid sandbox lifecycle state');
END;

CREATE TRIGGER validate_sandbox_lifecycle_update
BEFORE UPDATE OF state ON sandboxes
WHEN NEW.state NOT IN (
      'creating', 'created', 'starting', 'started', 'stopping', 'stopped',
      'deleting', 'pausing', 'paused', 'resuming', 'checkpointing',
      'suspending', 'suspended', 'restoring', 'cleanup_required',
      'cleanup_failed', 'quarantined', 'failed'
  )
BEGIN
    SELECT RAISE(ABORT, 'invalid sandbox lifecycle state');
END;

PRAGMA user_version = 3;

INSERT INTO node_dirty_ref_revision (singleton, value) VALUES (1, 0);
