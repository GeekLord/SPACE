CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_unique
    ON public.widgets USING btree (org_id, id DESC)
    INCLUDE (status)
    WITH (fillfactor = 80)
    TABLESPACE pg_default
    WHERE (deleted_at IS NULL);
