#!/bin/bash
# UserPromptSubmit hook, on the mini only. t3-pstack's own hook tells a chat
# once, at session start, when to enter poteto-mode, and the reminder fades in
# a long thread. This one adds the route card at the top of ~/.claude/routing.md
# to every message Carlos sends, so deep work goes through poteto-mode by
# default. The card is short on purpose: hook text stays in the conversation,
# so a long thread carries one copy per message. It tells the agent to read
# the whole file once per thread.
#
# What it adds to the message:
#   a delegated child's brief          a reminder that it is a leaf, and for a
#                                      review child a line that it edits
#                                      nothing (agent-gate.sh enforces it)
#   a child's report to its parent     nothing
#   a FirstMate crew                   nothing: its brief decides
#   a slash command or $skill          nothing: Carlos chose the skill
#   a message starting with --         the opt-out, in one line
#   anything else                      the route card, plus, when attended, a
#                                      line to confirm the route first
#
# A review child is one whose brief has a "ROLE: review" line or that T3
# opened as its review sub-agent. The hook marks its session in
# ~/.local/state/dotfiles/review-children, and agent-gate.sh then refuses
# its Edit, Write, MultiEdit and NotebookEdit calls.
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

LEAF="You are a delegated child, a leaf: do not route, do not enter poteto-mode, and do not call delegate_task unless your brief names one."
REVIEW="Your role is review: edit no files. Report what you find and change nothing; the Edit and Write tools are refused in this session."

# mark_review: records this session as a review child, if its brief says so.
mark_review() {
  local role session dir
  role=no
  case "$trimmed" in
    "Act as the review sub-agent"*|"Act as the reviewer sub-agent"*) role=yes ;;
  esac
  printf '%s\n' "$trimmed" | grep -Eiq '^ROLE:[[:space:]]*review(er)?([^a-z]|$)' && role=yes
  [ "$role" = yes ] || return 1
  session=$(get session_id) || return 0
  case "$session" in
    ""|*[!A-Za-z0-9_-]*) return 0 ;;
  esac
  dir="$HOME/.local/state/dotfiles/review-children"
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 0
  find "$dir" -type f -mtime +7 -delete 2>/dev/null
  : > "$dir/$session" 2>/dev/null
  return 0
}

child() {
  echo "$LEAF"
  mark_review && echo "$REVIEW"
  exit 0
}

case "$trimmed" in
  # T3 hands a child's report to its parent as a user turn.
  "Delegated task "*) exit 0 ;;
  # T3 opens a delegated child with this brief.
  "Act as the "*" sub-agent for this task"*) child ;;
  # A brief written in routing.md's format, with no pointer above it.
  "BRIEF FOR:"*) child ;;
  /*|\$*) exit 0 ;;
  --*)
    echo "Route: SKIP. Carlos opted out of routing for this message: do exactly what it says, without poteto-mode or other skills."
    exit 0
    ;;
esac

# t3-pstack starts every child's brief with its worker.md pointer.
case "$trimmed" in
  "Read "*"worker.md before anything else"*) child ;;
esac

[ -r "$RULES" ] || exit 0
# The card between the route-card markers. Without them, the whole file, so a
# bad edit to routing.md never drops the routing.
card=$(sed -n '/^<!-- route-card:start -->$/,/^<!-- route-card:end -->$/p' "$RULES" 2>/dev/null | sed '1d;$d')
if [ -n "$card" ]; then
  printf '%s\n' "$card"
else
  cat "$RULES" 2>/dev/null || exit 0
fi
if [ "${AGENT_ATTENDED:-0}" = 1 ]; then
  echo
  echo "Carlos is in this thread. For DEEP or TRIVIAL, give the route and your first steps, then ask with AskUserQuestion whether to go ahead before any edit."
fi
exit 0
