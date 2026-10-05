CREATE TABLE build_job_results (
    job_id       TEXT PRIMARY KEY,
    template_id  TEXT NOT NULL,
    state        TEXT NOT NULL CHECK(state IN ('succeeded', 'failed', 'publish_failed')),
    content_hash TEXT,
    error        TEXT,
    completed_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
);
