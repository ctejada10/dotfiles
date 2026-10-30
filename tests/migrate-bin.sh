#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sandbox laptop
trap cleanup_sandbox EXIT
script="$SANDBOX/migrate.sh"
cz execute-template < "$REPO/home/.chezmoiscripts/run_before_05-migrate-bin.sh.tmpl" > "$script"
mkdir -p "$SANDBOX/home/bin"
printf binary > "$SANDBOX/home/bin/chezmoi"
printf hidden > "$SANDBOX/home/bin/.hidden"
HOME="$SANDBOX/home" bash "$script"
[ ! -e "$SANDBOX/home/bin" ]
[ "$(cat "$SANDBOX/home/.local/bin/chezmoi")" = binary ]
[ "$(cat "$SANDBOX/home/.local/bin/.hidden")" = hidden ]
HOME="$SANDBOX/home" bash "$script"
mkdir "$SANDBOX/home/bin"
HOME="$SANDBOX/home" bash "$script"
[ ! -e "$SANDBOX/home/bin" ]
mkdir "$SANDBOX/home/bin"
printf old > "$SANDBOX/home/bin/chezmoi"
if HOME="$SANDBOX/home" bash "$script"; then
  echo "collision must fail" >&2
  exit 1
fi
[ "$(cat "$SANDBOX/home/bin/chezmoi")" = old ]
[ "$(cat "$SANDBOX/home/.local/bin/chezmoi")" = binary ]
echo "migration, hidden files, repeat run and collision preservation passed"
