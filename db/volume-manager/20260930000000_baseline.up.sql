CREATE TABLE volume_attachments (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    sandbox_id  TEXT NOT NULL,
    name        TEXT NOT NULL,
    s3_bucket   TEXT NOT NULL,
    s3_prefix   TEXT NOT NULL DEFAULT '',
    s3_region   TEXT NOT NULL,
    read_only   INTEGER NOT NULL DEFAULT 1,
    byok_key_id TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(sandbox_id, name)
);
