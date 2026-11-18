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

# The template's values, a lock in the sandbox, and a 2-second wait for it
# instead of half an hour.
sed -e "s#{{ deploy_repo | quote }}#$work/repo#" \
  -e "s#{{ deploy_branch | quote }}#main#" \
  -e "s#^lock=.*#lock=$work/gate.lock#" \
  -e "s#flock -w 1800#flock -w 2#" \
  "$REPO/ansible/roles/deploy/templates/deploy-gate.j2" > "$work/gate"
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

summary
