#!/usr/bin/env python3

"""Count lines or bytes for files under a directory tree."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Iterable
from pathlib import Path

SKIP_DIRS = {
    ".git",
    ".hg",
    ".nvim-cache",
    ".nvim-data",
    ".nvim-state",
    ".svn",
    "__pycache__",
    "_workspace",
    "dist",
    "node_modules",
}
SKIP_NAMES = {".DS_Store"}
BINARY_SUFFIXES = {
    ".gif",
    ".jpeg",
    ".jpg",
    ".png",
    ".swp",
    ".webp",
}
GENERATED_SUFFIXES = {".log", ".pyc"}
COMMANDS = {"lines", "bytes"}
DEFAULT_ROOT = Path(__file__).resolve().parents[1]


def should_skip(path: Path, *, command: str = "lines") -> bool:
    """Return whether a path should be excluded from scanning."""
    if any(part in SKIP_DIRS for part in path.parts):
        return True
    if path.name in SKIP_NAMES:
        return True
    suffix = path.suffix.lower()
    if suffix in GENERATED_SUFFIXES:
        return True
    return command == "lines" and suffix in BINARY_SUFFIXES


def iter_files(root: Path, *, command: str = "lines") -> Iterable[Path]:
    """Yield scannable files under ``root`` in a stable order."""
    for path in sorted(root.rglob("*")):
        if not path.is_file() or should_skip(path, command=command):
            continue
        yield path


def count_lines(path: Path) -> int:
    """Count text lines in a file using UTF-8 with replacement for errors."""
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        return sum(1 for _ in handle)


def count_bytes(path: Path) -> int:
    """Return the file size in bytes."""
    return path.stat().st_size


def add_path_argument(parser: argparse.ArgumentParser) -> None:
    """Add the optional scan path argument to a subcommand parser."""
    parser.add_argument(
        "path",
        nargs="?",
        default=DEFAULT_ROOT,
        type=Path,
        help="Directory to scan. Defaults to the repository root.",
    )


def build_parser() -> argparse.ArgumentParser:
    """Build the command-line parser for line and byte counting."""
    parser = argparse.ArgumentParser(
        description="Count lines or bytes in each file under a directory."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    lines_parser = subparsers.add_parser("lines", help="Count lines in files.")
    add_path_argument(lines_parser)

    bytes_parser = subparsers.add_parser("bytes", help="Count bytes in files.")
    add_path_argument(bytes_parser)
    return parser


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments, defaulting to the ``lines`` subcommand."""
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] not in COMMANDS:
        args.insert(0, "lines")
    return build_parser().parse_args(args)


def get_counter(command: str):
    """Return the counting function for the selected command."""
    if command == "bytes":
        return count_bytes
    return count_lines


def main() -> int:
    """Run the selected counting command and print per-file totals."""
    args = parse_args()
    root = args.path.resolve()

    if not root.exists():
        print(f"error: path does not exist: {root}", file=sys.stderr)
        return 1

    if root.is_file():
        files = [] if should_skip(root, command=args.command) else [root]
        base = root.parent
    else:
        files = iter_files(root, command=args.command)
        base = root

    counter = get_counter(args.command)
    total = 0
    for path in files:
        value = counter(path)
        total += value
        print(f"{value:>6}  {path.relative_to(base)}")

    print(f"{'-' * 6}  {'-' * 20}")
    print(f"{total:>6}  total {args.command}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
