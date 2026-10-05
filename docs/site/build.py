"""Assemble verified standalone outputs; never copy the repository's docs tree."""

from hashlib import sha256
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "target/docs"


def digest(file):
    return sha256(file.read_bytes()).hexdigest()


def copy_bundle(source, destination, commit):
    metadata = json.loads((source / "build.json").read_text())
    if metadata["commit"] != commit or metadata["dirty"]:
        raise ValueError(f"Rebuild {source.name}: source revision is stale or uncommitted")
    destination.mkdir()
    for name, expected in metadata["files"].items():
        artifact = source / name
        file = artifact.resolve()
        if Path(name).is_absolute() or ".." in Path(name).parts or artifact.is_symlink() or not file.is_relative_to(source.resolve()):
            raise ValueError(f"Unsafe artifact path: {name}")
        if digest(file) != expected:
            raise ValueError(f"Changed artifact: {name}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, target)
    return metadata


def refresh_manifest(directory, metadata):
    metadata["files"] = {
        file.relative_to(directory).as_posix(): digest(file)
        for file in sorted(directory.rglob("*"))
        if file.is_file() and file.name != "build.json"
    }
    (directory / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")


def assemble(commit):
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() != commit:
        raise ValueError("Source revision changed during the build")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip():
        raise ValueError("Source changed during the build; use a clean checkout")
    with tempfile.TemporaryDirectory(prefix="site-", dir=DOCS) as temp:
        site = Path(temp)
        api = copy_bundle(DOCS / "api", site / "api", commit)
        guide = copy_bundle(DOCS / "guide", site / "guide", commit)
        if digest(site / "api/openapi.json") != api["openapiSha256"]:
            raise ValueError("OpenAPI download does not match the exporter")
        source_url = f"https://github.com/perplexityai/SPACE/blob/{commit}/"
        chapter_links = {
            source_url + "docs/" + name: "../guide/" + Path(name).with_suffix(".html").name
            for name in guide["chapters"]
        }
        for name in ("toc.html", "toc.js"):
            toc = site / "guide" / name
            toc.write_text(toc.read_text().replace(
                source_url + "docs/api/index.md", "../api/index.html",
            ))
        for section in ("api", "guide"):
            for page in (site / section).glob("*.html"):
                # toc.html is mdBook's sidebar-only fallback, not a full chapter.
                if page.name == "toc.html":
                    continue
                html = page.read_text()
                if section == "guide":
                    html = html.replace(
                        f'<p><a href="{source_url}README.md">Documentation</a></p>', "",
                    )
                    html = html.replace(source_url + "docs/api/index.md", "../api/index.html")
                else:
                    html = html.replace(
                        source_url + "docs/introduction.md", "../guide/index.html",
                    )
                    html = html.replace("<footer>", (
                        f'<footer><a href="https://github.com/perplexityai/SPACE/tree/{commit}">'
                        f'Source {commit[:8]}</a> · '
                    ))
                    for original, local in chapter_links.items():
                        # Only link attributes, including optional fragments.
                        html = re.sub(
                            r'href="' + re.escape(original) + r'(#[^"]*)?"',
                            lambda match: f'href="{local}{match[1] or ""}"',
                            html,
                        )
                page.write_text(html)
        for section, metadata in (("api", api), ("guide", guide)):
            refresh_manifest(site / section, metadata)
        shutil.copyfile(ROOT / "docs/site/index.html", site / "index.html")
        shutil.copyfile(ROOT / "docs/site/entry.js", site / "entry.js")
        (site / "build.json").write_text(json.dumps({
            "commit": commit, "dirty": False, "openapiSha256": api["openapiSha256"],
            "guide": "guide/build.json", "api": "api/build.json",
        }, indent=2) + "\n")
        output = DOCS / "site"
        if output.is_symlink():
            raise ValueError(f"Refusing symlink output: {output}")
        if output.exists():
            shutil.rmtree(output)
        shutil.move(site, output)
    print(f"Built SPACE documentation from {commit} in target/docs/site")


if __name__ == "__main__":
    assemble(sys.argv[1])
