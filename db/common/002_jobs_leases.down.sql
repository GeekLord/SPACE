DROP INDEX IF EXISTS idx_jobs_lease_expiry;
ALTER TABLE jobs DROP COLUMN heartbeat_at;
ALTER TABLE jobs DROP COLUMN lease_expires_at;
ALTER TABLE jobs DROP COLUMN lease_owner;
