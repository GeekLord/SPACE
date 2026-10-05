#!/usr/bin/env python3
"""Require non-exempt coauthors to be primary commit authors in the same PR.

This checks contributor coverage, not CLA signatures. It reads GitHub metadata
only; it does not check out or execute pull-request code.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


AUTHORS = """
authors(first: 100, after: $authorCursor) {
  totalCount
  nodes { user { id } }
  pageInfo { hasNextPage endCursor }
}
"""
PR_QUERY = """
query($owner: String!, $repo: String!, $number: Int!, $cursor: String,
      $authorCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      headRefOid
      commits(first: 100, after: $cursor) {
        totalCount
        nodes { commit { id oid author { user { id } } """ + AUTHORS + """ } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"""
AUTHORS_QUERY = """
query($id: ID!, $authorCursor: String) {
  node(id: $id) { ... on Commit { id oid """ + AUTHORS + """ } }
}
"""
HEAD_QUERY = """
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) { headRefOid }
  }
}
"""


class CoverageError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CoverageError(message)


def parse_exemptions(content):
    """Load only explicitly reviewed account IDs; never infer membership/history."""
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate exemption-file key")
            result[key] = value
        return result

    try:
        data = json.loads(content, object_pairs_hook=unique_keys)
        require(set(data) == {"reviewed_at_revision", "contributors"}, "Invalid exemption-file fields")
        require(
            isinstance(data["reviewed_at_revision"], str)
            and re.fullmatch(r"[0-9a-f]{40}", data["reviewed_at_revision"]),
            "Invalid exemption inventory revision",
        )
        require(isinstance(data["contributors"], list), "Invalid exempt contributor list")
        identities, logins = set(), set()
        for contributor in data["contributors"]:
            require(set(contributor) == {"login", "github_user_id"}, "Invalid exemption entry")
            login, identity = contributor["login"], contributor["github_user_id"]
            require(
                isinstance(login, str)
                and re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", login)
                and "--" not in login,
                "Exemptions require explicit GitHub logins, not patterns or organizations",
            )
            require(
                isinstance(identity, str) and re.fullmatch(r"[A-Za-z0-9_+/=-]+", identity),
                "Exemptions require explicit GitHub user IDs",
            )
            require(identity not in identities and login.lower() not in logins, "Duplicate exemption")
            identities.add(identity)
            logins.add(login.lower())
        return frozenset(identities)
    except (ValueError, TypeError, KeyError) as error:
        raise CoverageError("Could not parse the contributor exemption file") from error


def load_base_exemptions(checkout, expected_base):
    """Read a tracked blob at the trusted event base, never PR-supplied data."""
    def git(*args):
        try:
            result = subprocess.run(
                ["git", "-C", str(checkout), *args],
                text=True, capture_output=True, timeout=30, check=False,
            )
            require(result.returncode == 0, "Could not read the trusted base checkout")
            return result.stdout
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CoverageError("Could not read the trusted base checkout") from error

    require(
        git("rev-parse", "--verify", "HEAD^{commit}").strip() == expected_base,
        "Exemption checkout does not match the trusted base revision",
    )
    entry = git("ls-tree", "--full-tree", "-z", expected_base, "--", "ci/cla-exempt-contributors.json")
    if not entry:
        # Bootstrap: absence in a successfully read, verified base tree means
        # no exemptions. A request/git failure must never take this branch.
        return frozenset()
    match = re.fullmatch(
        r"100(?:644|755) blob ([0-9a-f]{40})\tci/cla-exempt-contributors\.json\x00",
        entry,
    )
    require(match is not None, "Exemption file must be a regular tracked file")
    return parse_exemptions(git("cat-file", "blob", match.group(1)))


def graphql(query, variables):
    """Use only the runner's read-only GitHub token; never print API payloads."""
    try:
        result = subprocess.run(
            ["gh", "api", "graphql", "--input", "-"],
            input=json.dumps({"query": query, "variables": variables}),
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        require(result.returncode == 0, "GitHub metadata request failed")
        response = json.loads(result.stdout)
        require(not response.get("errors"), "GitHub returned metadata errors")
        require(isinstance(response.get("data"), dict), "Missing GitHub metadata")
        return response["data"]
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        raise CoverageError("Could not read GitHub metadata") from error


def collect_pages(first, next_page):
    """Reject partial connections, inconsistent counts and non-advancing cursors."""
    nodes, cursors = [], set()
    total = first["totalCount"]
    require(type(total) is int and total >= 0, "Invalid metadata count")
    page = first
    while True:
        require(page["totalCount"] == total, "Metadata count changed during check")
        require(isinstance(page["nodes"], list), "Missing metadata nodes")
        nodes.extend(page["nodes"])
        require(len(nodes) <= total, "Metadata count does not match nodes")
        info = page["pageInfo"]
        require(type(info["hasNextPage"]) is bool, "Missing pagination state")
        if not info["hasNextPage"]:
            require(len(nodes) == total, "GitHub metadata was truncated")
            return nodes
        cursor = info["endCursor"]
        require(
            isinstance(cursor, str) and cursor and cursor not in cursors,
            "GitHub pagination did not advance",
        )
        cursors.add(cursor)
        page = next_page(cursor)


def actor_id(actor):
    # An unknown primary author on a coauthor-free commit remains allowed.
    if actor is None:
        return None
    user = actor["user"]
    if user is None:
        return None
    identity = user["id"]
    require(isinstance(identity, str) and identity, "Missing GitHub user ID")
    return identity


def check_coverage(fetch, repository, number, expected_head, exempt_ids=frozenset()):
    owner, repo = repository.split("/")
    variables = {"owner": owner, "repo": repo, "number": number}

    def pull_request(query, extra=None):
        data = fetch(query, {**variables, **(extra or {})})
        pr = data["repository"]["pullRequest"]
        require(pr["headRefOid"] == expected_head, "PR head changed; rerun this check")
        return pr

    def commit_page(cursor):
        return pull_request(PR_QUERY, {"cursor": cursor, "authorCursor": None})["commits"]

    commits = collect_pages(commit_page(None), commit_page)
    require(commits, "No PR commits returned")
    primary_ids, coauthor_ids, commit_ids = set(), set(), set()
    for edge in commits:
        commit = edge["commit"]
        identity, oid = commit["id"], commit["oid"]
        require(
            isinstance(identity, str) and identity
            and isinstance(oid, str) and re.fullmatch(r"[0-9a-f]{40}", oid),
            "Invalid commit identity",
        )
        require(oid not in commit_ids, "Duplicate commit in metadata")
        commit_ids.add(oid)
        primary = actor_id(commit["author"])
        if primary is not None:
            primary_ids.add(primary)

        def author_page(cursor):
            node = fetch(AUTHORS_QUERY, {"id": identity, "authorCursor": cursor})["node"]
            require(node["id"] == identity and node["oid"] == oid, "Commit identity changed")
            return node["authors"]

        authors = collect_pages(commit["authors"], author_page)
        require(authors, "Missing commit authors")
        # GitHub guarantees that the git author is first in Commit.authors.
        require(actor_id(authors[0]) == primary, "Primary author metadata disagrees")
        for author in authors[1:]:
            coauthor = actor_id(author)
            require(coauthor is not None, "A coauthor has no recognized GitHub account")
            coauthor_ids.add(coauthor)

    pull_request(HEAD_QUERY)
    require(
        coauthor_ids <= primary_ids | exempt_ids,
        "Every non-exempt coauthor must also author a commit in this PR so the hosted CLA "
        "check can cover their account; a coauthor-only trailer is not sufficient",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--head", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--base-checkout", required=True, type=Path)
    args = parser.parse_args()
    try:
        require(re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo), "Invalid repository")
        require(args.pr > 0, "Invalid PR number")
        require(re.fullmatch(r"[0-9a-f]{40}", args.head), "Invalid PR head")
        require(re.fullmatch(r"[0-9a-f]{40}", args.base), "Invalid PR base")
        exempt_ids = load_base_exemptions(args.base_checkout, args.base)
        check_coverage(graphql, args.repo, args.pr, args.head, exempt_ids)
    except (CoverageError, KeyError, TypeError, AttributeError, ValueError) as error:
        message = str(error) if isinstance(error, CoverageError) else "Incomplete GitHub metadata"
        print(f"Coauthor coverage failed: {message}", file=sys.stderr)
        return 1
    print(f"Coauthor coverage passed for PR #{args.pr} at {args.head}; CLA signatures are checked separately.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
