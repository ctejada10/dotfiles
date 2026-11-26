#!/usr/bin/env bash
# The mini's route-reminder hook: which messages get the routing rules, which
# get a leaf or opt-out line, and which get nothing.
#
#   bash tests/route-reminder.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_route-reminder.sh"
rules="$REPO/home/dot_claude/routing.md"

# routing.md itself is plain text, so these run on any OS.
section "routing.md"
card=$(sed -n '/^<!-- route-card:start -->$/,/^<!-- route-card:end -->$/p' "$rules" | sed '1d;$d')
[ -n "$card" ] && pass "has a route card between its markers" || fail "has a route card between its markers"
[ "$(printf '%s\n' "$card" | wc -l)" -le 15 ] && pass "the card is 15 lines or fewer" || fail "the card is 15 lines or fewer" "$(printf '%s\n' "$card" | wc -l) lines"
[ "$(printf '%s\n' "$card" | wc -c)" -le 1500 ] && pass "the card is 1,500 bytes or fewer" || fail "the card is 1,500 bytes or fewer" "$(printf '%s\n' "$card" | wc -c) bytes"
for route in DEEP TRIVIAL QUESTION SKIP; do
  grep -q "^- $route" <<< "$card" && pass "the card names $route" || fail "the card names $route"
done
grep -q '^Route: DEEP|TRIVIAL|QUESTION|SKIP' <<< "$card" && pass "the card asks for the Route line" || fail "the card asks for the Route line"
grep -q 'read ~/.claude/routing.md in full' <<< "$card" && pass "the card sends the agent to the whole file" || fail "the card sends the agent to the whole file"
grep -q '`t3-pstack:poteto-mode`' "$rules" && pass "sends DEEP work to poteto-mode" || fail "sends DEEP work to poteto-mode"
grep -q '^## TRIVIAL' "$rules" && grep -q 'then `code-review` at level `low`' "$rules" \
  && pass "holds TRIVIAL's own steps" || fail "holds TRIVIAL's own steps"
grep -q 'skills/go' "$rules" && fail "no longer sends work to /go" || pass "no longer sends work to /go"
grep -q 'pick DEEP' "$rules" && pass "picks DEEP when unsure" || fail "picks DEEP when unsure"
for rule in 'At most 4 `delegate_task` children run at once per parent.' \
            'At most 3 review rounds per change.' \
            'At most 4 agent-to-agent handoffs without a message from Carlos.' \
            'Every child is a leaf.'; do
  [ "$(grep -cF -- "$rule" "$rules")" = 1 ] && pass "states once: $rule" || fail "states once: $rule"
done
for field in 'BRIEF FOR:' 'ROLE:' 'GOAL:' 'CONTEXT:' 'DONE WHEN:' 'DO NOT:' 'RETURN:'; do
  grep -q "^$field" "$rules" && pass "the brief format has $field" || fail "the brief format has $field"
done
grep -q '^DO NOT: start no subagents' "$rules" && pass "every brief starts no subagents" || fail "every brief starts no subagents"
grep -q 'the provider and model that actually ran' "$rules" && pass "every brief reports the model that ran" || fail "every brief reports the model that ran"
[ "$(grep -c 'ponytail:ponytail-review` once' "$rules")" = 1 ] && pass "DEEP runs the Ponytail review once" || fail "DEEP runs the Ponytail review once"
LC_ALL=C grep -q '[^ -~]' "$rules" && fail "is plain ASCII" "$(LC_ALL=C grep -n '[^ -~]' "$rules")" || pass "is plain ASCII"

if [ "$(uname)" != Darwin ] && [ "${ROUTE_TEST_ANY_OS:-0}" != 1 ]; then
  echo
  echo "route-reminder: the hook runs on the mini only and reads JSON with /usr/bin/plutil; the hook's own checks run there"
  summary
  exit $?
fi

# run <mode> <json>: the hook's output, with routing.md in a throwaway home.
run() {
  local mode="$1" payload="$2" home env
  home=$(mktemp -d)
  mkdir -p "$home/.claude"
  cp "$rules" "$home/.claude/routing.md"
  env=(env -i PATH=/usr/bin:/bin HOME="$home")
  case "$mode" in
    attended) env+=(AGENT_ATTENDED=1) ;;
    firstmate) env+=(FM_TASK_ID=t1) ;;
  esac
  printf '%s' "$payload" | "${env[@]}" /bin/bash "$hook"
  echo "exit=$?"
  rm -rf "$home"
}

msg() { jq -cn --arg p "$1" '{hook_event_name:"UserPromptSubmit",prompt:$p,cwd:"/tmp",session_id:"s1"}'; }

# expect <what> <mode> <label> <prompt>: what is rules, attended, leaf, skip or nothing.
expect() {
  local want="$1" mode="$2" label="$3" out got
  out=$(run "$mode" "$(msg "$4")")
  case "$out" in
    *"exit=0") ;;
    *) fail "$label exits 0" "$out"; return ;;
  esac
  out=${out%exit=0}
  if [ -z "${out//[$'\n']/}" ]; then got=nothing
  elif grep -q "delegated child, a leaf" <<< "$out"; then got=leaf
  elif grep -q "^Route: SKIP" <<< "$out"; then got=skip
  elif grep -q "^Route: DEEP|TRIVIAL|QUESTION|SKIP" <<< "$out"; then
    if grep -q "Carlos is in this thread" <<< "$out"; then got=attended; else got=rules; fi
  else got="unexpected: $out"
  fi
  if [ "$got" = "$want" ]; then pass "$want: $label"; else fail "$want: $label" "got $got"; fi
}

section "Carlos's messages"
expect rules unattended "a feature request" "Add a --json flag to dotfiles doctor"
expect rules unattended "a one-line fix" "Fix the typo 'recieve' in docs/setup-mini.md"
expect rules unattended "a question" "Why does chezmoi diff show the plist every run?"
expect rules unattended "a message after blank lines" $'\n\nRename parse_pins and update its callers'
expect attended attended "a feature request in an attended thread" "Add a --json flag to dotfiles doctor"

section "opt-outs and commands"
expect skip unattended "a message starting with --" "-- print pins.yaml"
expect nothing unattended "a slash command" "/superpowers:brainstorming a cache for the poster service"
expect nothing unattended "a Codex skill" "\$t3-pstack:poteto-mode tidy the hooks"

section "children and crews"
expect leaf unattended "T3's brief for a child" "Act as the reviewer sub-agent for this task. Review the diff."
expect leaf attended "a child of an attended thread" "Act as the reviewer sub-agent for this task. Review the diff."
expect leaf unattended "a brief in routing.md's format" $'BRIEF FOR: codex/gpt-6-luna reasoningEffort=medium\nROLE: research\nGOAL: Find every caller of parse_pins.'
expect leaf unattended "t3-pstack's worker.md pointer" "Read /Users/me/.claude/plugins/cache/t3-pstack/skills/poteto-mode/worker.md before anything else. Then build it."
expect nothing unattended "a child's report to its parent" "Delegated task abc123 finished: 3 files changed."
expect nothing firstmate "a FirstMate crew" "Add a --json flag to dotfiles doctor"

section "never in the way"
out=$(run unattended 'not json')
[ "$out" = "exit=0" ] && pass "malformed JSON: nothing, exit 0" || fail "malformed JSON: nothing, exit 0" "$out"
out=$(run unattended '{"hook_event_name":"UserPromptSubmit","prompt":""}')
[ "$out" = "exit=0" ] && pass "an empty message: nothing, exit 0" || fail "an empty message: nothing, exit 0" "$out"
out=$(printf '%s' "$(msg "Add a flag")" | env -i PATH=/usr/bin:/bin HOME="$(mktemp -d)" /bin/bash "$hook"; echo "exit=$?")
[ "$out" = "exit=0" ] && pass "no routing.md: nothing, exit 0" || fail "no routing.md: nothing, exit 0" "$out"

section "what Carlos's messages get"
out=$(run unattended "$(msg "Add a --json flag to dotfiles doctor")")
out=${out%exit=0}
[ "$out" = "$card"$'\n' ] && pass "the card, and nothing else from routing.md" || fail "the card, and nothing else from routing.md" "$out"
home=$(mktemp -d); mkdir -p "$home/.claude"
grep -v 'route-card:' "$rules" > "$home/.claude/routing.md"
out=$(printf '%s' "$(msg "Add a flag")" | env -i PATH=/usr/bin:/bin HOME="$home" /bin/bash "$hook")
rm -rf "$home"
grep -q '^## Roster' <<< "$out" && pass "without the markers, the whole file" || fail "without the markers, the whole file"

section "review children"
# review <prompt> [session]: whether the hook marked the session, and what it said.
review() {
  local home out payload
  home=$(mktemp -d); mkdir -p "$home/.claude"; cp "$rules" "$home/.claude/routing.md"
  payload=$(jq -cn --arg p "$1" --arg s "${2:-s1}" '{hook_event_name:"UserPromptSubmit",prompt:$p,cwd:"/tmp",session_id:$s}')
  out=$(printf '%s' "$payload" | env -i PATH=/usr/bin:/bin HOME="$home" /bin/bash "$hook")
  if [ -n "$(ls -A "$home/.local/state/dotfiles/review-children" 2>/dev/null)" ]; then echo marked; else echo unmarked; fi
  grep -q 'Your role is review' <<< "$out" && echo told || echo untold
  rm -rf "$home"
}
got=$(review $'BRIEF FOR: claudeAgent/claude-sonnet-5-5 effort=high\nROLE: review\nGOAL: Break this change.' | tr '\n' ' ')
[ "$got" = "marked told " ] && pass "a ROLE: review brief marks its session" || fail "a ROLE: review brief marks its session" "$got"
got=$(review $'Read /Users/me/.claude/plugins/cache/t3-pstack/skills/poteto-mode/worker.md before anything else.\nBRIEF FOR: antigravity/gemini-4-neon thinking_level=high\nROLE: reviewer\nGOAL: Check the plan.' | tr '\n' ' ')
[ "$got" = "marked told " ] && pass "so does one under t3-pstack's pointer" || fail "so does one under t3-pstack's pointer" "$got"
got=$(review "Act as the review sub-agent for this task. Review the diff." | tr '\n' ' ')
[ "$got" = "marked told " ] && pass "so does T3's review sub-agent brief" || fail "so does T3's review sub-agent brief" "$got"
got=$(review $'BRIEF FOR: claudeAgent/claude-opus-5-5 effort=high\nROLE: implementation\nGOAL: Build it.' | tr '\n' ' ')
[ "$got" = "unmarked untold " ] && pass "a builder's brief marks nothing" || fail "a builder's brief marks nothing" "$got"
got=$(review "Review the diff in docs/ and tell me what you think" | tr '\n' ' ')
[ "$got" = "unmarked untold " ] && pass "Carlos asking for a review marks nothing" || fail "Carlos asking for a review marks nothing" "$got"
got=$(review $'BRIEF FOR: x\nROLE: review' '../escape' | tr '\n' ' ')
[ "$got" = "unmarked told " ] && pass "a session id with a slash marks nothing" || fail "a session id with a slash marks nothing" "$got"

summary
