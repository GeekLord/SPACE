#!/usr/bin/env python3
"""Prepare a separate SQLite database for the public migration baseline."""

from contextlib import closing
import argparse
import hashlib
import os
import re
from pathlib import Path
import sqlite3
import tempfile
import tomllib


HISTORY = "_sqlx_migrations"
COMMON_HISTORY = "_space_common_schema_migrations"
METADATA = {HISTORY, COMMON_HISTORY, "goose_db_version", "schema_migrations", "_schema_version"}
STORES = ("node-manager", "node-ctl", "sandbox-manager", "template-manager", "volume-manager", "build-manager", "runtime-manager")
COMMON_STORES = set(STORES[2:])
BASELINE = 20260930000000


def migrations(directory):
    files = list(directory.glob("*.up.sql"))
    paths = {int(path.name.split("_", 1)[0]): path for path in files}
    if not paths or len(paths) != len(files):
        raise ValueError(f"missing or duplicate historical migrations in {directory}")
    return paths


def schema(conn):
    objects = []
    for kind, name, table, sql in conn.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_schema "
        "WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL ORDER BY type, name"
    ):
        if name not in METADATA:
            # Ignore formatting outside literals and quoted identifiers only.
            tokens = re.findall(r"'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|`[^`]*`|\[[^]]*\]|--[^\n]*|/\*.*?\*/|\w+|[^\s]", sql, re.S)
            tokens = [token for token in tokens if not token.startswith(("--", "/*"))]
            objects.append((kind, name, table, tokens))
    return objects


def validate_history(conn, table, paths, store, accepted):
    rows = conn.execute(f'SELECT version, success, checksum FROM "{table}"').fetchall()
    if {row[0] for row in rows} != set(paths):
        raise ValueError(f"{store}: incomplete or unexpected migration history")
    for version, success, checksum in rows:
        bundled = hashlib.sha384(paths[version].read_bytes()).digest()
        alternatives = accepted.get((store, version), set())
        if success != 1 or not (
            checksum == bundled or {checksum.hex(), bundled.hex()} <= alternatives
        ):
            raise ValueError(f"{store}: failed or changed migration {version}")


def replace_history(conn, table, path):
    conn.execute(f'DELETE FROM "{table}"')
    conn.execute(
        f'INSERT INTO "{table}" (version, description, success, checksum, execution_time) '
        "VALUES (?, 'baseline', 1, ?, 0)",
        (BASELINE, hashlib.sha384(path.read_bytes()).digest()),
    )


def prepare(args):
    source = args.source.resolve(strict=True)
    output = args.output.absolute()
    if output.exists():
        raise ValueError("output already exists; refusing to overwrite it")
    current = Path(__file__).resolve().parents[1] / "db"
    service_baseline = current / args.store / f"{BASELINE}_baseline.up.sql"
    common_baseline = current / "common" / f"{BASELINE}_baseline.up.sql"
    common_paths = migrations(current / "common") if args.store in COMMON_STORES else {}
    service_paths = migrations(args.legacy_db_dir / args.store)
    service_is_public = min(service_paths) >= BASELINE
    accepted = {}
    manifest = args.legacy_db_dir / "accepted-checksums.toml"
    for entry in tomllib.loads(manifest.read_text())["migrations"]:
        accepted[(entry["store"], entry["version"])] = set(entry["accepted_checksums"])

    # Publish only a fully checked copy; the original is also the rollback copy.
    with tempfile.TemporaryDirectory(prefix="sqlite-cutover-", dir=output.parent) as directory:
        candidate = Path(directory) / "database.sqlite"
        with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as original:
            with closing(sqlite3.connect(candidate)) as conn:
                original.backup(conn)
                os.chmod(candidate, 0o600)
                validate_history(conn, HISTORY, service_paths, args.store, accepted)
                if args.store in COMMON_STORES:
                    validate_history(conn, COMMON_HISTORY, migrations(args.legacy_db_dir / "common"), "common", accepted)
                if conn.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                    raise ValueError("database integrity check failed")
                if conn.execute("PRAGMA foreign_key_check").fetchall():
                    raise ValueError("database has foreign-key violations")
                if args.store == "sandbox-manager" and conn.execute(
                    "SELECT 1 FROM jobs WHERE kind = 'snapshot_upload' "
                    "AND status IN ('pending', 'running') "
                    "AND CASE WHEN json_valid(payload) "
                    "THEN json_type(payload, '$.includes_metadata_job') IS NOT 'true' "
                    "ELSE 1 END LIMIT 1"
                ).fetchone():
                    raise ValueError("active snapshot uploads lack staged metadata; finish or repair them with the preparation release before cutover")
                with closing(sqlite3.connect(":memory:")) as reference:
                    if args.store in COMMON_STORES:
                        for _, path in sorted(common_paths.items()):
                            reference.executescript(path.read_text())
                    reference_paths = service_paths if service_is_public else {BASELINE: service_baseline}
                    for _, path in sorted(reference_paths.items()):
                        reference.executescript(path.read_text())
                    if schema(conn) != schema(reference):
                        raise ValueError("schema differs from the public baseline; reconcile drift before cutover")
                    if conn.execute("PRAGMA user_version").fetchone() != reference.execute("PRAGMA user_version").fetchone():
                        raise ValueError("SQLite schema admission version differs from the baseline")
                with conn:
                    if not service_is_public:
                        replace_history(conn, HISTORY, service_baseline)
                    if common_baseline.is_file() and args.store in COMMON_STORES:
                        replace_history(conn, COMMON_HISTORY, common_baseline)
                conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                conn.execute("PRAGMA journal_mode=DELETE")
        # A hard link publishes atomically without replacing a concurrently created file.
        os.link(candidate, output)
    print(f"Prepared {output}; source retained unchanged. Keep the owning daemon stopped during installation.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", required=True, choices=STORES)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--legacy-db-dir", required=True, type=Path)
    prepare(parser.parse_args())


if __name__ == "__main__":
    main()
