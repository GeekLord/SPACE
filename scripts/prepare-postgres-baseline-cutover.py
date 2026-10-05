#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate reviewable cutover SQL from an archived, fully applied migration set."""

import argparse
import hashlib
import re
import tomllib
from pathlib import Path


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("legacy", type=Path, help="archived db/postgres directory")
    parser.add_argument("checksums", type=Path, help="archived accepted-checksums.toml")
    parser.add_argument("baseline", type=Path, help="new baseline up migration")
    parser.add_argument("--rollback", action="store_true", help="generate guarded history recovery SQL")
    args = parser.parse_args()

    accepted = {
        entry["version"]: entry["accepted_checksums"]
        for entry in tomllib.loads(args.checksums.read_text())["migrations"]
        if entry["store"] == "postgres"
    }
    expected = {}
    for path in sorted(args.legacy.glob("*.up.sql")):
        version = int(path.name.split("_", 1)[0])
        if version in expected:
            parser.error(f"duplicate legacy migration version: {version}")
        checksum = hashlib.sha384(path.read_bytes()).hexdigest()
        digests = accepted.get(version, [checksum])
        if checksum not in digests or any(not re.fullmatch(r"[0-9a-f]{96}", d) for d in digests):
            parser.error(f"invalid accepted checksums for {path.name}")
        expected[version] = digests

    version, description = args.baseline.name.removesuffix(".up.sql").split("_", 1)
    version = int(version)
    if not expected or version <= max(expected):
        parser.error("baseline must follow a nonempty legacy migration set")
    if len(expected) != 185 or min(expected) != 44 or max(expected) != 20261001180045:
        parser.error(
            "legacy catalog must contain all 185 migrations from 44 through 20261001180045; "
            "upgrade with that catalog and archive its matching revision before cutover"
        )
    checksum = hashlib.sha384(args.baseline.read_bytes()).hexdigest()
    rows = ",\n".join(
        f"    ({v}, ARRAY[{', '.join(literal(d) for d in digests)}])"
        for v, digests in sorted(expected.items())
    )
    if args.rollback:
        print(f"""-- Stop all migration jobs. Recovery is valid only before subsequent migrations.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
LOCK TABLE public._sqlx_migrations IN ACCESS EXCLUSIVE MODE;
LOCK TABLE space_migration_archive.postgres_history IN ACCESS EXCLUSIVE MODE;
CREATE TEMP TABLE expected_migrations (version bigint PRIMARY KEY, checksums text[]) ON COMMIT DROP;
INSERT INTO expected_migrations VALUES
{rows};
DO $$
BEGIN
    IF (SELECT count(*) FROM public._sqlx_migrations) <> 1 OR NOT EXISTS (
        SELECT 1 FROM public._sqlx_migrations
        WHERE version = {version} AND success AND checksum = decode('{checksum}', 'hex')
    ) THEN
        RAISE EXCEPTION 'Recovery requires the baseline alone; restore a backup after later migrations';
    END IF;
    IF (SELECT count(*) FROM space_migration_archive.postgres_history) <> {len(expected)} OR EXISTS (
        SELECT 1 FROM expected_migrations e
        FULL JOIN space_migration_archive.postgres_history a USING (version)
        WHERE e.version IS NULL OR a.version IS NULL OR a.success IS DISTINCT FROM true
            OR (encode(a.checksum, 'hex') = ANY(e.checksums)) IS NOT TRUE
    ) THEN
        RAISE EXCEPTION 'Archived migration history does not match the verified cutoff';
    END IF;
END
$$;
DELETE FROM public._sqlx_migrations;
INSERT INTO public._sqlx_migrations SELECT * FROM space_migration_archive.postgres_history;
COMMIT;
""")
        return

    print(f"""-- Stop all migration jobs and verify schema equivalence before running this file.
-- Run with psql -X -v ON_ERROR_STOP=1. This changes history only, never application data.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
LOCK TABLE public._sqlx_migrations IN ACCESS EXCLUSIVE MODE;

CREATE TEMP TABLE expected_migrations (version bigint PRIMARY KEY, checksums text[]) ON COMMIT DROP;
INSERT INTO expected_migrations VALUES
{rows};

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM expected_migrations e
        FULL JOIN public._sqlx_migrations a USING (version)
        WHERE e.version IS NULL OR a.version IS NULL OR a.success IS DISTINCT FROM true
            OR (encode(a.checksum, 'hex') = ANY(e.checksums)) IS NOT TRUE
    ) THEN
        RAISE EXCEPTION 'Migration history does not exactly match the verified cutoff';
    END IF;
END
$$;

CREATE SCHEMA space_migration_archive;
REVOKE ALL ON SCHEMA space_migration_archive FROM PUBLIC;
CREATE TABLE space_migration_archive.postgres_history AS TABLE public._sqlx_migrations;
REVOKE ALL ON space_migration_archive.postgres_history FROM PUBLIC;
DELETE FROM public._sqlx_migrations;
INSERT INTO public._sqlx_migrations (version, description, success, checksum, execution_time)
VALUES ({version}, {literal(description.replace('_', ' '))}, true, decode('{checksum}', 'hex'), 0);
COMMIT;
""")


if __name__ == "__main__":
    main()
