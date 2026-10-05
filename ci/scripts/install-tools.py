#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# ///
"""Install CI tools on demand for Buildkite steps.

Run this script with `uv run --script ci/scripts/install-tools.py ...`
after bootstrapping `uv` with `ci/scripts/ensure-uv.sh` on CI agents.
"""

from __future__ import annotations

import glob
import hashlib
import http.client
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable, Sequence

REPO_ROOT = Path(__file__).resolve().parents[2]
SHIM_GO_MOD = REPO_ROOT / "shim/go.mod"
GOLANGCI_LINT_VERSION = os.environ.get("GOLANGCI_LINT_VERSION", "2.8.0")
GOLANGCI_LINT_SHA256 = {
    ("2.8.0", "darwin", "amd64"): "164c72806d0e31ab19da4f08fff748a3fdc57e241851279b666c945ed9b91830",
    ("2.8.0", "darwin", "arm64"): "6f8979a83117e0607d4b85ff486382ef0404440bbf54f0e6f003ceab6ccf641e",
    ("2.8.0", "linux", "amd64"): "7048bc6b25c9515ed092c83f9fa8709ca97937ead52d9ff317a143299ee97a50",
    ("2.8.0", "linux", "arm64"): "2a58388db8af5ab9330791cea0ebdd4100723cd05ad7185d92febaaee272ec9a",
}
DOCKER_BUILDX_VERSION = os.environ.get("DOCKER_BUILDX_VERSION", "v0.30.1")
HELM_VERSION = os.environ.get("HELM_VERSION", "v3.18.0")
# `--include-crds` landed in helm-diff v3.11.0; below that a chart's `crds/` are
# outside `helm diff` entirely and the cluster-bootstrap drift gate degrades to
# comparing everything but the CRDs. Deployments using this installer share
# the pin, so moving it can affect their diff behavior too.
HELM_DIFF_VERSION = os.environ.get("HELM_DIFF_VERSION", "v3.14.1")
# helm-diff raised its own floor to helm 3.18 in v3.13.0: from there its
# plugin.yaml uses platformCommand `args`, which older helm rejects outright.
# The failure is not confined to the install -- helm reports "plugin is
# installed but unusable" and then every later `helm plugin list` fails to load
# any plugin at all. install_helm() keeps whatever helm is already on PATH, so
# a host carrying an older one has to be shadowed before the plugin is touched.
# Both bounds are needed because both pins are overridable: an older plugin on
# an older helm is a coherent pair and must not be refused.
HELM_DIFF_FLOOR_SINCE = (3, 13, 0)
HELM_DIFF_MINIMUM_HELM = (3, 18)
KUBECTL_VERSION = os.environ.get("KUBECTL_VERSION", "v1.35.0")
SCCACHE_VERSION = os.environ.get("SCCACHE_VERSION", "0.16.0")
SCCACHE_SHA256 = {
    ("0.16.0", "darwin", "amd64"): "f7dbd055db75a938ab1539f5316c5d08e73a1b94c40ab170ddcc617f5bf18343",
    ("0.16.0", "darwin", "arm64"): "ded590cae2c72042c61178632906bef62d635fa20d45f8b22110a2241f430960",
    ("0.16.0", "linux", "amd64"): "aec995a83ad3dff3d14b6314e08858b7b73d35ca85a5bcf3d3a9ec07dee35588",
    ("0.16.0", "linux", "arm64"): "f73a5c39f96bb6ebb89cc7915cf182260d4cbf30765322c5e793d0fe8bd80784",
}
WILD_VERSION = os.environ.get("WILD_VERSION", "0.9.0")
WILD_SHA256 = {
    ("0.9.0", "linux", "amd64"): "deb6ee0e5caec798053ec4aafaba042e20a8edf91f08cb4d36268571cc628d3b",
    ("0.9.0", "linux", "arm64"): "8855a347b9dfbc762e2492125ee82d09313124da3be616b1cd027a14eddfe8c0",
}
LOCAL_BIN_DIR = REPO_ROOT / "ci/bin"
HELM_PLUGINS_DIR = REPO_ROOT / "ci/helm/plugins"
DOWNLOAD_ATTEMPTS = 3
TRANSIENT_NETWORK_EXIT_STATUS = 75
os.environ["PATH"] = f"{LOCAL_BIN_DIR}:{os.environ.get('PATH', '')}"
os.environ.setdefault("HELM_PLUGINS", str(HELM_PLUGINS_DIR))


def run(
    args: Sequence[str],
    *,
    check: bool = True,
    capture: bool = False,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        list(args),
        check=False,
        text=True,
        capture_output=capture,
        cwd=str(cwd) if cwd is not None else None,
        env=env,
        input=input_text,
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode,
            args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result


def run_as_root(
    args: Sequence[str],
    *,
    check: bool = True,
    capture: bool = False,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    command = list(args)
    if os.geteuid() != 0 and Path("/usr/bin/sudo").exists():
        command = ["/usr/bin/sudo", *command]
    return run(
        command,
        check=check,
        capture=capture,
        cwd=cwd,
        env=env,
        input_text=input_text,
    )


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def download_file(url: str, dest: Path, *, mode: int | None = None) -> None:
    retryable_errors = (
        ConnectionError,
        TimeoutError,
        http.client.IncompleteRead,
        urllib.error.URLError,
    )
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url) as response, dest.open("wb") as fh:
                shutil.copyfileobj(response, fh)
            break
        except retryable_errors as error:
            dest.unlink(missing_ok=True)
            if attempt == DOWNLOAD_ATTEMPTS:
                print(
                    "Download retries exhausted; requesting a fresh CI agent",
                    file=sys.stderr,
                )
                raise SystemExit(TRANSIENT_NETWORK_EXIT_STATUS) from error
            delay_seconds = 2 ** (attempt - 1)
            print(
                f"Download failed ({error}); retrying in {delay_seconds}s "
                f"[{attempt}/{DOWNLOAD_ATTEMPTS}]",
                file=sys.stderr,
            )
            time.sleep(delay_seconds)
    if mode is not None:
        dest.chmod(mode)


def apt_install(packages: Iterable[str]) -> None:
    env = os.environ.copy()
    env["DEBIAN_FRONTEND"] = "noninteractive"
    run_as_root(["apt-get", "update", "-qq"], env=env)
    run_as_root(
        ["apt-get", "install", "-y", "-qq", "--no-install-recommends", *packages],
        env=env,
    )


def parse_go_version() -> str:
    match = re.search(r"^go\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)$", SHIM_GO_MOD.read_text(), re.M)
    if not match:
        raise SystemExit(f"Error: could not parse Go version from {SHIM_GO_MOD}")
    return match.group(1)


def install_go() -> None:
    go_version = parse_go_version()
    if command_exists("go"):
        installed = run(["go", "version"], capture=True).stdout
        match = re.search(r"go([0-9]+\.[0-9]+\.[0-9]+)", installed)
        if match and match.group(1) == go_version:
            print(f"Go {go_version} already installed")
            return

    print(f"Installing Go {go_version}...")
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        archive = tmp_path / f"go{go_version}.linux-amd64.tar.gz"
        download_file(f"https://go.dev/dl/go{go_version}.linux-amd64.tar.gz", archive)
        run_as_root(["tar", "-C", "/usr/local", "-xzf", str(archive)])

    os.environ["PATH"] = f"/usr/local/go/bin:{os.environ.get('PATH', '')}"
    version = run(["go", "version"], capture=True).stdout.strip()
    print(f"Go {version.split()[2]}")


def install_golangci_lint() -> None:
    if command_exists("golangci-lint"):
        print("golangci-lint already installed")
        return

    print(f"Installing golangci-lint v{GOLANGCI_LINT_VERSION}...")
    with tempfile.TemporaryDirectory() as tmp_dir:
        os_name = platform.system().lower()
        machine = platform.machine().lower()
        arch = {
            "aarch64": "arm64",
            "arm64": "arm64",
            "x86_64": "amd64",
            "amd64": "amd64",
        }.get(machine)
        if os_name not in {"linux", "darwin"} or arch is None:
            raise SystemExit(f"unsupported golangci-lint platform: {os_name}/{machine}")

        archive = Path(tmp_dir) / "golangci-lint.tar.gz"
        package = f"golangci-lint-{GOLANGCI_LINT_VERSION}-{os_name}-{arch}"
        download_file(
            f"https://github.com/golangci/golangci-lint/releases/download/v{GOLANGCI_LINT_VERSION}/{package}.tar.gz",
            archive,
        )
        expected_sha256 = GOLANGCI_LINT_SHA256.get((GOLANGCI_LINT_VERSION, os_name, arch))
        if expected_sha256 is None:
            raise SystemExit(
                f"missing pinned SHA256 for golangci-lint "
                f"{GOLANGCI_LINT_VERSION} on {os_name}/{arch}"
            )
        actual_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual_sha256 != expected_sha256:
            raise SystemExit(
                f"golangci-lint archive SHA256 mismatch: "
                f"expected {expected_sha256}, got {actual_sha256}"
            )
        run(["tar", "-xzf", str(archive), "-C", tmp_dir])
        run_as_root(
            [
                "install",
                "-m",
                "0755",
                str(Path(tmp_dir) / package / "golangci-lint"),
                "/usr/local/bin/golangci-lint",
            ]
        )


def install_tfswitch() -> None:
    if command_exists("tfswitch"):
        print("tfswitch already installed")
        return

    print("Installing tfswitch...")
    LOCAL_BIN_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(REPO_ROOT / "ci/scripts/tfswitch-lite.sh", LOCAL_BIN_DIR / "tfswitch")
    (LOCAL_BIN_DIR / "tfswitch").chmod(0o755)


def install_bindfs() -> None:
    if command_exists("bindfs"):
        print("bindfs already installed")
        return

    print("Installing bindfs...")
    apt_install(["bindfs"])


def read_os_release_value(key: str) -> str:
    for line in Path("/etc/os-release").read_text().splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit(f"Error: {key} missing from /etc/os-release")


def docker_apt_repository_config(os_id: str, codename: str, arch: str) -> tuple[str, str]:
    distro = os_id.strip().lower()
    if distro not in {"debian", "ubuntu"}:
        raise SystemExit(f"Error: unsupported Docker apt distribution: {os_id}")

    repository_url = f"https://download.docker.com/linux/{distro}"
    source = (
        f"deb [arch={arch} signed-by=/etc/apt/keyrings/docker.gpg] "
        f"{repository_url} {codename} stable\n"
    )
    return f"{repository_url}/gpg", source


def configure_docker_apt_repository() -> None:
    # A previous interrupted attempt may have left an invalid distribution URL
    # that would make the prerequisite apt update fail before we can replace it.
    run_as_root(["rm", "-f", "/etc/apt/sources.list.d/docker.list"])
    apt_install(["ca-certificates", "curl", "gnupg"])
    run_as_root(["install", "-m", "0755", "-d", "/etc/apt/keyrings"])

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        docker_asc = tmp_path / "docker.asc"
        docker_gpg = tmp_path / "docker.gpg"
        docker_list = tmp_path / "docker.list"

        os_id = read_os_release_value("ID")
        codename = read_os_release_value("VERSION_CODENAME")
        arch = run(["dpkg", "--print-architecture"], capture=True).stdout.strip()
        gpg_url, source = docker_apt_repository_config(os_id, codename, arch)

        download_file(gpg_url, docker_asc)
        run(["gpg", "--dearmor", "-o", str(docker_gpg), str(docker_asc)])
        docker_list.write_text(source)

        run_as_root(["rm", "-f", "/etc/apt/keyrings/docker.gpg"])
        run_as_root(["install", "-m", "0644", str(docker_gpg), "/etc/apt/keyrings/docker.gpg"])
        run_as_root(
            [
                "install",
                "-m",
                "0644",
                str(docker_list),
                "/etc/apt/sources.list.d/docker.list",
            ]
        )

    run_as_root(["apt-get", "update"])


def install_docker_cli() -> None:
    if command_exists("docker"):
        print("docker already installed")
        return

    print("Installing Docker CLI...")
    configure_docker_apt_repository()
    env = os.environ.copy()
    env["DEBIAN_FRONTEND"] = "noninteractive"
    run_as_root(
        ["apt-get", "install", "-y", "--no-install-recommends", "docker-ce-cli"],
        env=env,
    )


def install_docker_buildx_plugin() -> None:
    if command_exists("docker") and run(["docker", "buildx", "version"], check=False).returncode == 0:
        print("docker buildx already installed")
        return

    os_name = run(["uname", "-s"], capture=True).stdout.strip().lower()
    arch = run(["uname", "-m"], capture=True).stdout.strip()
    if arch == "x86_64":
        arch = "amd64"
    elif arch in {"aarch64", "arm64"}:
        arch = "arm64"
    else:
        raise SystemExit(f"Error: unsupported architecture for docker buildx install: {arch}")

    plugin_dir = Path(os.environ.get("DOCKER_CONFIG", str(Path.home() / ".docker"))) / "cli-plugins"
    plugin_dir.mkdir(parents=True, exist_ok=True)
    plugin_path = plugin_dir / "docker-buildx"
    download_url = (
        "https://github.com/docker/buildx/releases/download/"
        f"{DOCKER_BUILDX_VERSION}/buildx-{DOCKER_BUILDX_VERSION}.{os_name}-{arch}"
    )

    print(f"Installing docker buildx {DOCKER_BUILDX_VERSION}...")
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmpfile = Path(tmp_dir) / "docker-buildx"
        download_file(download_url, tmpfile, mode=0o755)
        shutil.copy2(tmpfile, plugin_path)
        plugin_path.chmod(0o755)

    if not command_exists("docker") or run(["docker", "buildx", "version"], check=False).returncode != 0:
        raise SystemExit("Error: docker buildx is unavailable after installing the standalone plugin.")


def install_aws_cli() -> None:
    if command_exists("aws"):
        print("aws already installed")
        return

    print("Installing AWS CLI...")
    apt_install(["awscli"])


def normalized_platform() -> tuple[str, str]:
    os_name = run(["uname", "-s"], capture=True).stdout.strip().lower()
    machine = run(["uname", "-m"], capture=True).stdout.strip().lower()
    arch = {
        "x86_64": "amd64",
        "amd64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
    }.get(machine)
    if arch is None:
        raise SystemExit(f"unsupported platform architecture: {machine}")
    return os_name, arch


def install_helm() -> None:
    if command_exists("helm"):
        print("helm already installed")
        return
    download_pinned_helm()


def download_pinned_helm() -> None:
    """Put the pinned helm in LOCAL_BIN_DIR, which shadows any helm on PATH."""
    os_name, arch = normalized_platform()
    if os_name not in {"linux", "darwin"}:
        raise SystemExit(f"unsupported helm platform: {os_name}/{arch}")

    print(f"Installing Helm {HELM_VERSION}...", flush=True)
    LOCAL_BIN_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        archive = tmp_path / "helm.tar.gz"
        download_file(
            f"https://get.helm.sh/helm-{HELM_VERSION}-{os_name}-{arch}.tar.gz",
            archive,
        )
        run(["tar", "-xzf", str(archive), "-C", str(tmp_path)])
        shutil.copy2(tmp_path / f"{os_name}-{arch}" / "helm", LOCAL_BIN_DIR / "helm")
        (LOCAL_BIN_DIR / "helm").chmod(0o755)


def parse_semver(text: str) -> tuple[int, ...] | None:
    """The first `[v]MAJOR.MINOR.PATCH` in `text` as ints, or None if absent."""
    match = re.search(r"v?(\d+)\.(\d+)\.(\d+)", text)
    return tuple(int(group) for group in match.groups()) if match else None


def installed_helm_version() -> tuple[int, ...] | None:
    """The helm on PATH as (major, minor, patch), or None if it cannot be read."""
    if not command_exists("helm"):
        return None
    result = run(["helm", "version", "--short"], capture=True, check=False)
    if result.returncode != 0:
        return None
    return parse_semver(result.stdout)


def required_helm_for_helm_diff() -> tuple[int, ...] | None:
    """The helm minor the pinned helm-diff needs, or None when it needs no floor.

    An unparseable pin is treated as modern: a plugin nobody can place is more
    likely to be newer than the last release that ran on pre-3.18 helm.
    """
    plugin = parse_semver(HELM_DIFF_VERSION)
    if plugin is not None and plugin < HELM_DIFF_FLOOR_SINCE:
        return None
    return HELM_DIFF_MINIMUM_HELM


def installed_helm_diff_version() -> str | None:
    """The `diff` plugin's version as helm reports it, or None when absent."""
    result = run(["helm", "plugin", "list"], capture=True)
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "diff":
            return fields[1]
    return None


def install_helm_diff() -> None:
    # Replace a mismatched plugin rather than accept it. The plugin directory is
    # gitignored, so a reused checkout (or a machine that ran an older revision
    # of this script) keeps whatever was installed first, and accepting that
    # would make this pin an intent rather than a description of what runs.
    # `helm plugin install` refuses to overwrite an existing plugin and
    # `helm plugin update` re-resolves to the default branch instead of a tag,
    # so uninstall-then-install is the only way to move to a pinned version.
    install_helm()
    wanted = HELM_DIFF_VERSION.lstrip("v")
    required = required_helm_for_helm_diff()
    if required is not None:
        floor = ".".join(str(part) for part in required)

        # A HELM_VERSION below the floor would make the recovery below download
        # the very version that cannot load the plugin. Checked against the pin
        # rather than the machine, so a host that happens to carry a newer helm
        # doesn't hide the contradiction until the next agent.
        pinned_helm = parse_semver(HELM_VERSION)
        if pinned_helm is None or pinned_helm[:2] < required:
            raise SystemExit(
                f"HELM_VERSION={HELM_VERSION} is below helm-diff {wanted}'s floor "
                f"of helm {floor}; installing that pair leaves the plugin "
                f"unusable. Raise HELM_VERSION, or pin HELM_DIFF_VERSION below "
                f"v{'.'.join(str(part) for part in HELM_DIFF_FLOOR_SINCE)}."
            )

        running = installed_helm_version()
        if running is None or running[:2] < required:
            found = ".".join(str(p) for p in running) if running else "<unreadable>"
            print(
                f"helm {found} is below helm-diff {wanted}'s floor of {floor}; "
                f"installing pinned Helm {HELM_VERSION} first",
                flush=True,
            )
            download_pinned_helm()

    HELM_PLUGINS_DIR.mkdir(parents=True, exist_ok=True)
    installed = installed_helm_diff_version()
    if installed == wanted:
        print(f"helm-diff {wanted} already installed")
        return

    if installed is not None:
        print(f"Replacing helm-diff {installed} with {wanted}...", flush=True)
        run(["helm", "plugin", "uninstall", "diff"])
    else:
        print(f"Installing helm-diff {wanted}...", flush=True)

    run(
        [
            "helm",
            "plugin",
            "install",
            "https://github.com/databus23/helm-diff",
            "--version",
            HELM_DIFF_VERSION,
        ]
    )
    settled = installed_helm_diff_version()
    if settled != wanted:
        raise SystemExit(
            f"unexpected helm-diff version after install: expected {wanted}, "
            f"got {settled or '<absent>'}"
        )


def install_kubectl() -> None:
    if command_exists("kubectl"):
        print("kubectl already installed")
        return

    os_name, arch = normalized_platform()
    if os_name != "linux":
        raise SystemExit(f"unsupported kubectl platform: {os_name}/{arch}")

    print(f"Installing kubectl {KUBECTL_VERSION}...")
    LOCAL_BIN_DIR.mkdir(parents=True, exist_ok=True)
    download_file(
        f"https://dl.k8s.io/release/{KUBECTL_VERSION}/bin/{os_name}/{arch}/kubectl",
        LOCAL_BIN_DIR / "kubectl",
        mode=0o755,
    )


def install_sccache() -> None:
    expected_version = f"sccache {SCCACHE_VERSION}"
    if command_exists("sccache"):
        installed_version = run(["sccache", "--version"], capture=True).stdout.strip()
        if installed_version == expected_version:
            print(f"sccache {SCCACHE_VERSION} already installed")
            return

    os_name, arch = normalized_platform()
    target = {
        ("darwin", "amd64"): "x86_64-apple-darwin",
        ("darwin", "arm64"): "aarch64-apple-darwin",
        ("linux", "amd64"): "x86_64-unknown-linux-musl",
        ("linux", "arm64"): "aarch64-unknown-linux-musl",
    }.get((os_name, arch))
    if target is None:
        raise SystemExit(f"unsupported sccache platform: {os_name}/{arch}")

    expected_sha256 = SCCACHE_SHA256.get((SCCACHE_VERSION, os_name, arch))
    if expected_sha256 is None:
        raise SystemExit(
            f"missing pinned SHA256 for sccache {SCCACHE_VERSION} on {os_name}/{arch}"
        )

    print(f"Installing sccache {SCCACHE_VERSION}...")
    LOCAL_BIN_DIR.mkdir(parents=True, exist_ok=True)
    package = f"sccache-v{SCCACHE_VERSION}-{target}"
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        archive = tmp_path / "sccache.tar.gz"
        download_file(
            f"https://github.com/mozilla/sccache/releases/download/"
            f"v{SCCACHE_VERSION}/{package}.tar.gz",
            archive,
        )
        actual_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual_sha256 != expected_sha256:
            raise SystemExit(
                f"sccache archive SHA256 mismatch: expected {expected_sha256}, "
                f"got {actual_sha256}"
            )
        run(["tar", "-xzf", str(archive), "-C", str(tmp_path)])
        shutil.copy2(tmp_path / package / "sccache", LOCAL_BIN_DIR / "sccache")
        (LOCAL_BIN_DIR / "sccache").chmod(0o755)

    installed_version = run(["sccache", "--version"], capture=True).stdout.strip()
    if installed_version != expected_version:
        raise SystemExit(
            f"unexpected sccache version after install: expected {expected_version}, "
            f"got {installed_version}"
        )


def install_wild() -> None:
    expected_version = f"Wild {WILD_VERSION} (compatible with GNU linkers)"
    if command_exists("wild"):
        installed_version = run(["wild", "--version"], capture=True).stdout.strip()
        if installed_version == expected_version:
            print(f"Wild {WILD_VERSION} already installed")
            return

    os_name, arch = normalized_platform()
    target = {
        ("linux", "amd64"): "x86_64-unknown-linux-gnu",
        ("linux", "arm64"): "aarch64-unknown-linux-gnu",
    }.get((os_name, arch))
    if target is None:
        raise SystemExit(f"unsupported Wild platform: {os_name}/{arch}")

    expected_sha256 = WILD_SHA256.get((WILD_VERSION, os_name, arch))
    if expected_sha256 is None:
        raise SystemExit(f"missing pinned SHA256 for Wild {WILD_VERSION} on {os_name}/{arch}")

    print(f"Installing Wild {WILD_VERSION}...")
    LOCAL_BIN_DIR.mkdir(parents=True, exist_ok=True)
    package = f"wild-linker-{WILD_VERSION}-{target}"
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        archive = tmp_path / "wild.tar.gz"
        download_file(
            f"https://github.com/wild-linker/wild/releases/download/"
            f"{WILD_VERSION}/{package}.tar.gz",
            archive,
        )
        actual_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual_sha256 != expected_sha256:
            raise SystemExit(
                f"Wild archive SHA256 mismatch: expected {expected_sha256}, "
                f"got {actual_sha256}"
            )
        run(["tar", "-xzf", str(archive), "-C", str(tmp_path)])
        shutil.copy2(tmp_path / package / "wild", LOCAL_BIN_DIR / "wild")
        (LOCAL_BIN_DIR / "wild").chmod(0o755)

    installed_version = run(["wild", "--version"], capture=True).stdout.strip()
    if installed_version != expected_version:
        raise SystemExit(
            f"unexpected Wild version after install: expected {expected_version}, "
            f"got {installed_version}"
        )


def install_envsubst() -> None:
    if (LOCAL_BIN_DIR / "envsubst").is_file() and os.access(LOCAL_BIN_DIR / "envsubst", os.X_OK):
        print(f"envsubst shim already available ({LOCAL_BIN_DIR / 'envsubst'})")
        return

    for path in (Path("/usr/bin/envsubst"), Path("/usr/local/bin/envsubst")):
        if path.exists() and os.access(path, os.X_OK):
            print(f"envsubst already installed ({path})")
            return

    print("Installing envsubst...")
    apt_install(["gettext-base"])


def install_google_cloud_cli() -> None:
    gcloud_shim = LOCAL_BIN_DIR / "gcloud"
    gsutil_shim = LOCAL_BIN_DIR / "gsutil"
    if all(path.exists() and os.access(path, os.X_OK) for path in (gcloud_shim, gsutil_shim)):
        print(f"google-cloud-cli shims already available ({gcloud_shim}, {gsutil_shim})")
        return

    for path in (Path("/usr/bin/gcloud"), Path("/usr/local/bin/gcloud"), Path("/snap/bin/gcloud")):
        if path.exists() and os.access(path, os.X_OK):
            print(f"google-cloud-cli already installed ({path})")
            return

    print("Installing google-cloud-cli...")
    apt_install(["ca-certificates", "curl", "gnupg"])
    run_as_root(["install", "-m", "0755", "-d", "/etc/apt/keyrings"])

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        google_asc = tmp_path / "google-cloud.asc"
        google_gpg = tmp_path / "google-cloud-cli.gpg"
        google_list = tmp_path / "google-cloud-sdk.list"

        download_file("https://packages.cloud.google.com/apt/doc/apt-key.gpg", google_asc)
        run(["gpg", "--dearmor", "-o", str(google_gpg), str(google_asc)])
        google_list.write_text(
            "deb [signed-by=/etc/apt/keyrings/google-cloud-cli.gpg] "
            "https://packages.cloud.google.com/apt cloud-sdk main\n"
        )

        run_as_root(["rm", "-f", "/etc/apt/keyrings/google-cloud-cli.gpg"])
        run_as_root(
            ["install", "-m", "0644", str(google_gpg), "/etc/apt/keyrings/google-cloud-cli.gpg"]
        )
        run_as_root(
            [
                "install",
                "-m",
                "0644",
                str(google_list),
                "/etc/apt/sources.list.d/google-cloud-sdk.list",
            ]
        )

    run_as_root(["apt-get", "update"])
    env = os.environ.copy()
    env["DEBIAN_FRONTEND"] = "noninteractive"
    run_as_root(
        ["apt-get", "install", "-y", "--no-install-recommends", "google-cloud-cli"],
        env=env,
    )


def extract_deb_binaries(pkg: str) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workdir = Path(tmp_dir)
        extract_dir = workdir / "extract"
        try:
            run_as_root(["apt-get", "update", "-qq"], check=False)
        except Exception:
            pass
        run(["apt-get", "download", pkg], cwd=workdir)

        matches = glob.glob(str(workdir / f"{pkg}_*.deb"))
        if not matches:
            raise SystemExit(f"Error: apt-get download did not produce a .deb for {pkg}")

        run(["dpkg-deb", "-x", matches[0], str(extract_dir)])

        copy_targets = {
            extract_dir / "bin": Path("/bin"),
            extract_dir / "sbin": Path("/sbin"),
            extract_dir / "usr/bin": Path("/usr/bin"),
            extract_dir / "usr/sbin": Path("/usr/sbin"),
        }
        for src_dir, target_dir in copy_targets.items():
            if not src_dir.is_dir():
                continue
            run_as_root(["mkdir", "-p", str(target_dir)])
            for child in src_dir.iterdir():
                run_as_root(["cp", "-a", str(child), f"{target_dir}/"])

        for lib_dir in (extract_dir / "lib", extract_dir / "usr/lib"):
            if not lib_dir.is_dir():
                continue
            for child in lib_dir.iterdir():
                run_as_root(["cp", "-a", str(child), "/usr/lib/"])


def binary_exists(paths: Iterable[str]) -> str | None:
    for path in paths:
        if Path(path).exists() and os.access(path, os.X_OK):
            return path
    return None


def install_kmod() -> None:
    existing = binary_exists(("/sbin/modprobe", "/usr/sbin/modprobe", "/bin/modprobe", "/usr/bin/modprobe"))
    if existing:
        print(f"kmod already installed ({existing})")
        return

    print("Installing kmod (via dpkg-deb extract)...")
    extract_deb_binaries("kmod")
    existing = binary_exists(("/sbin/modprobe", "/usr/sbin/modprobe", "/bin/modprobe", "/usr/bin/modprobe"))
    if existing:
        print(f"kmod installed successfully ({existing})")
    else:
        print(
            "Warning: kmod extraction completed but modprobe not found; modprobe shim will handle fallback",
            file=sys.stderr,
        )


def install_udev() -> None:
    existing = binary_exists(("/sbin/udevadm", "/usr/sbin/udevadm", "/bin/udevadm", "/usr/bin/udevadm"))
    if existing:
        print(f"udev already installed ({existing})")
        return

    print("Installing udev (via dpkg-deb extract)...")
    extract_deb_binaries("udev")
    existing = binary_exists(("/sbin/udevadm", "/usr/sbin/udevadm", "/bin/udevadm", "/usr/bin/udevadm"))
    if existing:
        print(f"udev installed successfully ({existing})")
    else:
        print(
            "Warning: udev extraction completed but udevadm not found; udevadm shim will handle fallback",
            file=sys.stderr,
        )


INSTALLERS = {
    "go": install_go,
    "golangci-lint": install_golangci_lint,
    "tfswitch": install_tfswitch,
    "bindfs": install_bindfs,
    "docker-cli": install_docker_cli,
    "docker-buildx-plugin": install_docker_buildx_plugin,
    "aws-cli": install_aws_cli,
    "helm": install_helm,
    "helm-diff": install_helm_diff,
    "kubectl": install_kubectl,
    "sccache": install_sccache,
    "wild": install_wild,
    "envsubst": install_envsubst,
    "google-cloud-cli": install_google_cloud_cli,
    "kmod": install_kmod,
    "udev": install_udev,
}


def main(argv: list[str]) -> int:
    for tool in argv:
        installer = INSTALLERS.get(tool)
        if installer is None:
            raise SystemExit(f"Unknown tool: {tool}")
        installer()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
