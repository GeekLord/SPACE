CREATE INDEX IF NOT EXISTS idx_jobs_dedup_latest
    ON jobs(kind, dedup_key, created_at DESC, job_id DESC)
    WHERE dedup_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_jobs_created_at
    ON jobs(created_at DESC, job_id DESC);

CREATE INDEX IF NOT EXISTS idx_jobs_status_created_at
    ON jobs(status, created_at DESC, job_id DESC);

CREATE INDEX IF NOT EXISTS idx_jobs_terminal_completed_at
    ON jobs(status, completed_at)
    WHERE status IN ('completed', 'failed') AND completed_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_jobs_subject_created_at
    ON jobs(subject_id, created_at DESC, job_id DESC)
    WHERE subject_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_jobs_active_kind_status
    ON jobs(kind, status)
    WHERE status IN ('pending', 'running');
