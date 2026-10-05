CREATE TABLE node_dirty_refs (
    facet          INTEGER NOT NULL,
    element_kind   TEXT NOT NULL,
    element_value  TEXT NOT NULL,
    requested_at   TEXT NOT NULL,
    updated_at     TEXT NOT NULL,
    PRIMARY KEY (facet, element_kind, element_value)
);

CREATE TABLE pools (
    template      TEXT PRIMARY KEY,
    target_count  INTEGER NOT NULL DEFAULT 3,
    boot_mode     TEXT NOT NULL DEFAULT 'cold',
    vcpu          INTEGER NOT NULL DEFAULT 2,
    memory_mib    INTEGER NOT NULL DEFAULT 1024,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE template_build_components (
    name          TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    kind          TEXT NOT NULL,
    role_key      TEXT NOT NULL DEFAULT '',
    version       TEXT,
    digest        TEXT,
    format        TEXT,
    PRIMARY KEY (name, content_hash, kind, role_key),
    FOREIGN KEY (name, content_hash)
        REFERENCES template_builds(name, content_hash) ON DELETE CASCADE
);

CREATE TABLE template_builds (
    name                  TEXT NOT NULL,
    content_hash          TEXT NOT NULL,
    build_date            TEXT NOT NULL,
    manifest_json         TEXT NOT NULL,
    runtime               TEXT NOT NULL,
    arch                  TEXT NOT NULL,
    artifact_size_bytes   INTEGER NOT NULL DEFAULT 0,
    state                 TEXT NOT NULL DEFAULT 'ready',
    owner_type            TEXT NOT NULL DEFAULT '',
    owner_id              TEXT NOT NULL DEFAULT '',
    created_at            TEXT NOT NULL,
    last_used_at TEXT NOT NULL DEFAULT '0',
    runtime_version TEXT,
    guest_os TEXT,
    state_format_name TEXT,
    state_format_version TEXT,
    execution_metadata_json TEXT,
    PRIMARY KEY (name, content_hash)
);

CREATE TABLE template_local_policy_sequence (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    generation INTEGER NOT NULL CHECK (typeof(generation) = 'integer' AND generation > 0)
);

CREATE TABLE template_network_policy_notifications (
    template      TEXT PRIMARY KEY,
    policy_json   TEXT NOT NULL,
    generation    INTEGER NOT NULL,
    requested_at  TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    authority TEXT NOT NULL DEFAULT 'cluster'
        CHECK (authority IN ('cluster', 'local'))
);

CREATE TABLE template_pinned_releases (
    name                 TEXT NOT NULL,
    content_hash         TEXT NOT NULL,
    release_id           TEXT NOT NULL,
    release_created_at   TEXT NOT NULL,
    updated_at           TEXT NOT NULL,
    PRIMARY KEY (name, content_hash)
);

CREATE TABLE template_pinned_tags (
    name          TEXT NOT NULL,
    tag           TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    PRIMARY KEY (name, tag)
);

CREATE TABLE template_settings (
    template                              TEXT PRIMARY KEY,
    default_auto_lifecycle_json           TEXT NOT NULL,
    default_network_policy_json           TEXT,
    default_network_policy_generation     INTEGER NOT NULL DEFAULT 0,
    ensure_base_snapshot                  INTEGER NOT NULL DEFAULT 0,
    snapshot_vcpu                         INTEGER NOT NULL DEFAULT 2,
    snapshot_memory_mib                   INTEGER NOT NULL DEFAULT 1024,
    base_snapshot_policy_set_at           TEXT,
    last_snapshot_reconcile_started_at    TEXT,
    last_snapshot_reconcile_completed_at  TEXT,
    last_snapshot_reconcile_error         TEXT,
    created_at                            TEXT NOT NULL,
    updated_at                            TEXT NOT NULL,
    default_network_policy_authority TEXT NOT NULL DEFAULT 'cluster'
        CHECK (default_network_policy_authority IN ('cluster', 'local')),
    default_auto_lifecycle_authority TEXT NOT NULL DEFAULT 'cluster'
        CHECK (default_auto_lifecycle_authority IN ('cluster', 'local'))
);

CREATE TABLE template_snapshots (
    name           TEXT NOT NULL,
    content_hash   TEXT NOT NULL,
    vcpu           INTEGER NOT NULL,
    memory_mib     INTEGER NOT NULL,
    snapshot_hash  TEXT NOT NULL,
    built_at       TEXT NOT NULL,
    PRIMARY KEY (name, content_hash, vcpu, memory_mib),
    FOREIGN KEY (name, content_hash) REFERENCES template_builds(name, content_hash)
);

CREATE INDEX idx_template_build_components_lookup
    ON template_build_components(kind, version, role_key);

CREATE INDEX idx_template_builds_execution
    ON template_builds(runtime, runtime_version, guest_os, arch);

CREATE TRIGGER template_local_notification_insert
AFTER INSERT ON template_network_policy_notifications
WHEN NEW.authority = 'local' AND EXISTS (
    SELECT 1 FROM template_settings WHERE template = NEW.template
      AND default_network_policy_authority = 'local'
      AND default_network_policy_json IS NOT NULL
      AND (default_network_policy_json IS NOT NEW.policy_json
           OR default_network_policy_generation IS NOT NEW.generation)
)
BEGIN
    UPDATE template_network_policy_notifications
    SET (policy_json, generation) = (
        SELECT default_network_policy_json, default_network_policy_generation
        FROM template_settings WHERE template = NEW.template
    ) WHERE template = NEW.template;
END;

CREATE TRIGGER template_local_notification_update
AFTER UPDATE OF policy_json, generation, authority ON template_network_policy_notifications
WHEN NEW.authority = 'local' AND EXISTS (
    SELECT 1 FROM template_settings WHERE template = NEW.template
      AND default_network_policy_authority = 'local'
      AND default_network_policy_json IS NOT NULL
      AND (default_network_policy_json IS NOT NEW.policy_json
           OR default_network_policy_generation IS NOT NEW.generation)
)
BEGIN
    UPDATE template_network_policy_notifications
    SET (policy_json, generation) = (
        SELECT default_network_policy_json, default_network_policy_generation
        FROM template_settings WHERE template = NEW.template
    ) WHERE template = NEW.template;
END;

CREATE TRIGGER template_local_policy_generation_insert
AFTER INSERT ON template_settings
WHEN NEW.default_network_policy_authority = 'local'
BEGIN
    UPDATE template_local_policy_sequence SET generation = generation + 1 WHERE singleton = 1;
    UPDATE template_settings SET default_network_policy_generation = (
        SELECT generation FROM template_local_policy_sequence WHERE singleton = 1
    ) WHERE template = NEW.template;
END;

CREATE TRIGGER template_local_policy_generation_update
AFTER UPDATE OF default_network_policy_json, default_network_policy_authority ON template_settings
WHEN NEW.default_network_policy_authority = 'local'
  AND (OLD.default_network_policy_json IS NOT NEW.default_network_policy_json
       OR OLD.default_network_policy_authority IS NOT NEW.default_network_policy_authority)
BEGIN
    UPDATE template_local_policy_sequence SET generation = generation + 1 WHERE singleton = 1;
    -- Generation-only derived writes do not recurse, even with recursive_triggers.
    UPDATE template_settings SET default_network_policy_generation = (
        SELECT generation FROM template_local_policy_sequence WHERE singleton = 1
    ) WHERE template = NEW.template;
END;

CREATE TRIGGER template_policy_notification_delete
AFTER DELETE ON template_settings
BEGIN
    DELETE FROM template_network_policy_notifications WHERE template = OLD.template;
END;

INSERT INTO template_local_policy_sequence (singleton, generation) VALUES (1, 1);
