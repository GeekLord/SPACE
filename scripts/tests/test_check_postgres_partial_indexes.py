#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parents[1]
FIXTURES_DIR = Path(__file__).parent / "fixtures" / "postgres-partial-index"
EXPECTED_ALLOW_FIXTURES = {
    "comments-and-strings.sql",
    "noop.sql",
    "ordinary-index-and-dml-where.sql",
    "simple-alter.sql",
}
EXPECTED_DENY_RESULTS = {
    "basic-partial-index.sql": ["idx_basic"],
    "compact-partial-index-no-semicolon.sql": ["idx_compact"],
    "multiline-unique-partial-index.sql": ["idx_unique"],
}
sys.path.insert(0, str(SCRIPTS_DIR))

import check_postgres_partial_indexes as checker


class PartialIndexCheckerTests(unittest.TestCase):
    def test_allows_named_sql_fixtures(self) -> None:
        paths = sorted((FIXTURES_DIR / "allow").glob("*.sql"))
        self.assertEqual({path.name for path in paths}, EXPECTED_ALLOW_FIXTURES)
        for path in paths:
            with self.subTest(fixture=path.name):
                self.assertEqual(checker.partial_index_names(path.read_text()), [])

    def test_rejects_named_sql_fixtures(self) -> None:
        self.assertEqual(
            {path.name for path in (FIXTURES_DIR / "deny").glob("*.sql")},
            EXPECTED_DENY_RESULTS.keys(),
        )
        for name, expected in EXPECTED_DENY_RESULTS.items():
            with self.subTest(fixture=name):
                sql = (FIXTURES_DIR / "deny" / name).read_text()
                self.assertEqual(checker.partial_index_names(sql), expected)


if __name__ == "__main__":
    unittest.main()
