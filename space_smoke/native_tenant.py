"""Run-owned second-organization credentials for native isolation scenarios."""

from __future__ import annotations

import json
import os
import time
import uuid
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request

from space_smoke.native import _URL_OPEN
from space_smoke.native_hardening import NativeHardeningFixture, _chunks
from space_smoke.runtime import SmokeConfigurationError


def foreign_tenant_token(test: NativeHardeningFixture) -> str:
    """Use a supplied tenant credential or create a disposable Kind identity."""
    supplied = os.environ.get("SPACE_SMOKE_NATIVE_FOREIGN_TOKEN", "").strip()
    if supplied:
        return supplied
    parsed = urlsplit(test.config.api_url)
    if (
        os.environ.get("SPACE_SMOKE_BACKEND") != "kind"
        or os.environ.get("SPACE_SMOKE_NATIVE_TENANT_FIXTURES") != "1"
        or parsed.scheme != "http"
        or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}
    ):
        raise SmokeConfigurationError(
            "tenant isolation needs SPACE_SMOKE_NATIVE_FOREIGN_TOKEN or the owned Kind harness"
        )
    slug = "native-smoke-" + uuid.uuid4().hex
    user_id = None
    org_id = None
    org_pending = False
    user_pending = False
    identity = {"slug": slug}
    test.context.record("native_foreign_identity", identity)

    def request(method: str, path: str, body: dict | None = None, *, login: bool = False):
        nonlocal org_pending, user_pending
        headers = {"Content-Type": "application/json"}
        if not login:
            headers["Authorization"] = "Bearer " + test.config.token
        payload = json.dumps(body).encode() if body is not None else None
        started = time.monotonic()
        try:
            response = _URL_OPEN(
                Request(test.config.api_url.rstrip("/") + path, data=payload,
                        headers=headers, method=method),
                timeout=test.config.request_timeout_seconds,
            )
            with response:
                raw = b"".join(_chunks(
                    response, limit=1024 * 1024,
                    deadline=started + test.config.request_timeout_seconds,
                ))
                return json.loads(raw) if raw else None
        except HTTPError as error:
            status = error.code
            error.close()
            if 400 <= status < 500 and status not in {408, 409, 429}:
                if method == "POST" and path == "/admin/api/v1/orgs":
                    org_pending = False
                elif method == "POST" and path.endswith("/users"):
                    user_pending = False
            if method == "DELETE" and status == 404:
                return None
            raise SmokeConfigurationError(
                f"native tenant fixture {method} failed with HTTP {status}"
            ) from None
        except Exception as error:
            raise SmokeConfigurationError(
                f"native tenant fixture {method} failed ({type(error).__name__})"
            ) from None

    def cleanup() -> None:
        nonlocal org_id
        # Resolve a create whose response was lost using the run's unique slug.
        deadline = time.monotonic() + 30
        while True:
            orgs = request("GET", "/admin/api/v1/orgs")
            if not isinstance(orgs, list):
                raise SmokeConfigurationError("native tenant cleanup received malformed organizations")
            matches = [item for item in orgs if isinstance(item, dict) and item.get("slug") == slug]
            if len(matches) > 1:
                raise SmokeConfigurationError("native tenant cleanup found an ambiguous organization")
            if matches:
                break
            if not org_pending:
                return
            if time.monotonic() >= deadline:
                raise SmokeConfigurationError("native tenant create remains ambiguous; resolve recorded slug")
            time.sleep(0.25)
        observed = matches[0].get("id")
        if not isinstance(observed, str) or (org_id is not None and observed != org_id):
            raise SmokeConfigurationError("native tenant cleanup organization identity changed")
        org_id = observed
        deadline = time.monotonic() + 30
        while True:
            users = request("GET", f"/admin/api/v1/orgs/{org_id}/users")
            if not isinstance(users, list):
                raise SmokeConfigurationError("native tenant cleanup received malformed users")
            if users or not user_pending:
                break
            if time.monotonic() >= deadline:
                raise SmokeConfigurationError("native tenant user create remains ambiguous; resolve recorded slug")
            time.sleep(0.25)
        # The organization was created solely for this scenario. Still refuse
        # unexpected membership rather than deleting another actor's identity.
        for user in users:
            if not isinstance(user, dict) or user.get("email") != slug + "@local":
                raise SmokeConfigurationError("native tenant cleanup found unexpected membership")
            identifier = user.get("id")
            if not isinstance(identifier, str) or (user_id is not None and identifier != user_id):
                raise SmokeConfigurationError("native tenant cleanup user identity changed")
            request("DELETE", f"/admin/api/v1/users/{identifier}")
        request("DELETE", f"/admin/api/v1/orgs/{org_id}")

    test.context.scope.defer("delete native isolation identity", cleanup, critical=True)
    org_pending = True
    created = request("POST", "/admin/api/v1/orgs", {"name": slug, "slug": slug})
    if not isinstance(created, dict) or not isinstance(created.get("id"), str):
        raise SmokeConfigurationError("native tenant organization creation omitted its identity")
    org_id = created["id"]
    org_pending = False
    identity["org_id"] = org_id
    password = uuid.uuid4().hex + "Aa1!"
    user_pending = True
    created_user = request("POST", f"/admin/api/v1/orgs/{org_id}/users", {
        "email": slug + "@local", "password": password,
        "display_name": slug, "role": "member",
    })
    if not isinstance(created_user, dict) or not isinstance(created_user.get("id"), str):
        raise SmokeConfigurationError("native tenant user creation omitted its identity")
    user_id = created_user["id"]
    user_pending = False
    identity["user_id"] = user_id
    session = request("POST", "/auth/v1/sessions", {
        "email": slug + "@local", "password": password,
    }, login=True)
    if not isinstance(session, dict) or not isinstance(session.get("token"), str) or not session["token"]:
        raise SmokeConfigurationError("native tenant session creation omitted its credential")
    return session["token"]
