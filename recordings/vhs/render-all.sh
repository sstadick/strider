#!/usr/bin/env bash
# Render every Strider VHS demo and print a short verification summary.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if ! command -v vhs >/dev/null 2>&1; then
  echo "vhs is required. Install it with: brew install vhs" >&2
  exit 1
fi

vhs validate recordings/vhs/*.tape

for tape in recordings/vhs/*.tape; do
  echo "Rendering $tape"
  vhs "$tape"
done

if command -v ffprobe >/dev/null 2>&1; then
  echo
  echo "Rendered GIFs"
  for gif in recordings/*.gif; do
    printf "%s " "$gif"
    ffprobe -v error \
      -select_streams v:0 \
      -show_entries stream=width,height,nb_frames,duration \
      -of csv=p=0 \
      "$gif"
  done
fi
