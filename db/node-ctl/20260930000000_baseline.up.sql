CREATE TABLE dirty_facets (
    facet TEXT NOT NULL,
    element TEXT NOT NULL,
    dirty INTEGER NOT NULL DEFAULT 1,
    dirty_generation INTEGER NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL,
    last_attempt_at INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    claim_token TEXT NOT NULL DEFAULT '',
    claimed_at INTEGER NOT NULL DEFAULT 0,
    dead_at INTEGER NOT NULL DEFAULT 0,
    dead_reason TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (facet, element)
);

CREATE TABLE dirty_node_state (
    kind TEXT NOT NULL,
    resource_id TEXT NOT NULL,
    dirty INTEGER NOT NULL DEFAULT 1,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL,
    last_attempt_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (kind, resource_id)
);

CREATE TABLE facet_sync_overrides (
    facet TEXT NOT NULL,
    direction TEXT NOT NULL,
    disabled_until INTEGER,
    reason TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (facet, direction)
);

CREATE TABLE reconciliation_status (
    name TEXT PRIMARY KEY,
    poll_interval_secs INTEGER NOT NULL,
    last_started_at INTEGER NOT NULL DEFAULT 0,
    last_completed_at INTEGER NOT NULL DEFAULT 0,
    last_success_at INTEGER NOT NULL DEFAULT 0,
    next_due_at INTEGER NOT NULL DEFAULT 0,
    running INTEGER NOT NULL DEFAULT 0,
    templates_seen INTEGER NOT NULL DEFAULT 0,
    sandboxes_seen INTEGER NOT NULL DEFAULT 0,
    templates_applied INTEGER NOT NULL DEFAULT 0,
    sandboxes_applied INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
);

CREATE INDEX idx_dirty_facets_dead
    ON dirty_facets(facet, updated_at)
    WHERE dead_at != 0;
