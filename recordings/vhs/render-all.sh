#!/usr/bin/env bash
# Render Strider VHS demos and print a short verification summary.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: recordings/vhs/render-all.sh [demo-name|path/to/demo.tape ...]

Examples:
  recordings/vhs/render-all.sh
  recordings/vhs/render-all.sh search patch
  recordings/vhs/render-all.sh recordings/vhs/review-file.tape

Environment:
  VHS_BIN=...       VHS executable to run. Default: vhs
  FFPROBE_BIN=...   ffprobe executable to use for metadata. Default: ffprobe
  VHS_VALIDATE=0    skip pre-render tape validation
  VHS_QUIET=1       pass --quiet to vhs
EOF
}

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

recordings_dir="recordings"
tape_dir="$recordings_dir/vhs"
vhs_bin="${VHS_BIN:-vhs}"
ffprobe_bin="${FFPROBE_BIN:-ffprobe}"
validate="${VHS_VALIDATE:-1}"
quiet="${VHS_QUIET:-0}"
last_step="initializing"

on_error() {
  printf "\nrender-all failed while %s\n" "$last_step" >&2
}
trap on_error ERR

need_cmd() {
  local cmd="$1"
  local install_hint="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf "%s is required. %s\n" "$cmd" "$install_hint" >&2
    exit 1
  fi
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_tape() {
  local input="$1"
  local candidate

  case "$input" in
    *.tape|*/*) candidate="$input" ;;
    *) candidate="$tape_dir/$input.tape" ;;
  esac

  if [[ ! -f "$candidate" && "$candidate" != *.tape && -f "$candidate.tape" ]]; then
    candidate="$candidate.tape"
  fi

  if [[ ! -f "$candidate" ]]; then
    printf "Unknown demo tape: %s\n" "$input" >&2
    return 1
  fi

  printf "%s\n" "$candidate"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd "$vhs_bin" "Install it with: brew install vhs"
need_cmd nvim "Install Neovim before rendering demos."
need_cmd python3 "Install python3 before rendering demos."
need_cmd git "Install git before rendering demos."

tapes=()
if [[ "$#" -eq 0 ]]; then
  for tape in "$tape_dir"/*.tape; do
    [[ -f "$tape" ]] || {
      printf "No VHS tapes found under %s\n" "$tape_dir" >&2
      exit 1
    }
    tapes+=("$tape")
  done
else
  for arg in "$@"; do
    tapes+=("$(resolve_tape "$arg")")
  done
fi

vhs_flags=()
if is_truthy "$quiet"; then
  vhs_flags+=("--quiet")
fi

if ! is_truthy "$validate"; then
  printf "Skipping validation because VHS_VALIDATE=%s\n" "$validate"
else
  last_step="validating ${#tapes[@]} tape(s)"
  printf "Validating %d tape(s)\n" "${#tapes[@]}"
  "$vhs_bin" validate "${tapes[@]}"
fi

for tape in "${tapes[@]}"; do
  last_step="rendering $tape"
  start_time="$(date +%s)"
  printf "Rendering %s\n" "$tape"
  "$vhs_bin" "${vhs_flags[@]}" "$tape"
  end_time="$(date +%s)"
  elapsed="$((end_time - start_time))"
  printf "Rendered %s in %ss\n" "$tape" "$elapsed"
done

if command -v "$ffprobe_bin" >/dev/null 2>&1; then
  echo
  echo "Rendered GIFs"
  for tape in "${tapes[@]}"; do
    gif="$(awk '$1 == "Output" { print $2; exit }' "$tape")"
    [[ -n "$gif" ]] || continue

    if [[ ! -f "$gif" ]]; then
      printf "%s missing\n" "$gif"
      continue
    fi

    printf "%s " "$gif"
    "$ffprobe_bin" -v error \
      -select_streams v:0 \
      -show_entries stream=width,height,nb_frames,duration \
      -of csv=p=0 \
      "$gif"
  done
else
  printf "\n%s not found; skipping GIF metadata summary\n" "$ffprobe_bin"
fi
