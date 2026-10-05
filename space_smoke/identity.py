"""Focused assertions for ECW identity contracts."""

from __future__ import annotations

import shlex
from collections.abc import Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING

from space_smoke.capabilities import EcwWatchHandle

if TYPE_CHECKING:
    from space_smoke.fixtures import Ecw


@dataclass(frozen=True)
class EcwIdentityAssertions:
    """Reusable observations and assertions for selected guest identities."""

    _test: Ecw

    def expect_process(
        self,
        *,
        as_user: str | None,
        expected_user: str,
        expected_home: str,
        expected_cwd: str | None = None,
        reject_root_environment: bool = False,
    ) -> None:
        """Require the selected process identity and login environment."""

        result = self._test.run_command(
            'printf "%s\\n" "$(id -un)" "$PWD" "$HOME" "$USER" "$LOGNAME"; '
            'printf "%s" "${HOME-}:${USER-}:${LOGNAME-}:${SHELL-}:'
            '${XDG_CACHE_HOME-}:${MAIL-}:$PATH"',
            user=as_user,
            failure_message=f"could not observe process identity for {as_user!r}",
        )
        lines = result.stdout.splitlines()
        self._test.verify(
            result.exit_code == 0 and len(lines) >= 6,
            "process identity observation was incomplete",
            requested_user=as_user,
            command_exit_code=result.exit_code,
            command_stdout=result.stdout,
            command_stderr=result.stderr,
        )
        observed_user, observed_cwd, home, env_user, logname = lines[:5]
        environment = lines[5]
        self._test.verify_equal(
            actual=(observed_user, home, env_user, logname),
            expected=(expected_user, expected_home, expected_user, expected_user),
            message="process identity did not match the selected sandbox user",
            requested_user=as_user,
            observed_cwd=observed_cwd,
            observed_environment=environment,
        )
        if expected_cwd is not None:
            self._test.verify_equal(
                actual=observed_cwd,
                expected=expected_cwd,
                message="process working directory did not match its login identity",
                requested_user=as_user,
            )
        if reject_root_environment:
            self._test.verify(
                "/root" not in environment,
                "default process inherited a root environment path",
                requested_user=as_user,
                observed_environment=environment,
            )

    def expect_watcher_denied(
        self,
        path: str,
        *,
        user: str | None,
        recursive: bool = False,
    ) -> None:
        """Require watcher creation denial without leaking a surprise handle."""

        label = "omitted" if user is None else user
        handle: EcwWatchHandle | None = None
        try:
            with self._test.expect_permission_denied(
                f"{label} CreateWatcher under root-private directory"
            ):
                handle = self._test.sandbox.files.watch_dir(
                    path,
                    user=user,
                    recursive=recursive,
                )
        finally:
            if handle is not None:
                try:
                    handle.stop()
                except Exception as error:  # noqa: BLE001 - preserve primary failure
                    cleanup_errors = self._test._context.evidence.setdefault(
                        "unexpected_watcher_cleanup_errors", []
                    )
                    assert isinstance(cleanup_errors, list)
                    cleanup_errors.append(str(error)[:1_000])

    def uid(self, user: str) -> int:
        """Resolve one named guest account to a non-root numeric uid."""

        result = self._test.run_command(
            f"id -u {shlex.quote(user)}",
            user="root",
            failure_message=f"could not resolve the sandbox uid for {user}",
        )
        observed = result.stdout.strip()
        self._test.verify(
            result.exit_code == 0 and observed.isdigit() and observed != "0",
            f"sandbox account {user} did not resolve to a non-root uid",
            command_exit_code=result.exit_code,
            command_stdout=result.stdout,
            command_stderr=result.stderr,
        )
        return int(observed)

    def file_owner_uids(self, paths: Sequence[str]) -> dict[str, int]:
        """Read numeric ownership for an exact set of guest paths."""

        quoted_paths = " ".join(shlex.quote(path) for path in paths)
        result = self._test.run_command(
            f"stat -c '%u %n' -- {quoted_paths}",
            user="root",
            failure_message="could not stat filesystem ownership",
        )
        self._test.verify(
            result.exit_code == 0,
            "stat could not read filesystem ownership",
            command_exit_code=result.exit_code,
            command_stdout=result.stdout,
            command_stderr=result.stderr,
        )
        owners: dict[str, int] = {}
        for line in result.stdout.splitlines():
            uid, separator, path = line.partition(" ")
            self._test.verify(
                bool(separator) and uid.isdigit() and bool(path),
                "stat returned an unparseable ownership row",
                stat_row=line,
            )
            owners[path] = int(uid)
        return owners
