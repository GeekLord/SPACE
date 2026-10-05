#!/usr/bin/env python3
"""Mirror the Rust build inputs into a persistent tree, by content.

    sync-rust-sources.py <checkout> <mirror> <input>...

Each <input> is a file or directory relative to <checkout>. A mirror file is
rewritten only when its bytes (or symlink target, or executable bit) differ
from the checkout's, and files under a mirrored directory that the checkout no
longer has are removed. Unchanged files keep their old mtimes.

That is the point: cargo decides whether a workspace crate is fresh by
comparing source mtimes with its last build, and a fresh `git worktree add`
stamps every file with the checkout time. Building straight from a new
worktree against a warm target dir therefore recompiled all ~94 workspace
crates for byte-identical sources — 148 s on 32 vCPU, 235 s on 16 (2026-09-23
bench). Building from this mirror, only files whose content changed look new.

Prints "<written> <removed>" on stdout.
"""

from __future__ import annotations

import filecmp
import os
import shutil
import stat
import sys
from pathlib import Path


def same(src: Path, dst: Path) -> bool:
    try:
        s, d = src.lstat(), dst.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(s.st_mode) or stat.S_ISLNK(d.st_mode):
        return stat.S_ISLNK(s.st_mode) and stat.S_ISLNK(d.st_mode) and os.readlink(src) == os.readlink(dst)
    if s.st_size != d.st_size or (s.st_mode & 0o111) != (d.st_mode & 0o111):
        return False
    return filecmp.cmp(src, dst, shallow=False)


def write(src: Path, dst: Path, mirror: Path) -> None:
    # A path that was a file (or link) in the mirror and is a directory in the
    # checkout now: clear it so the directory can be created.
    for parent in reversed(dst.relative_to(mirror).parents):
        at = mirror / parent
        if at.is_symlink() or at.is_file():
            at.unlink()
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_dir() and not dst.is_symlink():
        shutil.rmtree(dst)
    tmp = dst.with_name(f".{dst.name}.sync-tmp")
    if src.is_symlink():
        tmp.unlink(missing_ok=True)
        os.symlink(os.readlink(src), tmp)
    else:
        # copyfile, not copy2: the new file must carry a new mtime.
        shutil.copyfile(src, tmp)
        os.chmod(tmp, stat.S_IMODE(src.stat().st_mode))
    os.replace(tmp, dst)


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: sync-rust-sources.py <checkout> <mirror> <input>...", file=sys.stderr)
        return 2
    checkout, mirror = Path(argv[1]), Path(argv[2])
    written = removed = 0
    for rel in argv[3:]:
        src_root, dst_root = checkout / rel, mirror / rel
        if not src_root.exists() and not src_root.is_symlink():
            print(f"build input missing from the checkout: {rel}", file=sys.stderr)
            return 1
        if src_root.is_dir() and not src_root.is_symlink():
            wanted: set[Path] = set()
            for dirpath, dirnames, filenames in os.walk(src_root):
                base = Path(dirpath)
                # Symlinked directories are mirrored as links, not walked.
                for name in list(dirnames):
                    if (base / name).is_symlink():
                        dirnames.remove(name)
                        filenames.append(name)
                for name in filenames:
                    src = base / name
                    dst = dst_root / src.relative_to(src_root)
                    wanted.add(dst)
                    if not same(src, dst):
                        write(src, dst, mirror)
                        written += 1
            if dst_root.is_dir():
                for dirpath, dirnames, filenames in os.walk(dst_root, topdown=False):
                    base = Path(dirpath)
                    for name in filenames + [d for d in dirnames if (base / d).is_symlink()]:
                        if base / name not in wanted:
                            (base / name).unlink()
                            removed += 1
                    if base != dst_root and not any(base.iterdir()):
                        base.rmdir()
        elif not same(src_root, dst_root):
            write(src_root, dst_root, mirror)
            written += 1
    print(written, removed)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
