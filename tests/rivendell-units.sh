#!/usr/bin/env bash
# What Rivendell's warden and backup units run. The deploy gate checks out each
# commit it stages, so they must run .live's scripts, the commit the containers
# run, once a deploy has made it, and the checkout's before that.
#
#   bash tests/rivendell-units.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

templates="$REPO/ansible/roles/deploy/templates"
work="$(mktemp -d "${TMPDIR:-/tmp}/rivendell-units-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
repo="$work/rivendell"

# A checkout whose scripts say where they ran from, and python3 and bash
# stand-ins that run them, so the test needs neither.
mkdir -p "$work/bin"
printf '#!/bin/sh\nexec sh "$@"\n' > "$work/bin/python3"
chmod +x "$work/bin/python3"
checkout() {
  mkdir -p "$1/warden" "$1/scripts"
  printf 'WARDEN_STATE=%s/state\n' "$2" > "$1/rivendell.env"
  printf 'echo "warden $WARDEN_STATE $*"\n' > "$1/warden/warden.py"
  printf 'echo "backup %s $*"\n' "$2" > "$1/scripts/backup.sh"
}
checkout "$repo" checkout
for name in rivendell-warden rivendell-backup; do
  sed "s#{{ deploy_repo }}#$repo#g" "$templates/$name.j2" > "$work/$name"
done
run() { PATH="$work/bin:$PATH" sh "$work/$1" "${@:2}" 2>&1; }

section "rivendell-warden and rivendell-backup"
grep -q '{{' "$work/rivendell-warden" "$work/rivendell-backup" \
  && fail "the test fills in every template value" "$(grep '{{' "$work/rivendell-warden" "$work/rivendell-backup")"

out="$(run rivendell-warden tick)"
[ "$out" = "warden checkout/state tick" ] && pass "with no .live, the warden runs the checkout's" \
  || fail "with no .live, the warden runs the checkout's" "$out"
out="$(run rivendell-backup backup)"
[ "$out" = "backup checkout backup" ] && pass "with no .live, the backup runs the checkout's" \
  || fail "with no .live, the backup runs the checkout's" "$out"

# A folder at .live that isn't a checkout isn't what the containers run.
mkdir -p "$repo/.live"
out="$(run rivendell-warden tick)"
[ "$out" = "warden checkout/state tick" ] && pass "a .live with no .git is not run" \
  || fail "a .live with no .git is not run" "$out"

# A kill during the first deploy's git worktree add leaves .live/.git and no
# files; until the next deploy repairs it, the checkout's scripts still run.
echo "gitdir: $repo/.git/worktrees/live" > "$repo/.live/.git"
out="$(run rivendell-warden tick)"
[ "$out" = "warden checkout/state tick" ] && pass "a half-made .live with only .git is not run by the warden" \
  || fail "a half-made .live with only .git is not run by the warden" "$out"
out="$(run rivendell-backup backup)"
[ "$out" = "backup checkout backup" ] && pass "a half-made .live with only .git is not run by the backup" \
  || fail "a half-made .live with only .git is not run by the backup" "$out"

checkout "$repo/.live" live
out="$(run rivendell-warden tick)"
[ "$out" = "warden live/state tick" ] && pass "once a deploy made .live, the warden runs its scripts and settings" \
  || fail "once a deploy made .live, the warden runs its scripts and settings" "$out"
out="$(run rivendell-backup recover)"
[ "$out" = "backup live recover" ] && pass "once a deploy made .live, the backup runs its script" \
  || fail "once a deploy made .live, the backup runs its script" "$out"

section "the units run them"
for unit in rivendell-warden.service rivendell-backup.service rivendell-backup-check.service \
  rivendell-backup-recover.service; do
  exec_lines=$(grep -E '^Exec' "$templates/$unit.j2")
  direct=$(grep -F '{{ deploy_repo }}' <<< "$exec_lines")
  [ -n "$exec_lines" ] && [ -z "$direct" ] && pass "$unit runs no script from the checkout directly" \
    || fail "$unit runs no script from the checkout directly" "$exec_lines"
done
grep -q '^ExecStart=/usr/local/bin/rivendell-warden tick$' "$templates/rivendell-warden.service.j2" \
  && pass "the warden's unit ticks through rivendell-warden" \
  || fail "the warden's unit ticks through rivendell-warden" "$(grep '^Exec' "$templates/rivendell-warden.service.j2")"
for unit in rivendell-backup.service rivendell-backup-check.service rivendell-backup-recover.service; do
  bad=$(grep -E '^Exec' "$templates/$unit.j2" | grep -v '=/usr/local/bin/rivendell-backup ')
  [ -z "$bad" ] && pass "$unit goes through rivendell-backup" || fail "$unit goes through rivendell-backup" "$bad"
done

summary
