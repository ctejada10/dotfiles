#!/usr/bin/env bash
# The mini's t3-pstack model sheet and routing.md's roster. t3-pstack's own
# defaults run Opus at xhigh, Fable at max and a priced fast tier, so a role
# the sheet leaves out, or a rerun of /t3-pstack:setup-pstack, would break
# the rules: nothing above high, no fastMode, Fable only where routing.md
# allows it, Neon at high, Codex at medium or lower. Plain text checks, so this runs on any OS.
#
#   bash tests/check-model-sheet.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

sheet="$REPO/home/dot_local/share/dotfiles/t3-pstack/models.md"
rules="$REPO/home/dot_claude/routing.md"
roles=("feature, refactoring" "bug-fix" "perf-issue" "hillclimb" "judgment and prose" "arena runners"
       "arena cross-judge pool" "swarm workers" "interrogate reviewers" "session hook")

# problems <file>: one line per rule the sheet breaks, nothing when it keeps them all.
problems() {
  local file="$1" role line
  grep -qx '# defaults: 3' "$file" || echo "no '# defaults: 3' line, so poteto-mode would call it an old sheet"
  for role in "${roles[@]}"; do
    grep -q "^$role: " "$file" || echo "no line for $role, so it would run on t3-pstack's default"
  done
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    grep -Eq '(effort|reasoningEffort|thinking_level)=(xhigh|max)' <<< "$line" && echo "above high: $line"
    grep -q 'fastMode' <<< "$line" && echo "fastMode: $line"
    grep -q 'claude-fable' <<< "$line" && ! grep -q '^arena runners: ' <<< "$line" && echo "Fable outside the arena runners: $line"
    grep -Eo 'gemini-4-neon[^,]*' <<< "$line" | grep -vq 'thinking_level=high' && echo "Neon not at high: $line"
    grep -Eo 'codex/[^,]*' <<< "$line" | grep -Evq 'reasoningEffort=(low|medium)' && echo "Codex above medium: $line"
  done < "$file"
}

section "the sheet"
out=$(problems "$sheet")
[ -z "$out" ] && pass "keeps every rule" || fail "keeps every rule" "$out"
LC_ALL=C grep -q '[^ -~]' "$sheet" && fail "is plain ASCII" || pass "is plain ASCII"

section "the check catches a sheet that breaks a rule"
tmp=$(mktemp -d)
catches() {
  local label="$1" from="$2" to="$3"
  sed "s|$from|$to|" "$sheet" > "$tmp/sheet"
  if [ -n "$(problems "$tmp/sheet")" ]; then pass "$label"; else fail "$label"; fi
}
catches "an xhigh effort" 'bug-fix: claudeAgent/claude-opus-5-5 effort=high' 'bug-fix: claudeAgent/claude-opus-5-5 effort=xhigh'
catches "a max effort" 'hillclimb: claudeAgent/claude-opus-5-5 effort=high' 'hillclimb: claudeAgent/claude-opus-5-5 effort=max'
catches "Codex above medium" 'codex/gpt-6.2-sol reasoningEffort=medium' 'codex/gpt-6.2-sol reasoningEffort=high'
catches "fastMode" 'judgment and prose: claudeAgent/claude-opus-5-5 effort=high' 'judgment and prose: claudeAgent/claude-opus-5-5 effort=high fastMode=true'
catches "Fable on a single-model role" 'perf-issue: claudeAgent/claude-opus-5-5' 'perf-issue: claudeAgent/claude-fable-5-2'
catches "Neon at xhigh" 'interrogate reviewers: claudeAgent/claude-opus-5-5 effort=high, antigravity/gemini-4-neon thinking_level=high' 'interrogate reviewers: claudeAgent/claude-opus-5-5 effort=high, antigravity/gemini-4-neon thinking_level=xhigh'
catches "a missing role" 'swarm workers: ' 'old swarm workers: '
catches "a missing defaults line" '# defaults: 3' '# defaults: 2'
rm -rf "$tmp"

section "routing.md's roster"
for seat in 'claudeAgent/claude-opus-5-5 effort=high' 'claudeAgent/claude-sonnet-5-5 effort=high' \
            'codex/gpt-6-luna reasoningEffort=medium' 'codex/gpt-6.2-sol reasoningEffort=medium' \
            'antigravity/gemini-4-neon thinking_level=high' 'claudeAgent/claude-fable-5-2 effort=high'; do
  grep -qF "\`$seat\`" "$rules" && pass "seats $seat" || fail "seats $seat"
done
grep -Eq '(effort|reasoningEffort|thinking_level)=(xhigh|max)|fastMode=true' "$rules" \
  && fail "names nothing above high" "$(grep -En '(effort|reasoningEffort|thinking_level)=(xhigh|max)|fastMode=true' "$rules")" \
  || pass "names nothing above high"
grep -q 'At most one Fable child per DEEP task' "$rules" && pass "caps Fable at one child per DEEP task" || fail "caps Fable at one child per DEEP task"
grep -q 'usage credits' "$rules" && pass "stops Fable before usage credits" || fail "stops Fable before usage credits"

summary
