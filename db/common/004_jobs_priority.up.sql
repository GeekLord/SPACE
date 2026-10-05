ALTER TABLE jobs ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_jobs_pending_priority
    ON jobs(kind, priority DESC, created_at ASC, job_id ASC)
    WHERE status = 'pending';
