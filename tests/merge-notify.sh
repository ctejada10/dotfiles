#!/usr/bin/env bash
# The mini's merge notice: feeds the PostToolUse hook a Bash call and the
# pending merge guard-git.py records, with a stand-in gh and hermes on PATH
# and a throwaway home, and checks what it logs and sends.
#
#   bash tests/merge-notify.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_merge-notify.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/merge-notify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home/.local/bin" "$work/repo"
git init -q "$work/repo"
log="$work/home/.local/state/agent-merges.log"
sent="$work/sent"
sha=0123456789abcdef0123456789abcdef01234567

# The stand-in gh prints $work/pr.json for gh pr view, but only in the repo.
cat > "$work/bin/gh" <<EOF
#!/bin/sh
[ "\$1 \$2" = "pr view" ] || exit 1
[ "\$(pwd -P)" = "\$(cd "$work/repo" && pwd -P)" ] || { echo "not a git repository" >&2; exit 1; }
cat "$work/pr.json"
EOF
# The stand-in hermes, where the hook looks first, records each call's
# arguments and message, sleeps $work/hermes.sleep seconds if that exists,
# and exits with $work/hermes.status if it exists.
cat > "$work/home/.local/bin/hermes" <<EOF
#!/bin/sh
[ -f "$work/hermes.sleep" ] && sleep "\$(cat "$work/hermes.sleep")"
{ printf 'argv: %s\n' "\$*"; cat; printf '\n---\n'; } >> "$sent"
[ -f "$work/hermes.status" ] && exit "\$(cat "$work/hermes.status")"
exit 0
EOF
chmod +x "$work/bin/gh" "$work/home/.local/bin/hermes"
pending="$work/home/.local/state/agent-merge-pending"
mkdir -p "$work/elsewhere"

# reset <state>: a PR in that state, and nothing pending, logged or sent yet.
reset() {
  rm -rf "$log" "$sent" "$work/hermes.status" "$work/hermes.sleep" "$pending"
  jq -n --arg s "$1" --arg m "$sha" '{number: 12, title: "Add the parser", url: "https://github.com/ctejada10/scripts/pull/12",
    state: $s, mergeCommit: (if $s == "MERGED" then {oid: $m} else null end), headRefName: "feature"}' > "$work/pr.json"
}
# pend <tool_use_id> [cwd]: what guard-git.py records when it lets a merge through.
pend() {
  mkdir -p "$pending"
  jq -n --arg d "${2:-$work/repo}" --arg h "$sha" '{cwd: $d, repo: "ctejada10/scripts", head: $h}' > "$pending/$1.json"
}
# notify <tool_use_id, or ""> [command]: run the hook after that Bash call,
# which ran from a session whose folder is elsewhere; sets status.
notify() {
  jq -n --arg c "${2:-cd $work/repo && gh pr merge --squash --match-head-commit $sha}" --arg d "$work/elsewhere" --arg id "$1" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: "s-1"} + (if $id != "" then {tool_use_id: $id} else {} end)' \
    | HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" /usr/bin/python3 -B "$hook" >/dev/null 2>&1
  status=$?
}
calls() { [ -f "$sent" ] && grep -c '^argv: ' "$sent" || echo 0; }
lines() { [ -f "$log" ] && wc -l < "$log" | tr -d ' ' || echo 0; }

section "a merged PR"
reset MERGED
mkdir -p "$work/home/agent-drafts/scripts/feature"
printf 'MERGE %s\nThe diff renames a helper.\nTests cover it.\n' "$sha" > "$work/home/agent-drafts/scripts/feature/merge-verdict.txt"
pend t1; notify t1
[ "$status" -eq 0 ] && pass "exits 0" || fail "exits 0" "exit $status"
[ "$(calls)" -eq 1 ] && pass "sends one message, from the folder the merge ran in" || fail "sends one message, from the folder the merge ran in" "$(cat "$sent" 2>/dev/null)"
grep -qx 'argv: send --to telegram -q' "$sent" && pass "to Telegram, quietly" || fail "to Telegram, quietly" "$(cat "$sent")"
grep -qx 'Agent merged ctejada10/scripts#12: Add the parser' "$sent" && pass "names the PR" || fail "names the PR" "$(cat "$sent")"
grep -qx "${sha:0:12}" "$sent" && grep -qx 'https://github.com/ctejada10/scripts/pull/12' "$sent" \
  && pass "gives the merge SHA and the link" || fail "gives the merge SHA and the link" "$(cat "$sent")"
grep -qx 'The diff renames a helper.' "$sent" && grep -qx 'Tests cover it.' "$sent" && ! grep -q '^MERGE ' "$sent" \
  && pass "gives the reviewer's reasons" || fail "gives the reviewer's reasons" "$(cat "$sent")"
want=$(printf 'ctejada10/scripts\t12\t%s\tAdd the parser\ts-1\tsent' "$sha")
[ "$(lines)" -eq 1 ] && [ "$(cut -f2- "$log")" = "$want" ] && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$log" \
  && pass "logs the merge as sent" || fail "logs the merge as sent" "$(cat "$log" 2>/dev/null)"
[ ! -e "$pending/t1.json" ] && pass "removes the pending merge" || fail "removes the pending merge"
pend t2; notify t2
[ "$(calls)" -eq 1 ] && [ "$(lines)" -eq 1 ] && [ ! -e "$pending/t2.json" ] \
  && pass "a second run on the same merge sends nothing more" || fail "a second run on the same merge sends nothing more" "$(cat "$log")"
reset MERGED
mkdir -p "$work/home/agent-drafts/repo/feature"
printf 'MERGE %s\nFrom the folder name.\n' "$sha" > "$work/home/agent-drafts/repo/feature/merge-verdict.txt"
mv "$work/home/agent-drafts/scripts" "$work/scripts.off"
pend t3; notify t3
grep -qx 'From the folder name.' "$sent" && pass "reads a verdict under the main checkout's folder name" || fail "reads a verdict under the main checkout's folder name" "$(cat "$sent")"
rm -rf "$work/home/agent-drafts/repo"; mv "$work/scripts.off" "$work/home/agent-drafts/scripts"
reset MERGED
printf 'MERGE %s\n%0900d\n' "$sha" 0 > "$work/home/agent-drafts/scripts/feature/merge-verdict.txt"
pend t4; notify t4
body=$(sed -e '1d' -e '/^---$/d' "$sent")
[ "${#body}" -le 801 ] && pass "keeps the message to 800 characters" || fail "keeps the message to 800 characters" "${#body} characters"

section "only a merge guard-git.py let through"
reset MERGED
notify t5
[ "$status" -eq 0 ] && [ "$(calls)" -eq 0 ] && [ ! -f "$log" ] \
  && pass "a gh pr merge with nothing pending sends and logs nothing" || fail "a gh pr merge with nothing pending sends and logs nothing"
pend t6; notify ""
[ "$status" -eq 0 ] && [ "$(calls)" -eq 0 ] && [ -e "$pending/t6.json" ] \
  && pass "a payload with no tool_use_id sends nothing" || fail "a payload with no tool_use_id sends nothing"
mkdir -p "$work/home/.local/state"; jq -n --arg d "$work/repo" '{cwd: $d}' > "$work/home/.local/state/x.json"
notify '../x'
[ "$(calls)" -eq 0 ] && [ -e "$work/home/.local/state/x.json" ] \
  && pass "a tool_use_id that is a path reads and removes nothing" || fail "a tool_use_id that is a path reads and removes nothing"
reset MERGED
pend t7; notify t7 'gh pr view 12'
[ "$(calls)" -eq 1 ] && pass "acts on the pending file, whatever the command reads as" || fail "acts on the pending file, whatever the command reads as"
reset OPEN
pend t8; notify t8
[ "$status" -eq 0 ] && [ "$(calls)" -eq 0 ] && [ ! -f "$log" ] && [ ! -e "$pending/t8.json" ] \
  && pass "a PR still open sends and logs nothing, and the pending merge is removed" \
  || fail "a PR still open sends and logs nothing, and the pending merge is removed"
reset MERGED
pend t9 "$work/elsewhere"; notify t9
[ "$(calls)" -eq 0 ] && [ ! -f "$log" ] && [ ! -e "$pending/t9.json" ] \
  && pass "gh failing sends nothing, and the pending merge is removed" || fail "gh failing sends nothing, and the pending merge is removed"
mkdir -p "$pending"; printf 'not json' > "$pending/t10.json"; notify t10
[ "$status" -eq 0 ] && [ ! -e "$pending/t10.json" ] && pass "a pending file that isn't JSON is removed" || fail "a pending file that isn't JSON is removed"
printf 'not json' | HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" /usr/bin/python3 -B "$hook" >/dev/null 2>&1 \
  && pass "a payload that isn't JSON exits 0" || fail "a payload that isn't JSON exits 0"

section "hermes failing"
reset MERGED
printf '1' > "$work/hermes.status"
pend t11; notify t11
[ "$status" -eq 0 ] && pass "still exits 0" || fail "still exits 0" "exit $status"
[ "$(lines)" -eq 1 ] && cut -f7 "$log" | grep -qx 'notify-failed' \
  && pass "logs the merge once, as notify-failed" || fail "logs the merge once, as notify-failed" "$(cat "$log")"
rm "$work/hermes.status"
pend t12; notify t12
[ "$(calls)" -eq 2 ] && [ "$(lines)" -eq 2 ] && tail -n 1 "$log" | cut -f7 | grep -qx sent \
  && pass "a merge whose notice failed is sent on the next run" || fail "a merge whose notice failed is sent on the next run" "$(cat "$log")"
reset MERGED
mv "$work/home/.local/bin/hermes" "$work/hermes.off"
pend t13; notify t13
[ "$status" -eq 0 ] && cut -f7 "$log" | grep -qx 'notify-failed' \
  && pass "no hermes at all logs notify-failed" || fail "no hermes at all logs notify-failed" "$(cat "$log")"
mv "$work/hermes.off" "$work/home/.local/bin/hermes"
reset MERGED
printf '25' > "$work/hermes.sleep"
pend t14; began=$SECONDS; notify t14; took=$((SECONDS - began))
[ "$took" -lt 20 ] && cut -f7 "$log" | grep -qx 'notify-failed' \
  && pass "a hermes that hangs is given up on after 10 seconds ($took s)" || fail "a hermes that hangs is given up on after 10 seconds" "$took s: $(cat "$log" 2>/dev/null)"

section "two notices at once"
reset MERGED
printf '1' > "$work/hermes.sleep"
pend a; pend b
notify a & notify b & wait
[ "$(calls)" -eq 1 ] && [ "$(lines)" -eq 1 ] \
  && pass "send one message between them" || fail "send one message between them" "$(calls) sent: $(cat "$log" 2>/dev/null)"

summary
