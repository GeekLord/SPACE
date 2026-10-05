#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


reclaim = load_module(
    "reclaim_backed_btrfs_send_streams_under_test",
    REPO_ROOT / "scripts/disk-usage/reclaim-backed-btrfs-send-streams.py",
)


class ReclaimBackedBtrfsSendStreamsTests(unittest.TestCase):
    def make_db(self) -> str:
        tmp = tempfile.NamedTemporaryFile(prefix="sbx-reclaim-test-", suffix=".db", delete=False)
        tmp.close()
        conn = sqlite3.connect(tmp.name)
        conn.executescript(
            """
            CREATE TABLE sandboxes (
                id TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                current_local_artifact_id TEXT
            );
            CREATE TABLE local_artifacts (
                local_artifact_id TEXT PRIMARY KEY,
                sandbox_id TEXT NOT NULL,
                artifact_origin TEXT NOT NULL,
                artifact_kind TEXT NOT NULL,
                state TEXT NOT NULL,
                backup_completed_at TEXT,
                local_path TEXT NOT NULL
            );
            CREATE TABLE jobs (
                kind TEXT NOT NULL,
                subject_id TEXT,
                status TEXT NOT NULL
            );
            """
        )
        conn.commit()
        conn.close()
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        return tmp.name

    def insert_candidate(
        self,
        db_path: str,
        sandbox_id: str,
        artifact_id: str,
        updated_at: int,
        *,
        job_status: str | None = None,
    ) -> None:
        conn = sqlite3.connect(db_path)
        conn.execute(
            """
            INSERT INTO sandboxes (
                id, state, updated_at, current_local_artifact_id
            ) VALUES (?, 'suspended', ?, ?)
            """,
            (sandbox_id, str(updated_at), artifact_id),
        )
        conn.execute(
            """
            INSERT INTO local_artifacts (
                local_artifact_id, sandbox_id, artifact_origin, artifact_kind,
                state, backup_completed_at, local_path
            ) VALUES (?, ?, 'suspend', 'full', 'ready', '1700000000', ?)
            """,
            (artifact_id, sandbox_id, f"/space/cache/{sandbox_id}/snapshot"),
        )
        if job_status is not None:
            conn.execute(
                "INSERT INTO jobs (kind, subject_id, status) VALUES ('snapshot_upload', ?, ?)",
                (sandbox_id, job_status),
            )
        conn.commit()
        conn.close()

    def test_candidates_from_db_applies_quiet_age_and_upload_gates(self) -> None:
        db_path = self.make_db()
        self.insert_candidate(db_path, "old", "artifact-old", 900)
        self.insert_candidate(db_path, "recent", "artifact-recent", 1_500)
        self.insert_candidate(db_path, "uploading", "artifact-uploading", 800, job_status="running")

        candidates = reclaim.candidates_from_db(db_path, now_secs=2_000, min_age_secs=1_000)

        self.assertEqual(
            candidates,
            [
                reclaim.ReclaimCandidate(
                    "old", "artifact-old", "/space/cache/old/snapshot/rootfs.btrfs-send"
                )
            ],
        )

    def test_parse_stream_stat_line_keeps_paths_with_spaces(self) -> None:
        parsed = reclaim.parse_stream_stat_line("1024 1710000000 99 /space/cache/sbx/snapshot file")

        self.assertEqual(
            parsed,
            (
                "/space/cache/sbx/snapshot file",
                reclaim.StreamIdentity(size=1024, mtime=1_710_000_000, inode=99),
            ),
        )

    def test_apply_pod_skips_when_db_recheck_drops_candidate(self) -> None:
        plan = reclaim.ReclaimPlan(
            "sbx",
            "artifact",
            "/space/cache/sbx/snapshot/rootfs.btrfs-send",
            reclaim.StreamIdentity(size=123, mtime=456, inode=789),
        )
        with mock.patch.object(reclaim, "snapshot_db", return_value="/tmp/db"), mock.patch.object(
            reclaim, "candidates_from_db", return_value=[]
        ), mock.patch.object(reclaim, "guarded_delete_stream") as delete:
            self.assertEqual(
                reclaim.apply_pod(
                    "ctx", "space", "sandbox-manager", "pod", [plan], 60, 3600, now_secs=2_000
                ),
                (0, 0, 1),
            )
            delete.assert_not_called()

    def test_apply_pod_skips_identity_mismatch(self) -> None:
        plan = reclaim.ReclaimPlan(
            "sbx",
            "artifact",
            "/space/cache/sbx/snapshot/rootfs.btrfs-send",
            reclaim.StreamIdentity(size=123, mtime=456, inode=789),
        )
        candidate = reclaim.ReclaimCandidate("sbx", "artifact", plan.path)
        with mock.patch.object(reclaim, "snapshot_db", return_value="/tmp/db"), mock.patch.object(
            reclaim, "candidates_from_db", return_value=[candidate]
        ), mock.patch.object(reclaim, "guarded_delete_stream", return_value=False):
            self.assertEqual(
                reclaim.apply_pod(
                    "ctx", "space", "sandbox-manager", "pod", [plan], 60, 3600, now_secs=2_000
                ),
                (0, 0, 1),
            )

    def test_apply_pod_counts_only_successful_guarded_deletes(self) -> None:
        plan = reclaim.ReclaimPlan(
            "sbx",
            "artifact",
            "/space/cache/sbx/snapshot/rootfs.btrfs-send",
            reclaim.StreamIdentity(size=123, mtime=456, inode=789),
        )
        candidate = reclaim.ReclaimCandidate("sbx", "artifact", plan.path)
        with mock.patch.object(reclaim, "snapshot_db", return_value="/tmp/db"), mock.patch.object(
            reclaim, "candidates_from_db", return_value=[candidate]
        ), mock.patch.object(reclaim, "guarded_delete_stream", return_value=True):
            self.assertEqual(
                reclaim.apply_pod(
                    "ctx", "space", "sandbox-manager", "pod", [plan], 60, 3600, now_secs=2_000
                ),
                (1, 123, 0),
            )


if __name__ == "__main__":
    unittest.main()
