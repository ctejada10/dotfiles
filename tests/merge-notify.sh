#!/usr/bin/env bash
# The mini's merge notice: feeds the PostToolUse hook a Bash call, with a
# stand-in gh and hermes on PATH and a throwaway home, and checks what it logs
# and sends.
#
#   bash tests/merge-notify.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_merge-notify.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/merge-notify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home/.local/bin" "$work/repo"
log="$work/home/.local/state/agent-merges.log"
sent="$work/sent"
sha=0123456789abcdef0123456789abcdef01234567

# The stand-in gh prints $work/pr.json for gh pr view.
cat > "$work/bin/gh" <<EOF
#!/bin/sh
[ "\$1 \$2" = "pr view" ] || exit 1
cat "$work/pr.json"
EOF
# The stand-in hermes, where the hook looks first, records each call's
# arguments and message, and exits with $work/hermes.status if it exists.
cat > "$work/home/.local/bin/hermes" <<EOF
#!/bin/sh
{ printf 'argv: %s\n' "\$*"; cat; printf '\n---\n'; } >> "$sent"
[ -f "$work/hermes.status" ] && exit "\$(cat "$work/hermes.status")"
exit 0
EOF
chmod +x "$work/bin/gh" "$work/home/.local/bin/hermes"

# reset <state>: a PR in that state, and nothing logged or sent yet.
reset() {
  rm -f "$log" "$sent" "$work/hermes.status"
  jq -n --arg s "$1" --arg m "$sha" '{number: 12, title: "Add the parser", url: "https://github.com/ctejada10/scripts/pull/12",
    state: $s, mergeCommit: (if $s == "MERGED" then {oid: $m} else null end), headRefName: "feature"}' > "$work/pr.json"
}
# notify <command>: run the hook after that Bash call; sets status.
notify() {
  jq -n --arg c "$1" --arg d "$work/repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: "s-1"}' \
    | HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" /usr/bin/python3 -B "$hook" >/dev/null 2>&1
  status=$?
}
calls() { [ -f "$sent" ] && grep -c '^argv: ' "$sent" || echo 0; }

section "a merged PR"
reset MERGED
mkdir -p "$work/home/agent-drafts/scripts/feature"
printf 'MERGE %s\nThe diff renames a helper.\nTests cover it.\n' "$sha" > "$work/home/agent-drafts/scripts/feature/merge-verdict.txt"
notify "gh pr merge --squash --match-head-commit $sha"
[ "$status" -eq 0 ] && pass "exits 0" || fail "exits 0" "exit $status"
[ "$(calls)" -eq 1 ] && pass "sends one message" || fail "sends one message" "$(cat "$sent" 2>/dev/null)"
grep -qx 'argv: send --to telegram -q' "$sent" && pass "to Telegram, quietly" || fail "to Telegram, quietly" "$(cat "$sent")"
grep -qx 'Agent merged ctejada10/scripts#12: Add the parser' "$sent" && pass "names the PR" || fail "names the PR" "$(cat "$sent")"
grep -qx "${sha:0:12}" "$sent" && grep -qx 'https://github.com/ctejada10/scripts/pull/12' "$sent" \
  && pass "gives the merge SHA and the link" || fail "gives the merge SHA and the link" "$(cat "$sent")"
grep -qx 'The diff renames a helper.' "$sent" && grep -qx 'Tests cover it.' "$sent" && ! grep -q '^MERGE ' "$sent" \
  && pass "gives the reviewer's reasons" || fail "gives the reviewer's reasons" "$(cat "$sent")"
want=$(printf 'ctejada10/scripts\t12\t%s\tAdd the parser\ts-1' "$sha")
[ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] && [ "$(cut -f2- "$log")" = "$want" ] && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$log" \
  && pass "logs the merge" || fail "logs the merge" "$(cat "$log" 2>/dev/null)"
notify "gh pr merge --squash --match-head-commit $sha"
[ "$(calls)" -eq 1 ] && [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] \
  && pass "a second run on the same merge sends nothing more" || fail "a second run on the same merge sends nothing more" "$(cat "$log")"
reset MERGED
printf 'MERGE %s\n%0900d\n' "$sha" 0 > "$work/home/agent-drafts/scripts/feature/merge-verdict.txt"
notify "cd $work/repo && gh pr merge --squash --match-head-commit $sha"
body=$(sed -e '1d' -e '/^---$/d' "$sent")
[ "${#body}" -le 801 ] && pass "keeps the message to 800 characters" || fail "keeps the message to 800 characters" "${#body} characters"

section "no merge"
reset OPEN
notify "gh pr merge --squash --match-head-commit $sha"
[ "$status" -eq 0 ] && [ "$(calls)" -eq 0 ] && [ ! -f "$log" ] \
  && pass "a PR still open sends and logs nothing" || fail "a PR still open sends and logs nothing"
reset MERGED
for cmd in 'gh pr view 12' 'git merge --ff-only origin/main' 'gh pr ready'; do
  notify "$cmd"
  [ "$status" -eq 0 ] && [ "$(calls)" -eq 0 ] && [ ! -f "$log" ] \
    && pass "$cmd sends and logs nothing" || fail "$cmd sends and logs nothing"
done
printf 'not json' | HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" /usr/bin/python3 -B "$hook" >/dev/null 2>&1 \
  && pass "a payload that isn't JSON exits 0" || fail "a payload that isn't JSON exits 0"

section "hermes failing"
reset MERGED
printf '1' > "$work/hermes.status"
notify "gh pr merge --squash --match-head-commit $sha"
[ "$status" -eq 0 ] && pass "still exits 0" || fail "still exits 0" "exit $status"
[ "$(wc -l < "$log" | tr -d ' ')" -eq 2 ] && tail -n 1 "$log" | grep -q 'notify-failed' \
  && pass "logs the merge and notify-failed" || fail "logs the merge and notify-failed" "$(cat "$log")"
reset MERGED
mv "$work/home/.local/bin/hermes" "$work/hermes.off"
notify "gh pr merge --squash --match-head-commit $sha"
[ "$status" -eq 0 ] && tail -n 1 "$log" | grep -q 'notify-failed' \
  && pass "no hermes at all logs notify-failed" || fail "no hermes at all logs notify-failed" "$(cat "$log")"

summary
