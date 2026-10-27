#!/usr/bin/env bash
# The advisory hook for Bash. A risky command gets its warning as
# additionalContext in one JSON object on stdout, which Claude reads with the
# tool's result; any other command gets no output. It never blocks, asks or
# allows anything itself.
#
#   bash tests/warn-risky.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_warn-risky.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# expect <warns|quiet> <command> [text the warning holds]
expect() {
  local want="$1" cmd="$2" says="${3:-}" rc
  jq -n --arg c "$cmd" '{tool_input: {command: $c}}' | (cd "${dir:-$work}" && bash "$hook") > "$work/out" 2> "$work/err"
  rc=$?
  if [ "$rc" != 0 ] || [ -s "$work/err" ]; then
    fail "$want: $cmd" "exit $rc, stderr: $(cat "$work/err")"
  elif [ "$want" = quiet ]; then
    [ ! -s "$work/out" ] && pass "quiet: $cmd" || fail "quiet: $cmd" "$(cat "$work/out")"
  elif jq -e --arg s "$says" '(keys == ["hookSpecificOutput"])
      and (.hookSpecificOutput | keys == ["additionalContext", "hookEventName"])
      and .hookSpecificOutput.hookEventName == "PreToolUse"
      and (.hookSpecificOutput.additionalContext | contains($s))' "$work/out" >/dev/null 2>&1; then
    pass "warns: $cmd"
  else
    fail "warns: $cmd" "$(cat "$work/out")"
  fi
}

section "risky commands warn the model"
expect warns "git gc --prune=now" "rewrites the object store"
expect warns "git push --force origin main" "force-push"
expect warns "rm ~/Documents/armenelos/old.md" "breaks inbound wikilinks"
expect warns "uv run pytest tests/test_api.py" "Add --no-cov"
expect warns "git gc && git push -f origin x" "force-push"

section "everything else is quiet"
expect quiet "git status"
expect quiet "uv run pytest --no-cov tests/test_api.py"
expect quiet "make test"
printf 'not json' | bash "$hook" > "$work/out" 2>&1
rc=$?
[ "$rc" = 0 ] && [ ! -s "$work/out" ] && pass "quiet: input that isn't JSON" || fail "quiet: input that isn't JSON" "exit $rc: $(cat "$work/out")"

section "two warnings in one object"
jq -n '{tool_input: {command: "git gc && git push --force"}}' | bash "$hook" > "$work/out"
[ "$(jq -r '.hookSpecificOutput.additionalContext' "$work/out" | grep -c '^WARNING: ')" = 2 ] \
  && pass "both warnings, one per line" || fail "both warnings, one per line" "$(cat "$work/out")"

section "a json.py in the session's folder"
# Python run with -c puts the current folder first on its path; -I doesn't.
dir="$work/repo"
mkdir -p "$dir"
printf 'raise SystemExit("planted json.py ran")\n' > "$dir/json.py"
expect warns "git gc" "rewrites the object store"
unset dir

summary
