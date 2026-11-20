#!/usr/bin/env bash
# The mini's route-reminder hook: which messages get the routing rules, which
# get a leaf or opt-out line, and which get nothing.
#
#   bash tests/route-reminder.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ "$(uname)" != Darwin ] && [ "${ROUTE_TEST_ANY_OS:-0}" != 1 ]; then
  echo "route-reminder: the hook runs on the mini only and reads JSON with /usr/bin/plutil; nothing to check here"
  exit 0
fi

hook="$REPO/home/dot_claude/hooks/executable_route-reminder.sh"
rules="$REPO/home/dot_claude/routing.md"

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

msg() { jq -cn --arg p "$1" '{hook_event_name:"UserPromptSubmit",prompt:$p,cwd:"/tmp"}'; }

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
expect nothing unattended "a slash command" "/go fix the typo in README"
expect nothing unattended "a Codex skill" "\$t3-pstack:poteto-mode tidy the hooks"

section "children and crews"
expect leaf unattended "T3's brief for a child" "Act as the reviewer sub-agent for this task. Review the diff."
expect leaf attended "a child of an attended thread" "Act as the reviewer sub-agent for this task. Review the diff."
expect leaf unattended "t3-pstack's worker.md pointer" "Read /Users/ctejada/.claude/plugins/cache/t3-pstack/skills/poteto-mode/worker.md before anything else. Then build it."
expect nothing unattended "a child's report to its parent" "Delegated task abc123 finished: 3 files changed."
expect nothing firstmate "a FirstMate crew" "Add a --json flag to dotfiles doctor"

section "never in the way"
out=$(run unattended 'not json')
[ "$out" = "exit=0" ] && pass "malformed JSON: nothing, exit 0" || fail "malformed JSON: nothing, exit 0" "$out"
out=$(run unattended '{"hook_event_name":"UserPromptSubmit","prompt":""}')
[ "$out" = "exit=0" ] && pass "an empty message: nothing, exit 0" || fail "an empty message: nothing, exit 0" "$out"
out=$(printf '%s' "$(msg "Add a flag")" | env -i PATH=/usr/bin:/bin HOME="$(mktemp -d)" /bin/bash "$hook"; echo "exit=$?")
[ "$out" = "exit=0" ] && pass "no routing.md: nothing, exit 0" || fail "no routing.md: nothing, exit 0" "$out"

section "routing.md"
grep -q '`t3-pstack:poteto-mode`' "$rules" && pass "sends DEEP work to poteto-mode" || fail "sends DEEP work to poteto-mode"
grep -q 'skills/go/SKILL.md' "$rules" && pass "sends TRIVIAL work through /go's small path" || fail "sends TRIVIAL work through /go's small path"
grep -q 'pick DEEP' "$rules" && pass "picks DEEP when unsure" || fail "picks DEEP when unsure"
LC_ALL=C grep -q '[^ -~]' "$rules" && fail "is plain ASCII" "$(LC_ALL=C grep -n '[^ -~]' "$rules")" || pass "is plain ASCII"

summary
