#!/usr/bin/env bash
# Usage: recordings/vhs/run-nvim.sh <workspace> [file-to-open]
# Launches nvim with the same minimal init the asciinema demos used, pointed at
# the fake pi backend. Designed to be invoked from a vhs .tape via `Type`.
set -euo pipefail

usage() {
  echo "Usage: recordings/vhs/run-nvim.sh <workspace> [file-to-open]" >&2
}

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  usage
  exit 2
fi

workspace="$1"
file="${2-}"
file_path=""

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ ! -d "$workspace" ]]; then
  echo "workspace does not exist: $workspace" >&2
  exit 2
fi

if [[ -n "$file" ]]; then
  case "$file" in
    /*) file_path="$file" ;;
    *) file_path="$workspace/$file" ;;
  esac

  if [[ ! -e "$file_path" ]]; then
    echo "file does not exist in workspace: $file" >&2
    exit 2
  fi
fi

if ! command -v nvim >/dev/null 2>&1; then
  echo "nvim is required to render demos" >&2
  exit 1
fi

export STRIDER_TEST_ROOT="$repo_root"
export STRIDER_TEST_REAL_PI="0"

cd "$workspace"
if [[ -n "$file" ]]; then
  exec nvim --clean -u "$repo_root/tests/support/minimal_init.lua" -- "$file"
else
  exec nvim --clean -u "$repo_root/tests/support/minimal_init.lua"
fi
