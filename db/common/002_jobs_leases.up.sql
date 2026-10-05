ALTER TABLE jobs ADD COLUMN lease_owner TEXT;
ALTER TABLE jobs ADD COLUMN lease_expires_at TEXT;
ALTER TABLE jobs ADD COLUMN heartbeat_at TEXT;

CREATE INDEX IF NOT EXISTS idx_jobs_lease_expiry
    ON jobs(lease_expires_at)
    WHERE status = 'running' AND lease_expires_at IS NOT NULL;
