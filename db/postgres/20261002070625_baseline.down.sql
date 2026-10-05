-- The initial schema is a rollback floor; reset is separately destructive and gated.
DO $$
BEGIN
    RAISE EXCEPTION 'The initial schema cannot be rolled back; use an explicitly confirmed reset or restore a backup';
END
$$;
