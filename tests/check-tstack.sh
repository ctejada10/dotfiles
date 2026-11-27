#!/usr/bin/env bash
# The skills copied in from Theo Browne's tstack: each one matches its sha256
# in pins.yaml and is plain ASCII, the licence is here, and routing.md runs
# them and overrides the lines that clash with the rules. A changed file
# means a new pin, never an edit.
#
#   bash tests/check-tstack.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

pins="$REPO/home/.chezmoidata/pins.yaml"

section "pin"
commit=$(sed -n '/^  tstack:/,/^  [a-z]/s/^    commit: \([0-9a-f]*\)$/\1/p' "$pins")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] && pass "pins a full commit" || fail "pins a full commit" "${commit:-none}"
files=$(sed -n '/^  tstack:/,/^  [a-z]/s/^      \([^:]*\): \([0-9a-f]\{64\}\)$/\1 \2/p' "$pins")
count=$(grep -c . <<< "$files")
[ "$count" = 2 ] && pass "lists two files" || fail "lists two files" "$count"

section "files"
while read -r path want; do
  [ -n "$path" ] || continue
  f="$REPO/$path"
  if [ ! -f "$f" ]; then fail "$path exists"; continue; fi
  got=$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -c1-64)
  [ "$got" = "$want" ] && pass "$path matches its pin" || fail "$path matches its pin" "got $got"
  LC_ALL=C grep -q '[^[:print:][:space:]]' "$f" \
    && fail "$path is plain ASCII" "$(LC_ALL=C grep -n '[^[:print:][:space:]]' "$f" | head -3)" \
    || pass "$path is plain ASCII"
  name=$(sed -n '2,/^---$/s/^name: \(.*\)$/\1/p' "$f")
  [ "$name" = "$(basename "$(dirname "$path")")" ] && pass "$path is named after its folder" \
    || fail "$path is named after its folder" "${name:-none}"
done <<< "$files"

section "licence"
[ -s "$REPO/LICENSES/tstack-MIT.txt" ] && grep -q 'Theo Browne' "$REPO/LICENSES/tstack-MIT.txt" \
  && pass "LICENSES/tstack-MIT.txt" || fail "LICENSES/tstack-MIT.txt"
grep -q "$commit" "$REPO/LICENSES/README.md" && pass "LICENSES/README.md names the pinned commit" \
  || fail "LICENSES/README.md names the pinned commit"

section "only the mini"
ignore="$REPO/home/.chezmoiignore"
for skill in sol-loop council; do
  awk '/^\{\{ if not \.isAgent -\}\}$/ {on=1} on && /^\{\{- end/ {on=0} on' "$ignore" | grep -qx ".claude/skills/$skill" \
    && pass "$skill is left off every other machine" || fail "$skill is left off every other machine"
done

section "routing"
rules="$REPO/home/dot_claude/routing.md"
for skill in sol-loop council; do
  grep -qF "/.claude/skills/$skill/SKILL.md" "$rules" && pass "routing.md runs $skill" || fail "routing.md runs $skill"
done
review=$(sed -n '/^## Review$/,/^## /p' "$rules")
grep -q 'Reviewed with sol-loop' <<< "$review" && grep -q '## Council review' <<< "$review" \
  && pass "routing.md overrides the PR-body lines that credit a model" \
  || fail "routing.md overrides the PR-body lines that credit a model"
grep -qi 'never 5' <<< "$review" && pass "routing.md caps the loop at 3 rounds" || fail "routing.md caps the loop at 3 rounds"
grep -q 'reasoningEffort=medium' <<< "$review" && pass "routing.md keeps Sol at medium in a council" \
  || fail "routing.md keeps Sol at medium in a council"

summary
