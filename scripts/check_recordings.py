#!/usr/bin/env python3
"""Check that VHS demo GIFs exist and are newer than their tape files."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_RE = re.compile(r"^Output\s+(?:\.gif\s+)?(.+)$")


@dataclass(frozen=True)
class RecordingStatus:
    tape: Path
    gif: Path
    status: str


def parse_output_path(tape: Path, root: Path) -> Path:
    """Return the GIF path declared by a VHS tape."""
    for line in tape.read_text(encoding="utf-8", errors="replace").splitlines():
        match = OUTPUT_RE.match(line.strip())
        if match:
            output = Path(match.group(1).strip())
            return output if output.is_absolute() else root / output
    return root / "recordings" / f"{tape.stem}.gif"


def check_tape(tape: Path, root: Path) -> RecordingStatus:
    """Classify a tape's output GIF as ok, missing, or stale."""
    gif = parse_output_path(tape, root)
    if not gif.exists():
        return RecordingStatus(tape, gif, "missing")
    if gif.stat().st_mtime < tape.stat().st_mtime:
        return RecordingStatus(tape, gif, "stale")
    return RecordingStatus(tape, gif, "ok")


def iter_tapes(root: Path) -> list[Path]:
    """Return all demo tape files in render order."""
    return sorted((root / "recordings" / "vhs").glob("*.tape"))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=DEFAULT_ROOT, type=Path)
    parser.add_argument("--quiet", action="store_true", help="Only print stale/missing recordings.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = args.root.resolve()
    statuses = [check_tape(tape, root) for tape in iter_tapes(root)]

    problems = [item for item in statuses if item.status != "ok"]
    shown = problems if args.quiet else statuses
    for item in shown:
        tape = item.tape.relative_to(root)
        gif = item.gif.relative_to(root)
        print(f"{item.status:7} {tape} -> {gif}")

    if not statuses:
        print("error: no VHS tapes found", file=sys.stderr)
        return 1
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
