#!/usr/bin/env bash
# Usage: recordings/vhs/run-nvim.sh <workspace> [file-to-open]
# Launches nvim with the same minimal init the asciinema demos used, pointed at
# the fake pi backend. Designed to be invoked from a vhs .tape via `Type`.
set -euo pipefail

workspace="$1"
file="${2-}"

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

export STRIDER_TEST_ROOT="$repo_root"
export STRIDER_TEST_REAL_PI="0"

cd "$workspace"
if [[ -n "$file" ]]; then
  exec nvim --clean -u "$repo_root/tests/support/minimal_init.lua" "$file"
else
  exec nvim --clean -u "$repo_root/tests/support/minimal_init.lua"
fi
