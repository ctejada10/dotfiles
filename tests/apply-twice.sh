#!/usr/bin/env bash
# For each role: init a throwaway home, apply twice, then require an empty
# `chezmoi diff` and a `chezmoi verify` that exits 0. Only the ci role runs
# its scripts (it has none that change the machine). The others are rendered
# and applied with scripts and externals left out, because chezmoi runs
# scripts against the real home folder.
#
#   bash tests/apply-twice.sh [role ...]    default: every role this OS can take

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ $# -gt 0 ]; then
  roles=("$@")
elif [ "$(uname)" = Darwin ]; then
  roles=(ci laptop agent-mini)
else
  roles=(ci server)
fi

for role in "${roles[@]}"; do
  section "apply twice as $role"
  # bash 3.2 (macOS) treats an empty array as unset under set -u, so ci
  # excludes nothing explicitly.
  skipped="scripts,externals"
  if [ "$role" = ci ]; then exclude=(--exclude=none); else exclude=("--exclude=$skipped"); fi
  log="$(mktemp)"
  if ! sandbox "$role" >"$log" 2>&1; then fail "init as $role" "$(cat "$log")"; rm -f "$log"; cleanup_sandbox; continue; fi
  rm -f "$log"

  if out=$(cz apply "${exclude[@]}" 2>&1); then pass "first apply"; else fail "first apply" "$out"; fi
  if out=$(cz apply "${exclude[@]}" 2>&1); then pass "second apply"; else fail "second apply" "$out"; fi

  diff_out=$(cz diff "${exclude[@]}" 2>&1)
  if [ -z "$diff_out" ]; then pass "diff is empty"; else fail "diff is empty" "$diff_out"; fi

  if out=$(cz verify "${exclude[@]}" 2>&1); then pass "verify exits 0"; else fail "verify exits 0" "$out"; fi
  if [ -e "$SANDBOX/op-called" ]; then fail "no template runs op" "$(cat "$SANDBOX/op-called")"; else pass "no template runs op"; fi

  # chezmoi skips a script that renders to whitespace. In CI every script must
  # render that way: CI never renames a machine, installs or reads 1Password.
  if [ "$role" = ci ]; then
    rendered=""
    for script in "$REPO"/home/.chezmoiscripts/*.tmpl; do
      if [ -n "$(cz execute-template < "$script" | tr -d '[:space:]')" ]; then
        rendered="$rendered$(basename "$script")"$'\n'
      fi
    done
    if [ -z "$rendered" ]; then pass "ci renders no scripts"; else fail "ci renders no scripts" "$rendered"; fi
  fi
  cleanup_sandbox
done

summary
