#!/usr/bin/env bash
# Usage: recordings/vhs/prep.sh <scenario> <fixture> [--git] [--diff]
# Copies tests/fixtures/<fixture> into recordings/_workspace/<scenario>
# and prints the absolute path of the prepared workspace on stdout.
#
# Flags:
#   --git   initialize a git repo with a base commit
#   --diff  mutate src/App.tsx after the base commit so `git diff` has content
#           (implies --git)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: recordings/vhs/prep.sh <scenario> <fixture> [--git] [--diff]

Examples:
  recordings/vhs/prep.sh search app
  recordings/vhs/prep.sh review_diff app --diff
EOF
}

if [[ "$#" -lt 2 ]]; then
  usage >&2
  exit 2
fi

scenario="$1"
fixture="$2"
shift 2

if [[ ! "$scenario" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "scenario must contain only letters, numbers, underscores, or dashes: $scenario" >&2
  exit 2
fi

if [[ ! "$fixture" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "fixture must name a directory under tests/fixtures: $fixture" >&2
  exit 2
fi

want_git=0
want_diff=0
for flag in "$@"; do
  case "$flag" in
    --git) want_git=1 ;;
    --diff) want_git=1; want_diff=1 ;;
    *) echo "unknown flag: $flag" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$repo_root/tests/fixtures/$fixture"
dst="$repo_root/recordings/_workspace/$scenario"

if [[ ! -d "$src" ]]; then
  echo "fixture does not exist: $src" >&2
  exit 2
fi

rm -rf -- "$dst"
mkdir -p "$dst"
cp -R "$src"/. "$dst"/

if [[ "$want_git" -eq 1 ]]; then
  (
    cd "$dst"
    git init -q
    git config user.email "demo@example.com"
    git config user.name "Strider Demo"
    git add .
    git commit -qm "base"
  )
fi

if [[ "$want_diff" -eq 1 ]]; then
  if [[ ! -f "$dst/src/App.tsx" ]]; then
    echo "--diff requires a fixture with src/App.tsx: $fixture" >&2
    exit 2
  fi

  cat > "$dst/src/App.tsx" <<'EOF'
export function App() {
  return <main>Hello from diff demo</main>
}
EOF
fi

echo "$dst"
