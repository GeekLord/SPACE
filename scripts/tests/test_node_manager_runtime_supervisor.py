#!/usr/bin/env python3

from __future__ import annotations

import os
import pathlib
import subprocess


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts/k8s/node-manager-runtime-supervisor.sh"


def write_executable(path: pathlib.Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


def run_rollout(
    tmp_path: pathlib.Path,
    fake_bin: pathlib.Path,
    marker: pathlib.Path,
    work_gate: pathlib.Path,
    socket: pathlib.Path,
    probe: pathlib.Path,
) -> subprocess.CompletedProcess[str]:
    driver = tmp_path / "run-rollout.sh"
    write_executable(
        driver,
        """#!/bin/bash
set -euo pipefail
log_init() { printf '%s\n' "$*"; }
. "$RESTART_HELPER"
node_manager_ensure_runtime_supervisor \
  true \
  "$RESTART_MARKER" \
  "$WORK_GATE" \
  "$HEALTH_SOCKET" \
  "$HEALTH_PROBE"
printf 'action=%s\n' "$RUNTIME_SUPERVISOR_ACTION"
""",
    )
    return subprocess.run(
        ["bash", str(driver)],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "RESTART_HELPER": str(HELPER),
            "RESTART_MARKER": str(marker),
            "WORK_GATE": str(work_gate),
            "HEALTH_SOCKET": str(socket),
            "HEALTH_PROBE": str(probe),
            "RESTART_LOG": str(tmp_path / "restart.log"),
        },
        capture_output=True,
        text=True,
        check=False,
    )


def run_activation(
    tmp_path: pathlib.Path,
    fake_bin: pathlib.Path,
    marker: pathlib.Path,
    work_gate: pathlib.Path,
    socket: pathlib.Path,
    probe: pathlib.Path,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            str(HELPER),
            "activate",
            str(marker),
            str(work_gate),
            str(socket),
            str(probe),
        ],
        env={
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "RESTART_LOG": str(tmp_path / "restart.log"),
        },
        capture_output=True,
        text=True,
        check=False,
    )


def test_rollout_defers_to_successor_activation_and_ignores_stale_witness(
    tmp_path: pathlib.Path,
) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "nsenter",
        """#!/bin/bash
printf '%s\n' "$*" >>"$RESTART_LOG"
""",
    )
    probe = fake_bin / "grpc_health_probe"
    write_executable(probe, "#!/bin/bash\nexit 0\n")

    marker = tmp_path / "restart-required"
    marker.touch()
    stale_capabilities = tmp_path / "client-capabilities"
    stale_capabilities.write_text("runtime-supervisor-connect-retry\n")
    work_gate = tmp_path / "work-v1.lock"
    work_gate.touch()
    socket = tmp_path / "runtime-supervisor.sock"

    first = run_rollout(
        tmp_path,
        fake_bin,
        marker,
        work_gate,
        socket,
        probe,
    )

    assert first.returncode == 0, first.stderr
    assert "action=deferred" in first.stdout
    assert marker.exists()
    assert "systemctl restart space-runtime-supervisor.service" not in (
        tmp_path / "restart.log"
    ).read_text()

    activation = run_activation(
        tmp_path,
        fake_bin,
        marker,
        work_gate,
        socket,
        probe,
    )

    assert activation.returncode == 0, activation.stderr
    assert "staged replacement activated" in activation.stdout
    assert not marker.exists()
    assert (
        tmp_path / "restart.log"
    ).read_text().count("systemctl restart space-runtime-supervisor.service") == 1


def test_successor_activation_without_staged_replacement_is_a_noop(
    tmp_path: pathlib.Path,
) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(fake_bin / "nsenter", "#!/bin/bash\nexit 0\n")
    probe = fake_bin / "grpc_health_probe"
    write_executable(probe, "#!/bin/bash\nexit 0\n")
    work_gate = tmp_path / "work-v1.lock"
    work_gate.touch()

    activation = run_activation(
        tmp_path,
        fake_bin,
        tmp_path / "restart-required",
        work_gate,
        tmp_path / "runtime-supervisor.sock",
        probe,
    )

    assert activation.returncode == 0, activation.stderr
    assert "has no staged replacement" in activation.stdout
    assert not (tmp_path / "restart.log").exists()


def test_failed_successor_activation_preserves_staged_replacement(
    tmp_path: pathlib.Path,
) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(fake_bin / "nsenter", "#!/bin/bash\nexit 1\n")
    probe = fake_bin / "grpc_health_probe"
    write_executable(probe, "#!/bin/bash\nexit 0\n")
    marker = tmp_path / "restart-required"
    marker.touch()
    work_gate = tmp_path / "work-v1.lock"
    work_gate.touch()

    activation = run_activation(
        tmp_path,
        fake_bin,
        marker,
        work_gate,
        tmp_path / "runtime-supervisor.sock",
        probe,
    )

    assert activation.returncode != 0
    assert marker.exists()


def test_worker_image_installs_the_restart_helper() -> None:
    dockerfile = (REPO_ROOT / "docker/Dockerfile.worker").read_text()
    assert (
        "scripts/k8s/node-manager-runtime-supervisor.sh "
        "/opt/space/bin/node-manager-runtime-supervisor.sh"
    ) in dockerfile
