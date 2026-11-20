#!/bin/bash
# UserPromptSubmit hook, on the mini only. t3-pstack's own hook tells a chat
# once, at session start, when to enter poteto-mode, and the reminder fades in
# a long thread. This one repeats the routing rules in ~/.claude/routing.md on
# every message Carlos sends, so deep work goes through poteto-mode by default.
#
# What it adds to the message:
#   a delegated child's brief          a reminder that it is a leaf
#   a child's report to its parent     nothing
#   a FirstMate crew                   nothing: its brief decides
#   a slash command or $skill          nothing: Carlos chose the skill
#   a message starting with --         the opt-out, in one line
#   anything else                      routing.md, plus, when attended, a
#                                      line to confirm the route first
#
# Plain text on stdout is added to the message as context. It never blocks a
# message: every failure exits 0 with nothing printed. Reads the hook's JSON
# with macOS's own plutil, like agent-gate.sh.

set -u

PLUTIL=/usr/bin/plutil
RULES="$HOME/.claude/routing.md"
input=$(cat 2>/dev/null) || exit 0

get() {
  printf '%s' "$input" | "$PLUTIL" -extract "$1" raw -o - - 2>/dev/null
}

prompt=$(get prompt) || exit 0
[ -n "$prompt" ] || exit 0

# FirstMate crews, detected as agent-gate.sh does.
[ -n "${FM_TASK_ID:-}" ] && exit 0
cwd=$(get cwd)
[ -n "$cwd" ] && [ -f "$cwd/bin/fm-session-start.sh" ] && exit 0

# Leading blank lines don't change what the message is.
trimmed=$(printf '%s' "$prompt" | sed -e '/./,$!d')

case "$trimmed" in
  # T3 hands a child's report to its parent as a user turn.
  "Delegated task "*) exit 0 ;;
  # T3 opens a delegated child with this brief.
  "Act as the "*" sub-agent for this task"*)
    echo "You are a delegated child, a leaf: do not route, do not enter poteto-mode, and do not call delegate_task unless your brief names one."
    exit 0
    ;;
  /*|\$*) exit 0 ;;
  --*)
    echo "Route: SKIP. Carlos opted out of routing for this message: do exactly what it says, without poteto-mode or other skills."
    exit 0
    ;;
esac

# t3-pstack starts every child's brief with its worker.md pointer.
case "$trimmed" in
  "Read "*"worker.md before anything else"*)
    echo "You are a delegated child, a leaf: do not route, do not enter poteto-mode, and do not call delegate_task unless your brief names one."
    exit 0
    ;;
esac

[ -r "$RULES" ] || exit 0
cat "$RULES" 2>/dev/null || exit 0
if [ "${AGENT_ATTENDED:-0}" = 1 ]; then
  echo
  echo "Carlos is in this thread. For DEEP or TRIVIAL, give the route and your first steps, then ask with AskUserQuestion whether to go ahead before any edit."
fi
exit 0
