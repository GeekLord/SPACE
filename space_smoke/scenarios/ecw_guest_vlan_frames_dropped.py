"""Guest VLAN-tagged frames never enter the host network stack."""

from __future__ import annotations

import json
import shlex
from importlib.resources import files

import space_smoke as smoke

_PROBE_PATH = "/tmp/space-smoke-vlan-tag-probe.py"
_TAGGED_CASES = ("vlan0_nested", "qinq")


@smoke.scenario("ecw.guest_vlan_frames_dropped")
def guest_vlan_frames_dropped(test: smoke.Ecw) -> None:
    """A SYN inside VLAN tags gets no host reply while the same untagged SYN does.

    SPACE gives guests a routed point-to-point link with no VLAN configuration,
    so a tagged frame from a guest is never legitimate. The sandbox tap drops
    802.1Q and 802.1ad frames at ingress; this proves it from the only vantage
    point a tenant has. The untagged control establishes that the host does
    answer a SYN to the gateway, which is what makes silence meaningful.
    """

    source = (
        files("space_smoke.guest").joinpath("vlan_tag_probe.py").read_text(encoding="utf-8")
    )
    with test.phase("install vlan tag probe"):
        installed = test.run_command_when_ready(
            f"umask 077 && printf %s {shlex.quote(source)} > {shlex.quote(_PROBE_PATH)}",
            user="root",
            failure_message="vlan tag probe could not be installed",
        )
        test.expect_command(installed, stdout="")

    with test.phase("probe host handling of tagged frames"):
        result = test.run_command(
            f"python3 {shlex.quote(_PROBE_PATH)}",
            user="root",
            timeout=60,
            failure_message="vlan tag probe did not run",
        )
    test.verify(
        result.exit_code == 0,
        "vlan tag probe failed inside the guest",
        command_exit_code=result.exit_code,
        command_stdout=result.stdout,
        command_stderr=result.stderr,
    )
    try:
        report = json.loads(result.stdout)
    except ValueError:
        report = None
    test.verify(
        isinstance(report, dict),
        "vlan tag probe did not report a JSON object",
        command_stdout=result.stdout,
    )
    assert isinstance(report, dict)
    test.record("vlan_probe", report)

    test.verify(
        report.get("untagged") not in (None, "none"),
        "the untagged control SYN got no reply, so tagged frames cannot be judged",
        untagged_reply=report.get("untagged"),
    )
    for case in _TAGGED_CASES:
        test.verify(
            report.get(case) == "none",
            f"a {case} frame from the guest was processed by the host network stack",
            case=case,
            reply=report.get(case),
            untagged_reply=report.get("untagged"),
        )
