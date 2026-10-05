UPDATE jobs
SET status = 'failed',
    error_kind = 'permanent',
    error = 'job cancellation state downgraded',
    completed_at = COALESCE(completed_at, datetime('now'))
WHERE status IN ('cancelling', 'cancelled');

CREATE TABLE jobs_without_cancellation (
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
    traceparent     TEXT,
    lease_owner     TEXT,
    lease_expires_at TEXT,
    heartbeat_at    TEXT,
    priority        INTEGER NOT NULL DEFAULT 0,
    failure_reason  TEXT
                    CHECK(failure_reason IN (
                        'not_found',
                        'permission_denied',
                        'invalid_input',
                        'internal'
                    ))
                    CHECK(failure_reason IS NULL OR error_kind = 'permanent')
);

INSERT INTO jobs_without_cancellation
SELECT * FROM jobs;

DROP TABLE jobs;
ALTER TABLE jobs_without_cancellation RENAME TO jobs;

CREATE INDEX idx_jobs_pending
    ON jobs(next_attempt_at)
    WHERE status = 'pending';
CREATE INDEX idx_jobs_subject
    ON jobs(subject_id);
CREATE INDEX idx_jobs_lease_expiry
    ON jobs(lease_expires_at)
    WHERE status = 'running' AND lease_expires_at IS NOT NULL;
CREATE INDEX idx_jobs_dedup_latest
    ON jobs(kind, dedup_key, created_at DESC, job_id DESC)
    WHERE dedup_key IS NOT NULL;
CREATE INDEX idx_jobs_created_at
    ON jobs(created_at DESC, job_id DESC);
CREATE INDEX idx_jobs_status_created_at
    ON jobs(status, created_at DESC, job_id DESC);
CREATE INDEX idx_jobs_terminal_completed_at
    ON jobs(status, completed_at)
    WHERE status IN ('completed', 'failed')
      AND completed_at IS NOT NULL;
CREATE INDEX idx_jobs_subject_created_at
    ON jobs(subject_id, created_at DESC, job_id DESC)
    WHERE subject_id IS NOT NULL;
CREATE INDEX idx_jobs_active_kind_status
    ON jobs(kind, status)
    WHERE status IN ('pending', 'running');
CREATE INDEX idx_jobs_pending_priority
    ON jobs(kind, priority DESC, created_at ASC, job_id ASC)
    WHERE status = 'pending';
