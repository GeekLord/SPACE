CREATE UNIQUE INDEX CONCURRENTLY idx_widgets_id ON widgets (id);
DELETE FROM widgets WHERE deleted_at IS NOT NULL;
