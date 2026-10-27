#!/usr/bin/env bash
# The mini's agent-gate hook: what it lets superpowers and AskUserQuestion do
# when Carlos is in the session, when Carlos isn't, and in a FirstMate crew.
#
#   bash tests/agent-gate.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ "$(uname)" != Darwin ]; then
  echo "agent-gate: the hook runs on the mini only and reads JSON with /usr/bin/plutil; nothing to check here"
  exit 0
fi

hook="$REPO/home/dot_claude/hooks/executable_agent-gate.sh"

# decide <mode> <json>: prints deny, context or allow.
decide() {
  local mode="$1" payload="$2" out env=(env -i PATH=/usr/bin:/bin HOME="$HOME")
  case "$mode" in
    attended) env+=(AGENT_ATTENDED=1) ;;
    firstmate) env+=(FM_TASK_ID=t1) ;;
  esac
  out=$(printf '%s' "$payload" | "${env[@]}" /bin/bash "$hook")
  if [ -z "$out" ]; then echo allow; return; fi
  if ! jq -e . >/dev/null 2>&1 <<< "$out"; then echo "invalid JSON: $out"; return; fi
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out")" = deny ]; then echo deny; else echo context; fi
}

skill() { printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"/tmp"}' "$1"; }
ask() {
  local qs="" q
  for q in "$@"; do qs="$qs${qs:+,}{\"question\":\"$q\",\"header\":\"h\",\"options\":[]}"; done
  printf '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]},"cwd":"/tmp"}' "$qs"
}
start='{"hook_event_name":"SessionStart","source":"startup","cwd":"/tmp"}'
# --fork-session, /fork, /branch and moving a conversation to the background.
fork='{"hook_event_name":"SessionStart","source":"fork","cwd":"/tmp"}'

expect() {
  local want="$1" mode="$2" label="$3" payload="$4" got
  got=$(decide "$mode" "$payload")
  if [ "$got" = "$want" ]; then pass "$want when $mode: $label"; else fail "$want when $mode: $label" "got $got"; fi
}

section "session start"
expect context unattended "the nobody-is-watching note" "$start"
expect allow attended "no note" "$start"
expect allow firstmate "no note" "$start"
expect context unattended "the note in a forked session" "$fork"
expect allow attended "no note in a forked session" "$fork"

section "brainstorming"
expect deny unattended "superpowers:brainstorming" "$(skill superpowers:brainstorming)"
expect allow attended "superpowers:brainstorming" "$(skill superpowers:brainstorming)"
expect deny firstmate "superpowers:brainstorming" "$(skill superpowers:brainstorming)"

section "finishing a branch"
for mode in unattended attended firstmate; do
  expect deny "$mode" "superpowers:finishing-a-development-branch" "$(skill superpowers:finishing-a-development-branch)"
done

section "other superpowers skills"
expect context unattended "superpowers:writing-plans" "$(skill superpowers:writing-plans)"
expect allow attended "superpowers:writing-plans" "$(skill superpowers:writing-plans)"
expect context firstmate "superpowers:systematic-debugging" "$(skill superpowers:systematic-debugging)"
expect allow unattended "a skill that isn't superpowers'" "$(skill t3-pstack:poteto-mode)"

section "questions"
expect deny unattended "an ordinary question" "$(ask 'Which retry policy?')"
expect allow unattended "a STOP: question" "$(ask 'STOP: Drop the production table?')"
expect deny unattended "a STOP: question next to an ordinary one" "$(ask 'STOP: Delete it?' 'Which name?')"
expect allow attended "an ordinary question" "$(ask 'Which retry policy?')"
expect allow firstmate "an ordinary question" "$(ask 'Which retry policy?')"

summary
