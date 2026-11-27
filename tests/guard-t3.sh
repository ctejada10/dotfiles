#!/usr/bin/env bash
# The mini's guard on T3 Code's pull-request tools: feeds it the calls T3's
# MCP server takes and checks which it blocks. Runs Python with -B so no
# bytecode cache lands in the source tree.
#
#   bash tests/guard-t3.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_guard-t3.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/guard-t3.XXXXXX")"
trap 'rm -rf "$work"' EXIT

outcome() {
  case "$1" in
    0) echo allowed ;;
    2) echo blocked ;;
    *) echo "a crash (exit $1), which lets the call through" ;;
  esac
}

# call <blocked|allowed> <tool name> <input JSON> [hook path] [label]
call() {
  local want="$1" tool="$2" input="$3" path="${4:-$hook}" got label
  printf '%s' "$(jq -cn --arg t "$tool" --argjson i "$input" '{tool_name: $t, tool_input: $i}')" \
    | /usr/bin/python3 -B "$path" 2>"$work/err"
  got=$(outcome $?)
  label="${5:-$want: $tool $input}"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "got $got: $(cat "$work/err")"; fi
}
t='mcp__t3-code__'

section "merges and reviews never go through T3"
call blocked "${t}pull_request_merge" '{"expectedHeadSha": "abc1234"}'
call blocked "${t}pull_request_merge" '{"expectedHeadSha": "abc1234", "auto": true}'
call blocked "mcp__t3_code__pull_request_merge" '{"expectedHeadSha": "abc1234"}'
call blocked "mcp__t3-code-direct__pull_request_merge" '{"expectedHeadSha": "abc1234"}'
call blocked "mcp__T3-Code__pull_request_merge" '{"expectedHeadSha": "abc1234"}'
call blocked "${t}pull_request_review" '{"verdict": "approve", "expectedHeadSha": "abc1234"}'
call blocked "${t}pull_request_review" '{"verdict": "comment", "body": "looks fine"}'

section "drafts only"
call allowed "${t}pull_request_create" '{"title": "Keep tabs", "body": "## Why\nx", "draft": true}'
call blocked "${t}pull_request_create" '{"title": "Keep tabs", "body": "x"}'
call blocked "${t}pull_request_create" '{"title": "Keep tabs", "body": "x", "draft": false}'
call blocked "${t}pull_request_create" '{"title": "Keep tabs", "body": "x", "draft": "true"}'
call allowed "${t}pull_request_update" '{"ready": false}'
call blocked "${t}pull_request_update" '{"ready": true}'
call blocked "${t}pull_request_update" '{"body": "x", "ready": true}'
call allowed "${t}pull_request_update" '{"title": "Keep tabs in the parser", "body": "## Why\ny"}'
call allowed "${t}pull_request_update" '{"state": "closed"}'
call allowed "${t}pull_request_update" '{"addLabels": ["bug"]}'

section "only Carlos requests a review"
call blocked "${t}pull_request_update" '{"requestReviewers": ["copilot-pull-request-reviewer"]}'
call blocked "${t}pull_request_update" '{"requestReviewers": ["someone"]}'
call allowed "${t}pull_request_update" '{"requestReviewers": []}'

section "thread replies, not PR comments"
call allowed "${t}pull_request_respond" '{"reviewThreadId": "PRRT_1", "body": "Fixed in abc1234."}'
call allowed "${t}pull_request_respond" '{"reviewThreadId": "PRRT_1", "resolved": true}'
call blocked "${t}pull_request_respond" '{"body": "Ready for review."}'
call blocked "${t}pull_request_respond" '{"reviewThreadId": "", "body": "x"}'

section "no AI credit"
call blocked "${t}pull_request_create" '{"title": "Keep tabs", "body": "x\n\nCo-Authored-By: Claude <noreply@anthropic.com>", "draft": true}'
call blocked "${t}pull_request_update" '{"body": "x\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"}'
call blocked "${t}pull_request_respond" '{"reviewThreadId": "PRRT_1", "body": "Fixed. https://claude.ai/code/session_01ABC"}'

section "everything else passes"
call allowed "${t}pull_request_read" '{"sections": ["checks"]}'
call allowed "${t}ci_logs" '{}'
call allowed "${t}ci_rerun" '{}'
call allowed "${t}watch_pull_request" '{}'
call allowed "${t}link_pull_request" '{"number": 12}'
call allowed "mcp__github__merge_pull_request" '{"pull_number": 12}'
call allowed "Bash" '{"command": "gh pr view"}'

section "what it can't read blocks"
out=$(printf 'not json' | /usr/bin/python3 -B "$hook" 2>&1); status=$?
[ "$status" -eq 2 ] && pass "a payload that isn't JSON" || fail "a payload that isn't JSON" "exit $status: $out"
call blocked "${t}pull_request_update" '"ready"' "$hook" "blocked: an input that isn't an object"
mkdir -p "$work/alone"
cp "$hook" "$work/alone/guard-t3.py"
call blocked "${t}pull_request_create" '{"title": "x", "body": "y", "draft": true}' "$work/alone/guard-t3.py" \
  "blocked: guard-git.py missing, so the AI-credit check can't run"
mkdir -p "$work/deployed"
cp "$hook" "$work/deployed/guard-t3.py"
cp "$REPO/home/dot_claude/hooks/executable_guard-git.py" "$work/deployed/guard-git.py"
call allowed "${t}pull_request_create" '{"title": "x", "body": "y", "draft": true}' "$work/deployed/guard-t3.py" \
  "allowed: deployed under its live names"

summary
