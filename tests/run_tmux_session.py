#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests.support.tmux_nvim import TmuxNvimHarness


def main() -> int:
    parser = argparse.ArgumentParser(description="Launch a Sherpa tmux+nvim session")
    parser.add_argument("--project", type=Path, required=True, help="Project root to open in Neovim")
    parser.add_argument("--real-pi", action="store_true", help="Use the real pi backend instead of the fake test backend")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    harness = TmuxNvimHarness(repo_root=repo_root, project_root=args.project, real_pi=args.real_pi)
    harness.start()
    print(f"tmux session: {harness.session_name}")
    print(f"nvim socket: {harness.socket_path}")
    print(f"project: {args.project.resolve()}")
    print("Use 'tmux attach -t <session>' to inspect. Kill it manually when done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
