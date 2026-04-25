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

scenario="$1"
fixture="$2"
shift 2

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

rm -rf "$dst"
mkdir -p "$(dirname "$dst")"
cp -R "$src" "$dst"

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
  cat > "$dst/src/App.tsx" <<'EOF'
export function App() {
  return <main>Hello from diff demo</main>
}
EOF
fi

echo "$dst"
