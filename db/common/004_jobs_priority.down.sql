DROP INDEX IF EXISTS idx_jobs_pending_priority;

ALTER TABLE jobs DROP COLUMN priority;
