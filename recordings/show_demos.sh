#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ "$#" -eq 0 ]; then
  echo "available demos:"
  ls -1 *.cast | sed 's/\.cast$//'
  echo
  echo "play one with: ./show_demos.sh <name>"
  exit 0
fi

asciinema play "$1.cast"
