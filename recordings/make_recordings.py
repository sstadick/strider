#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RECORDINGS = REPO_ROOT / "recordings"
RUNNER = RECORDINGS / "demo_runner.py"

SCENARIOS = [
    "search",
    "review-file",
    "review-diff",
    "review-searches",
    "review-selection",
    "review-comment",
    "patch",
    "work-review",
]


def record(name: str) -> None:
    cast = RECORDINGS / f"{name}.cast"
    cmd = [
        "asciinema",
        "record",
        "--overwrite",
        "--headless",
        "--idle-time-limit",
        "0.6",
        "--window-size",
        "120x36",
        "--command",
        f"{sys.executable} {RUNNER} {name}",
        str(cast),
    ]
    subprocess.run(cmd, check=True, cwd=REPO_ROOT)


def main() -> int:
    names = sys.argv[1:] or SCENARIOS
    for name in names:
        if name not in SCENARIOS:
            raise SystemExit(f"unknown scenario: {name}")
        record(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
