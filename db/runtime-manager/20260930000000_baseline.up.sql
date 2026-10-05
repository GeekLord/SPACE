-- The shared `jobs` table (db/common) holds each kernel operation's request
-- and lifecycle. This store adds what is the runtime manager's own.

-- One row per kernel the runtime manager installed. These rows are what make
-- a kernel space-managed; nothing else does.
CREATE TABLE kernel_installs (
    kernel_version TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    -- The runtime line the kernel was installed for: `firecracker`, `1.15`.
    runtime TEXT NOT NULL,
    runtime_line TEXT NOT NULL,
    source TEXT NOT NULL,
    size INTEGER NOT NULL,
    source_md5 TEXT NOT NULL,
    digest TEXT NOT NULL,
    -- The job that installed it; NULL for a kernel seeded from the node
    -- image's manifest.
    job_id TEXT,
    installed_at_unix_ms INTEGER NOT NULL
);

-- What a kernel job did on disk: either the step it is part-way through
-- (`phase`, set while it publishes or removes a kernel directory, so a job
-- re-run after a restart can tell whether its rename landed) or its outcome.
CREATE TABLE kernel_job_results (
    job_id TEXT PRIMARY KEY,
    phase TEXT,
    outcome TEXT,
    path TEXT NOT NULL,
    digest TEXT NOT NULL,
    updated_at_unix_ms INTEGER NOT NULL,
    CHECK ((phase IS NULL) <> (outcome IS NULL))
);
