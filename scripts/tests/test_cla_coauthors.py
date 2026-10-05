"""Synthetic metadata regressions for the CLA coauthor coverage guard."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


PATH = Path(__file__).resolve().parents[2] / "ci/scripts/check-cla-coauthors.py"
SPEC = importlib.util.spec_from_file_location("cla_coauthors", PATH)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
HEAD = "a" * 40


def actor(identity):
    return {"user": {"id": identity} if identity else None}


def connection(nodes, total=None, cursor=None):
    return {
        "nodes": nodes,
        "totalCount": len(nodes) if total is None else total,
        "pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor},
    }


def commit(primary, coauthors=(), oid="b" * 40):
    return {"commit": {
        "id": "commit-" + oid, "oid": oid, "author": actor(primary),
        "authors": connection([actor(primary), *(actor(user) for user in coauthors)]),
    }}


class Metadata:
    def __init__(self, commits):
        self.pages = {None: connection(commits)}
        self.author_pages = {}
        self.final_head = HEAD

    def __call__(self, query, variables):
        if query == guard.AUTHORS_QUERY:
            return self.author_pages[(variables["id"], variables["authorCursor"])]
        if query == guard.HEAD_QUERY:
            return {"repository": {"pullRequest": {"headRefOid": self.final_head}}}
        return {"repository": {"pullRequest": {
            "headRefOid": HEAD, "commits": self.pages[variables["cursor"]],
        }}}


class CoauthorCoverageTests(unittest.TestCase):
    def check(self, metadata, exempt_ids=frozenset()):
        guard.check_coverage(metadata, "example/project", 1, HEAD, exempt_ids)

    def test_coauthor_only_reproduction_is_rejected(self):
        with self.assertRaisesRegex(guard.CoverageError, "Every non-exempt coauthor"):
            self.check(Metadata([commit("signed-primary", ["unsigned-coauthor"])]))

    def test_two_primary_authors_cover_coauthors(self):
        self.check(Metadata([
            commit("user-a", ["user-b"]),
            commit("user-b", oid="c" * 40),
        ]))

    def test_ids_not_names_or_emails_are_used(self):
        first = commit("user-a", ["user-b"])
        first["commit"]["authors"]["nodes"][1]["name"] = "same name"
        second = commit("different-id", oid="c" * 40)
        second["commit"]["author"]["name"] = "same name"
        with self.assertRaisesRegex(guard.CoverageError, "Every non-exempt coauthor"):
            self.check(Metadata([first, second]))

    def test_coauthor_free_unknown_primary_is_allowed(self):
        self.check(Metadata([commit(None)]))

    def test_unknown_coauthor_is_rejected(self):
        with self.assertRaisesRegex(guard.CoverageError, "no recognized"):
            self.check(Metadata([commit("user-a", [None])]))

    def test_repeated_coauthors_are_deduplicated(self):
        self.check(Metadata([
            commit("user-a", ["user-b", "user-b"]),
            commit("user-b", ["user-a"], oid="c" * 40),
        ]))

    def test_all_commit_pages_are_checked(self):
        metadata = Metadata([])
        metadata.pages[None] = connection([commit("user-a", ["user-b"])], 2, "next")
        metadata.pages["next"] = connection([commit("user-b", oid="c" * 40)], 2)
        self.check(metadata)

    def test_coauthor_on_later_commit_page_is_not_lost(self):
        metadata = Metadata([])
        metadata.pages[None] = connection([commit("user-a")], 2, "next")
        metadata.pages["next"] = connection([commit("user-b", ["user-c"], "c" * 40)], 2)
        with self.assertRaisesRegex(guard.CoverageError, "Every non-exempt coauthor"):
            self.check(metadata)

    def test_all_author_pages_are_checked(self):
        first = commit("user-a")
        first["commit"]["authors"] = connection([actor("user-a")], 2, "more-authors")
        metadata = Metadata([first, commit("user-b", oid="c" * 40)])
        node = copy.deepcopy(first["commit"])
        node["authors"] = connection([actor("user-b")], 2)
        metadata.author_pages[(node["id"], "more-authors")] = {"node": node}
        self.check(metadata)
        node["authors"] = connection([actor("uncovered")], 2)
        with self.assertRaisesRegex(guard.CoverageError, "Every non-exempt coauthor"):
            self.check(metadata)

    def test_explicitly_exempt_coauthor_needs_no_primary_commit(self):
        self.check(Metadata([commit("new-primary", ["existing-member"])]), {"existing-member"})

    def test_exemption_does_not_cover_other_contributors(self):
        metadata = Metadata([commit("existing-member", ["external-coauthor"])])
        with self.assertRaisesRegex(guard.CoverageError, "Every non-exempt"):
            self.check(metadata, {"existing-member"})
        metadata = Metadata([
            commit("new-primary", ["existing-member", "external-coauthor"]),
            commit("external-coauthor", oid="c" * 40),
        ])
        self.check(metadata, {"existing-member"})

    def test_exemption_never_resolves_an_unknown_coauthor(self):
        with self.assertRaisesRegex(guard.CoverageError, "no recognized"):
            self.check(Metadata([commit("existing-member", [None])]), {"existing-member"})

    def test_nonlisted_primary_author_is_not_required_to_be_exempt(self):
        self.check(Metadata([commit("new-primary")]), {"existing-member"})

    def test_exemptions_use_ids_not_login_labels(self):
        data = {
            "reviewed_at_revision": HEAD,
            "contributors": [{"login": "existing-member", "github_user_id": "approved-ID"}],
        }
        exemptions = guard.parse_exemptions(json.dumps(data))
        self.assertEqual(exemptions, {"approved-ID"})
        with self.assertRaisesRegex(guard.CoverageError, "Every non-exempt"):
            self.check(Metadata([commit("primary", ["existing-member"])]), exemptions)

    def test_checked_in_exemption_record_has_valid_schema(self):
        path = PATH.parents[1] / "cla-exempt-contributors.json"
        self.assertIsInstance(guard.parse_exemptions(path.read_text()), frozenset)

    def test_malformed_exemptions_fail_closed(self):
        valid = {"reviewed_at_revision": HEAD, "contributors": [
            {"login": "example-user", "github_user_id": "stable-ID"},
        ]}
        cases = [
            "{",
            '{"reviewed_at_revision":"' + HEAD + '","contributors":[],"contributors":[]}',
            json.dumps({**valid, "organizations": ["example"]}),
            json.dumps({**valid, "reviewed_at_revision": "main"}),
            json.dumps({**valid, "contributors": [{"login": "*", "github_user_id": "stable-ID"}]}),
            json.dumps({**valid, "contributors": [{"login": "example-user", "github_user_id": "*"}]}),
            json.dumps({**valid, "contributors": valid["contributors"] * 2}),
            json.dumps({**valid, "contributors": [{"login": "example-user"}]}),
        ]
        for content in cases:
            with self.subTest(content=content):
                with self.assertRaises(guard.CoverageError):
                    guard.parse_exemptions(content)

    def test_unreadable_base_is_not_treated_as_no_exemptions(self):
        with patch.object(guard.subprocess, "run", side_effect=OSError):
            with self.assertRaises(guard.CoverageError):
                guard.load_base_exemptions(Path("missing-checkout"), HEAD)

    def test_only_verified_base_blob_can_supply_exemptions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.run(
                    ["git", "-C", directory, "-c", "user.name=Example Contributor",
                     "-c", "user.email=contributor@example.invalid", *args],
                    check=True, text=True, capture_output=True,
                ).stdout.strip()

            git("init", "-q")
            git("commit", "-q", "--allow-empty", "-m", "Synthetic base")
            missing_file_base = git("rev-parse", "HEAD")
            self.assertEqual(guard.load_base_exemptions(root, missing_file_base), set())

            path = root / "ci/cla-exempt-contributors.json"
            path.parent.mkdir()
            approved = {"reviewed_at_revision": HEAD, "contributors": [
                {"login": "approved-user", "github_user_id": "approved-ID"},
            ]}
            path.write_text(json.dumps(approved))
            self.assertEqual(guard.load_base_exemptions(root, missing_file_base), set())
            git("add", ".")
            git("commit", "-q", "-m", "Synthetic approved exemptions")
            approved_base = git("rev-parse", "HEAD")

            # A candidate/working-tree edit cannot grant its own exemption.
            approved["contributors"].append({"login": "new-user", "github_user_id": "new-ID"})
            path.write_text(json.dumps(approved))
            self.assertEqual(guard.load_base_exemptions(root, approved_base), {"approved-ID"})
            with self.assertRaisesRegex(guard.CoverageError, "does not match"):
                guard.load_base_exemptions(root, missing_file_base)

            path.write_text("malformed")
            git("add", ".")
            git("commit", "-q", "-m", "Synthetic invalid exemptions")
            with self.assertRaises(guard.CoverageError):
                guard.load_base_exemptions(root, git("rev-parse", "HEAD"))

    def test_truncated_or_missing_author_metadata_is_rejected(self):
        for authors in (connection([actor("user-a")], 2), connection([]), {}):
            with self.subTest(authors=authors):
                first = commit("user-a")
                first["commit"]["authors"] = authors
                with self.assertRaises((guard.CoverageError, KeyError)):
                    self.check(Metadata([first]))

    def test_missing_user_field_is_not_an_unknown_primary(self):
        first = commit("user-a")
        del first["commit"]["author"]["user"]
        with self.assertRaises(KeyError):
            self.check(Metadata([first]))

    def test_truncated_commits_and_repeated_cursor_are_rejected(self):
        metadata = Metadata([commit("user-a")])
        metadata.pages[None]["totalCount"] = 2
        with self.assertRaisesRegex(guard.CoverageError, "truncated"):
            self.check(metadata)
        metadata.pages = {
            None: connection([], 1, "same"),
            "same": connection([], 1, "same"),
        }
        with self.assertRaisesRegex(guard.CoverageError, "did not advance"):
            self.check(metadata)

    def test_head_race_is_rejected(self):
        metadata = Metadata([commit("user-a")])
        metadata.final_head = "f" * 40
        with self.assertRaisesRegex(guard.CoverageError, "head changed"):
            self.check(metadata)

    def test_duplicate_commit_and_inconsistent_primary_are_rejected(self):
        with self.assertRaisesRegex(guard.CoverageError, "Duplicate"):
            self.check(Metadata([commit("user-a"), commit("user-a")]))
        first = commit("user-a")
        first["commit"]["authors"]["nodes"][0] = actor("user-b")
        with self.assertRaisesRegex(guard.CoverageError, "disagrees"):
            self.check(Metadata([first]))

    def test_api_errors_and_partial_data_fail_closed_without_raw_output(self):
        for response in (
            subprocess.CompletedProcess([], 1, "", "private transport detail"),
            subprocess.CompletedProcess([], 0, '{"errors":[{"message":"detail"}],"data":{}}', ""),
            subprocess.CompletedProcess([], 0, "not json", ""),
            subprocess.CompletedProcess([], 0, '{"data":null}', ""),
        ):
            with self.subTest(response=response), patch.object(guard.subprocess, "run", return_value=response):
                with self.assertRaises(guard.CoverageError) as error:
                    guard.graphql("query", {})
                self.assertNotIn("detail", str(error.exception))


if __name__ == "__main__":
    unittest.main()
