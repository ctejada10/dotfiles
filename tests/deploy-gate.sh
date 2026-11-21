#!/usr/bin/env bash
# The deploy gate against a throwaway repo. A process that deploy.sh leaves
# running, as 1Password's op leaves its cache daemon, must not keep the gate's
# lock and block every later deploy. Needs flock and GNU tee, as on the servers
# and in CI; elsewhere it says so and skips.
#
#   bash tests/deploy-gate.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

section "the deploy gate"
if ! command -v flock >/dev/null || ! tee -p /dev/null </dev/null 2>/dev/null; then
  echo "  skip  needs flock and GNU tee (Linux)"
  summary
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/deploy-gate-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git() { command git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main "$@"; }

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/src" 2>/dev/null
mkdir -p "$work/src/scripts"
cat > "$work/src/scripts/deploy.sh" <<'EOF'
#!/usr/bin/env bash
nohup sleep 20 >/dev/null 2>&1 &
echo "deployed $*"
EOF
chmod +x "$work/src/scripts/deploy.sh"
git -C "$work/src" add scripts/deploy.sh
git -C "$work/src" commit -qm deploy
git -C "$work/src" push -q origin main
git clone -q "$work/origin.git" "$work/repo"
sha="$(git -C "$work/repo" rev-parse HEAD)"

# The template's values, a lock in the sandbox, and short waits for it instead
# of half an hour and 10 seconds. $1: deploy_forward_only.
render() {
  sed -e "s#{{ deploy_repo | quote }}#$work/repo#" \
    -e "s#{{ deploy_branch | quote }}#main#" \
    -e "s#{{ deploy_forward_only | ternary('true', 'false') }}#$1#" \
    -e "s#^lock=.*#lock=$work/gate.lock#" \
    -e "s#flock -w 1800#flock -w 2#" \
    -e "s#flock -w 10 #flock -w 3 #" \
    "$REPO/ansible/roles/deploy/templates/deploy-gate.j2"
}
render false > "$work/gate"
gate() { XDG_STATE_HOME="$work/state" bash "$work/gate" deploy "$sha" 2>&1; }
apply() { XDG_STATE_HOME="$work/state" bash "$work/gate" apply "$sha" 2>&1; }
ssh_apply() { SSH_ORIGINAL_COMMAND="apply $sha" XDG_STATE_HOME="$work/state" bash "$work/gate" 2>&1; }

out="$(gate)" && grep -q deployed <<< "$out" \
  && pass "runs the commit's deploy.sh" || fail "runs the commit's deploy.sh" "$out"
out="$(gate)" && grep -q deployed <<< "$out" \
  && pass "a process deploy.sh left running doesn't hold the lock" \
  || fail "a process deploy.sh left running doesn't hold the lock" "$out"
out="$(gate)" && grep -qx "deployed $sha" <<< "$out" \
  && pass "deploy hands deploy.sh the sha alone, to stage it" \
  || fail "deploy hands deploy.sh the sha alone, to stage it" "$out"
out="$(apply)" && grep -qx "deployed --apply $sha" <<< "$out" \
  && pass "apply, from the server, runs deploy.sh --apply" \
  || fail "apply, from the server, runs deploy.sh --apply" "$out"
out="$(ssh_apply)"; rc=$?
[ "$rc" != 0 ] && ! grep -q deployed <<< "$out" \
  && pass "the restricted key can't ask for apply" \
  || fail "the restricted key can't ask for apply" "$out"

section "the deploy gate, forward only, with two revisions"
# Rivendell's case: deploy.sh <sha> only stages, the checkout must stay on what
# the containers run, and the checked-out commit's scripts/deploy-hook vets each
# request before the requested commit's own code runs. Every deploy.sh here
# notes in $work/ran that it ran, so a refused commit's code is seen not to.
rm -rf "$work/origin.git" "$work/src" "$work/repo" "$work/state"
git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/src" 2>/dev/null
mkdir -p "$work/src/scripts"
# deploy.sh as Rivendell's: <sha> stages it (exit 90, nothing applied) unless
# STUB_STAGE_FAILS (91, nothing changed) or STUB_APPLY_NOW (applies it, 0);
# --apply <sha> applies it. The pending commit is in $STUB_STATE/pending.
cat > "$work/src/scripts/deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(git rev-parse HEAD) $*" >> "$STUB_RAN"
[ -z "${STUB_SLOW:-}" ] || sleep "$STUB_SLOW"
# The gate is this script's parent: a stop sent to the gate alone.
[ -z "${STUB_KILL_GATE:-}" ] || { kill "-$STUB_KILL_GATE" "$PPID"; sleep 0.3; }
if [ "$1" = --apply ]; then echo "applied $2"; : > "$STUB_STATE/pending"; exit 0; fi
[ -z "${STUB_STAGE_FAILS:-}" ] || exit 91
[ -z "${STUB_APPLY_NOW:-}" ] || { echo "applied $1"; exit 0; }
echo "$1" > "$STUB_STATE/pending"
echo "staged $1"
exit 90
EOF
chmod +x "$work/src/scripts/deploy.sh"
commit() { git -C "$work/src" add -A && git -C "$work/src" commit -qm "$1" && git -C "$work/src" rev-parse HEAD; }
first=$(commit "the first commit")
echo old > "$work/src/old"
old=$(commit "an old commit, with no deploy-hook")
# deploy-hook as Rivendell's: vet refuses an apply of anything but the pending
# commit, and a deploy of one older than it; refused notes the report.
cat > "$work/src/scripts/deploy-hook" <<'EOF'
#!/usr/bin/env bash
pending=$(cat "$STUB_STATE/pending" 2>/dev/null)
case $1 in
  vet)
    if [ "$2" = apply ] && [ "$3" != "$pending" ]; then echo "$3 is no longer the pending commit"; exit 1; fi
    if [ "$2" = deploy ] && [ -n "$pending" ] && [ "$3" != "$pending" ] && git merge-base --is-ancestor "$3" "$pending"; then
      echo "$3 is older than the pending $pending"; exit 1
    fi ;;
  refused) echo "$2 $3" >> "$STUB_STATE/reported" ;;
esac
EOF
chmod +x "$work/src/scripts/deploy-hook"
deployed=$(commit "the deployed commit")
# A merged side branch: its commit is on main, but not on main's own line.
git -C "$work/src" checkout -q -b side "$old"
echo side > "$work/src/side"
side=$(commit "a commit of a merged branch")
git -C "$work/src" checkout -q main
git -C "$work/src" merge -q --no-ff -m "merge side" side
echo two > "$work/src/two"
second=$(commit "the second revision")
echo three > "$work/src/three"
third=$(commit "the third revision")
git -C "$work/src" push -q origin HEAD
git clone -q "$work/origin.git" "$work/repo"
git -C "$work/repo" checkout -q "$deployed"
mkdir -p "$work/state/stub"
: > "$work/ran"
render true > "$work/gate"
export STUB_RAN="$work/ran" STUB_STATE="$work/state/stub"
checked_out() { git -C "$work/repo" rev-parse HEAD; }
ask() { XDG_STATE_HOME="$work/state" bash "$work/gate" "$@" 2>&1; }
subject() { git -C "$work/src" log -1 --format=%s "$1"; }

out="$(ask deploy "$second")"; rc=$?
[ "$rc" = 0 ] && grep -q "staged $second" <<< "$out" && [ "$(checked_out)" = "$deployed" ] \
  && pass "a staged commit leaves the deployed one checked out, and GitHub sees success" \
  || fail "a staged commit leaves the deployed one checked out, and GitHub sees success" "rc=$rc $out"

for refused in "$old" "$side"; do
  : > "$work/ran"
  out="$(ask deploy "$refused")"; rc=$?
  [ "$rc" != 0 ] && [ ! -s "$work/ran" ] && [ "$(checked_out)" = "$deployed" ] \
    && pass "refuses $(subject "$refused") before its code runs" \
    || fail "refuses $(subject "$refused") before its code runs" "rc=$rc ran: $(cat "$work/ran") $out"
done
grep -q "^$old .*older than" "$STUB_STATE/reported" 2>/dev/null && grep -q "^$side " "$STUB_STATE/reported" \
  && pass "reports each refused GitHub request through the checked-out commit's hook" \
  || fail "reports each refused GitHub request through the checked-out commit's hook" \
    "$(cat "$STUB_STATE/reported" 2>/dev/null)"

out="$(STUB_STAGE_FAILS=1 ask deploy "$third")"; rc=$?
[ "$rc" = 1 ] && [ "$(checked_out)" = "$deployed" ] \
  && pass "a stage that fails leaves the deployed one checked out" \
  || fail "a stage that fails leaves the deployed one checked out" "rc=$rc $out"

# The warden read pending=second and asks to apply it while GitHub's newer stage
# of third holds the lock: by the time the apply gets the lock, second is stale.
echo "$second" > "$STUB_STATE/pending"
: > "$work/ran"
STUB_SLOW=1 ask deploy "$third" > "$work/stage.out" &
sleep 0.3
out="$(ask apply "$second")"; rc=$?
wait
[ "$rc" = 1 ] && ! grep -q -- --apply "$work/ran" && [ "$(checked_out)" = "$deployed" ] \
  && [ "$(cat "$STUB_STATE/pending")" = "$third" ] \
  && pass "a queued apply overtaken by a newer stage is refused" \
  || fail "a queued apply overtaken by a newer stage is refused" "rc=$rc ran: $(cat "$work/ran") $out"
grep -q "^$second " "$STUB_STATE/reported" \
  && fail "leaves the warden's refused applies to the warden to report" "$(cat "$STUB_STATE/reported")" \
  || pass "leaves the warden's refused applies to the warden to report"

out="$(ask apply "$third")"; rc=$?
[ "$rc" = 0 ] && grep -q "applied $third" <<< "$out" && [ "$(checked_out)" = "$third" ] \
  && pass "an apply of the pending commit runs deploy.sh --apply and leaves it checked out" \
  || fail "an apply of the pending commit runs deploy.sh --apply and leaves it checked out" "rc=$rc $out"

flock "$work/gate.lock" sleep 5 &
holder=$!
sleep 0.3
out="$(ask apply "$third")"; rc=$?
kill "$holder" 2>/dev/null; wait
[ "$rc" = 75 ] && pass "an apply that can't get the lock soon exits 75, to be asked again" \
  || fail "an apply that can't get the lock soon exits 75, to be asked again" "rc=$rc $out"

# A gate stopped while it stages must leave the deployed commit checked out.
# logger is how the gate says it is about to run deploy.sh; this one stops the
# gate right then, after its checkout. STUB_KILL_GATE in deploy.sh stops it
# while deploy.sh runs instead.
mkdir -p "$work/bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in *" -- deploying "*) [ -z "${STUB_STOP_AT_LOG:-}" ] || kill "-$STUB_STOP_AT_LOG" "$PPID" ;; esac' \
  > "$work/bin/logger"
chmod +x "$work/bin/logger"
for signal in TERM INT HUP; do
  git -C "$work/repo" checkout -q "$deployed"
  echo "$second" > "$STUB_STATE/pending"
  : > "$work/ran"
  out="$(PATH="$work/bin:$PATH" STUB_STOP_AT_LOG=$signal ask deploy "$third")"; rc=$?
  [ "$rc" != 0 ] && [ "$(checked_out)" = "$deployed" ] && [ ! -s "$work/ran" ] \
    && pass "a gate stopped by $signal after its checkout of a stage puts the deployed commit back" \
    || fail "a gate stopped by $signal after its checkout of a stage puts the deployed commit back" \
      "rc=$rc checked out $(checked_out) ran: $(cat "$work/ran") $out"
done
git -C "$work/repo" checkout -q "$deployed"
out="$(STUB_KILL_GATE=TERM ask deploy "$third")"; rc=$?
[ "$rc" = 0 ] && [ "$(checked_out)" = "$deployed" ] \
  && pass "a gate stopped while deploy.sh stages waits for it and puts the deployed commit back" \
  || fail "a gate stopped while deploy.sh stages waits for it and puts the deployed commit back" \
    "rc=$rc checked out $(checked_out) $out"
git -C "$work/repo" checkout -q "$deployed"
out="$(STUB_KILL_GATE=TERM STUB_APPLY_NOW=1 ask deploy "$third")"; rc=$?
[ "$rc" = 0 ] && [ "$(checked_out)" = "$third" ] \
  && pass "a gate stopped while deploy.sh applies at once keeps the applied commit checked out" \
  || fail "a gate stopped while deploy.sh applies at once keeps the applied commit checked out" \
    "rc=$rc checked out $(checked_out) $out"
# An apply's checkout is deploy.sh --apply's to decide, by its exit status.
echo "$third" > "$STUB_STATE/pending"
git -C "$work/repo" checkout -q "$deployed"
out="$(PATH="$work/bin:$PATH" STUB_STOP_AT_LOG=TERM ask apply "$third")"; rc=$?
[ "$(checked_out)" = "$third" ] \
  && pass "a gate stopped after its checkout of an apply leaves that commit checked out" \
  || fail "a gate stopped after its checkout of an apply leaves that commit checked out" \
    "rc=$rc checked out $(checked_out) $out"
git -C "$work/repo" checkout -q "$deployed"

# Until a commit with a deploy-hook is deployed, the gate's own checks still
# hold, and a commit's deploy.sh that applies at once leaves it checked out.
git -C "$work/repo" checkout -q "$old"
: > "$STUB_STATE/pending"
for refused in "$first" "$side"; do
  : > "$work/ran"
  out="$(ask deploy "$refused")"; rc=$?
  [ "$rc" != 0 ] && [ ! -s "$work/ran" ] && [ "$(checked_out)" = "$old" ] \
    && pass "without a hook, still refuses $(subject "$refused")" \
    || fail "without a hook, still refuses $(subject "$refused")" "rc=$rc ran: $(cat "$work/ran") $out"
done
out="$(STUB_APPLY_NOW=1 ask deploy "$third")"; rc=$?
[ "$rc" = 0 ] && grep -q "applied $third" <<< "$out" && [ "$(checked_out)" = "$third" ] \
  && pass "a deploy.sh that applied at once leaves its commit checked out" \
  || fail "a deploy.sh that applied at once leaves its commit checked out" "rc=$rc $out"

summary
