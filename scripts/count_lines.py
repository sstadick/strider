#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SKIP_DIRS = {".git", ".hg", ".svn", "__pycache__"}


def iter_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        files.append(path)
    return files


def count_lines(path: Path) -> int:
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        return sum(1 for _ in handle)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Count the number of lines in each file under a directory."
    )
    parser.add_argument(
        "path",
        nargs="?",
        default=Path(__file__).resolve().parents[1],
        type=Path,
        help="Directory to scan. Defaults to the repository root.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.path.resolve()

    if not root.exists():
        print(f"error: path does not exist: {root}", file=sys.stderr)
        return 1

    if root.is_file():
        files = [root]
        base = root.parent
    else:
        files = iter_files(root)
        base = root

    total = 0
    for path in files:
        lines = count_lines(path)
        total += lines
        print(f"{lines:>6}  {path.relative_to(base)}")

    print(f"{'-' * 6}  {'-' * 20}")
    print(f"{total:>6}  total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
