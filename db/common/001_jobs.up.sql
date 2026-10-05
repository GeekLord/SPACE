CREATE TABLE IF NOT EXISTS jobs (
    job_id          TEXT PRIMARY KEY,
    kind            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending', 'running', 'completed', 'failed')),
    payload         TEXT NOT NULL DEFAULT '',
    subject_id      TEXT,
    dedup_key       TEXT,
    error_kind      TEXT CHECK(error_kind IN ('permanent', 'retriable')),
    attempts        INTEGER NOT NULL DEFAULT 0,
    max_attempts    INTEGER NOT NULL DEFAULT 5,
    bytes_processed INTEGER NOT NULL DEFAULT 0,
    error           TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    started_at      TEXT,
    completed_at    TEXT,
    next_attempt_at TEXT,
    traceparent     TEXT
);

CREATE INDEX IF NOT EXISTS idx_jobs_pending
    ON jobs(next_attempt_at)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_jobs_subject
    ON jobs(subject_id);
