#!/usr/bin/env bash
# The mini's snapshot job, repo-snapshots, in throwaway repos: a fake HOME
# with a ~/src of clones and a stand-in Dropbox folder, an isolated git
# config, a git shim that records every git command the job runs and can cut
# short the bundles it writes, an ls shim that can refuse a folder as macOS
# does, and a logger shim so nothing reaches the system log. Each run stands
# for a day of its own, so one test covers several Sundays. Last, the apply
# script that loads the job, with a stand-in launchctl.
#
#   bash tests/repo-snapshots.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

# The job runs on the mini only, and some cases lock a folder with chflags.
if [ "$(uname)" != Darwin ]; then
  echo "repo-snapshots: the job runs on the mini only; nothing to check here"
  exit 0
fi

JOB="$REPO/home/dot_local/bin/executable_repo-snapshots"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/repo-snapshots.XXXXXX")" && pwd -P)"
# Some cases lock a folder; unlock it so the sandbox can go.
trap 'chflags -R nouchg "$T" 2>/dev/null; chmod -R u+rwx "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
REALGIT=$(command -v git)
mkdir -p "$T/bin" "$T/remote" "$T/tmp"
cd "$T" || exit 1
export HOME="$T/home" TMPDIR="$T/tmp"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
unset GIT_DIR GIT_WORK_TREE
cat >"$GIT_CONFIG_GLOBAL" <<EOF
[user]
    name = Test
    email = test@example.com
[init]
    defaultBranch = main
[protocol "file"]
    allow = always
EOF

# git: records each command. With corrupt-bundles there, it cuts the last
# bytes off each bundle that git bundle create wrote and exits 0, as a disk
# or sync fault might leave one.
cat >"$T/bin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/git-calls.log"
"$REALGIT" "\$@"
rc=\$?
if [ "\$rc" = 0 ] && [ -e "$T/corrupt-bundles" ]; then
  prev="" next="" out=""
  for a in "\$@"; do
    if [ "\$next" = 1 ]; then
      case \$a in -*) ;; *) out=\$a; break ;; esac
    elif [ "\$prev" = bundle ] && [ "\$a" = create ]; then
      next=1
    fi
    prev=\$a
  done
  if [ -n "\$out" ] && [ -f "\$out" ]; then
    head -c "\$((\$(wc -c <"\$out") - 10))" "\$out" >"\$out.cut" && mv -f "\$out.cut" "\$out"
  fi
fi
exit "\$rc"
EOF
# ls: with deny-ls there, listing the folder it names fails as macOS fails
# it for a job it keeps out of Dropbox's folder.
cat >"$T/bin/ls" <<EOF
#!/bin/bash
if [ -e "$T/deny-ls" ]; then
  for a in "\$@"; do
    if [ "\$a" = "\$(cat "$T/deny-ls")" ]; then
      echo "ls: \$a: Operation not permitted" >&2
      exit 1
    fi
  done
fi
exec /bin/ls "\$@"
EOF
cat >"$T/bin/logger" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/logger.log"
EOF
chmod +x "$T/bin/git" "$T/bin/ls" "$T/bin/logger"
: >"$T/git-calls.log"
: >"$T/logger.log"
REPO_SNAPSHOTS_PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$REALGIT")"
REPO_SNAPSHOTS_GIT="$T/bin/git"
export REPO_SNAPSHOTS_PATH REPO_SNAPSHOTS_GIT

SRC="$HOME/src"
DBX="$HOME/Library/CloudStorage/Dropbox"
BK="$DBX/backups"
SNAP="$BK/repositories/snapshots"
A="$SNAP/alpha"
LOGS="$HOME/Library/Logs/repo-snapshots"
ATT="$LOGS/attention.txt"
# Folders in Dropbox the job must never touch: another folder in backups, and
# the repos' old home.
mkdir -p "$SRC" "$BK/other" "$DBX/repositories/old"
echo keep >"$BK/other/file"
echo keep >"$DBX/repositories/old/file"

# The exact attention lines, less the path each starts with.
KICK="macOS hasn't let the job into Dropbox's folder (Operation not permitted), so the run stopped; give /bin/bash Full Disk Access in System Settings > Privacy & Security, then run launchctl kickstart gui/\$(id -u)/com.carlosetejada.repo-snapshots"
NOBACKUPS="not there, so no repo was snapshotted; in Dropbox's Preferences > Sync, under Select folders to sync to this Mac, open it and tick only repositories inside it, rather than making it by hand, which would give a conflicting copy"

commit() { (cd "$1" && echo "$2" >>"f-$2.txt" && git add "f-$2.txt" && git commit -q -m "$2"); }

# alpha: a clone with a remote, a feature branch, a tag, a stash, and an
# untracked .env.
git init -q --bare "$T/remote/alpha.git"
git clone -q "$T/remote/alpha.git" "$T/seed" 2>/dev/null
commit "$T/seed" base
git -C "$T/seed" push -q origin main 2>/dev/null
git clone -q "$T/remote/alpha.git" "$SRC/alpha" 2>/dev/null
git -C "$SRC/alpha" switch -q -c feature
commit "$SRC/alpha" feature
git -C "$SRC/alpha" switch -q main
git -C "$SRC/alpha" tag v1
echo wip >>"$SRC/alpha/f-base.txt"
git -C "$SRC/alpha" stash -q
echo API_KEY=secret >"$SRC/alpha/.env"
# beta: one commit and no remote. "gamma two": a name with a space.
git init -q "$SRC/beta"
commit "$SRC/beta" b
git init -q "$SRC/gamma two"
commit "$SRC/gamma two" g
# Not snapshotted: a repo with no commits yet, a folder with no .git, a file,
# and a link to a repo elsewhere.
git init -q "$SRC/empty"
mkdir "$SRC/notes" && echo n >"$SRC/notes/n.txt"
echo x >"$SRC/stray.txt"
git init -q "$T/elsewhere"
commit "$T/elsewhere" e
ln -s "$T/elsewhere" "$SRC/linked"

N=0
# run DAY [option...]: one run, standing for DAY. Sets OUT and RC.
run() {
  local day=$1
  shift
  N=$((N + 1))
  OUT="$T/run$N.out"
  REPO_SNAPSHOTS_TODAY=$day /bin/bash "$JOB" "$@" >"$OUT" 2>&1
  RC=$?
}
# bundles REPO: its dated bundles, oldest first, on one line.
bundles() {
  local f names=""
  for f in "$SNAP/$1"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].bundle; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then names="$names${names:+ }${f##*/}"; fi
  done
  printf '%s\n' "$names"
}
refs_of() { git -C "$1" for-each-ref --format='%(objectname) %(refname)'; }
# holds REPO BUNDLE: the bundle names every ref the repo has, and its HEAD.
holds() {
  [ "$({ refs_of "$SRC/$1"; printf '%s HEAD\n' "$(git -C "$SRC/$1" rev-parse HEAD)"; } | sort)" = \
    "$(git bundle list-heads "$2" | sort)" ]
}
# restores REPO BUNDLE: a mirror clone of the bundle, in $T/restore, has
# exactly the repo's refs.
restores() {
  rm -rf "$T/restore"
  git clone -q --mirror "$2" "$T/restore" 2>/dev/null && [ "$(refs_of "$T/restore")" = "$(refs_of "$SRC/$1")" ]
}
# state_of PATH...: every path below them with its mtime, size and mode, and
# each file's checksum.
state_of() {
  find "$@" -exec stat -f '%m %z %p %N' {} + 2>/dev/null | sort
  find "$@" -type f -exec cksum {} + 2>/dev/null | sort
}
calls_since() { tail -n +"$(($1 + 1))" "$T/git-calls.log"; }

section "the first run makes one verified bundle per repo"
state_of "$SRC" "$T/elsewhere" >"$T/src.before"
run 2026-01-04
[ "$RC" = 0 ] && pass "exits 0" || fail "exits 0" "$(cat "$OUT")"
for r in alpha beta "gamma two"; do
  b="$SNAP/$r/2026-01-04.bundle"
  [ "$(ls -A "$SNAP/$r" 2>/dev/null)" = 2026-01-04.bundle ] \
    && pass "$r: one bundle, named for the day, and no temporary file" || fail "$r: one bundle, named for the day, and no temporary file" "$(ls -lA "$SNAP/$r" 2>&1)"
  git -C "$SRC/$r" bundle verify --quiet "$b" >/dev/null 2>&1 \
    && pass "$r: it passes git bundle verify" || fail "$r: it passes git bundle verify"
  holds "$r" "$b" && pass "$r: it names every ref and HEAD" || fail "$r: it names every ref and HEAD" "$(git bundle list-heads "$b" 2>&1)"
  restores "$r" "$b" && pass "$r: a clone of it has the repo's refs" || fail "$r: a clone of it has the repo's refs"
done
heads=$(git bundle list-heads "$A/2026-01-04.bundle")
grep -q ' refs/stash$' <<<"$heads" && grep -q ' refs/tags/v1$' <<<"$heads" && grep -q ' refs/remotes/origin/main$' <<<"$heads" \
  && pass "alpha's holds its stash, its tag and its remote-tracking branch" || fail "alpha's holds its stash, its tag and its remote-tracking branch" "$heads"
restores alpha "$A/2026-01-04.bundle"
objects=$(git -C "$T/restore" rev-list --all --objects)
! grep -q '\.env$' <<<"$objects" && pass "alpha's untracked .env is not in it" || fail "alpha's untracked .env is not in it"
made=""
for x in empty notes linked stray.txt; do [ -e "$SNAP/$x" ] && made="$made $x"; done
[ -z "$made" ] && pass "nothing for a repo with no commits, a folder with no .git, a link or a file" \
  || fail "nothing for a repo with no commits, a folder with no .git, a link or a file" "$made"
grep -Fxq "$SRC/linked | a link, not a clone, so it was not snapshotted" "$ATT" && [ "$(wc -l <"$ATT" | tr -d ' ')" = 2 ] \
  && pass "attention names the link in ~/src, its one item" || fail "attention names the link in ~/src, its one item" "$(cat "$ATT")"
[ "$(head -n 1 "$LOGS/state/alpha")" = 2026-01-04.bundle ] && [ "$(tail -n +2 "$LOGS/state/alpha")" = "$(refs_of "$SRC/alpha")" ] \
  && pass "alpha's fingerprint is kept on this Mac, under ~/Library/Logs" || fail "alpha's fingerprint is kept on this Mac, under ~/Library/Logs"
state_of "$SRC" "$T/elsewhere" >"$T/src.after"
cmp -s "$T/src.before" "$T/src.after" && pass "the repos and the link's target are exactly as they were" \
  || fail "the repos and the link's target are exactly as they were" "$(diff "$T/src.before" "$T/src.after" | head -20)"
[ "$(ls -A "$BK" | tr '\n' ' ')" = "other repositories " ] && [ "$(ls -A "$BK/repositories")" = snapshots ] \
  && pass "in backups it made only repositories/snapshots" || fail "in backups it made only repositories/snapshots" "$(ls -lAR "$BK")"
grep -q '^DONE wrote=3 unchanged=0 skipped=3 failed=0 attention=1 dry_run=0$' <<<"$(sed 's/^[^ ]* //; s/  */ /' "$OUT")" \
  && pass "the log ends with the counts" || fail "the log ends with the counts" "$(tail -n 1 "$OUT")"

section "a second run skips the repos whose refs are unchanged"
calls=$(wc -l <"$T/git-calls.log")
run 2026-01-11
[ "$RC" = 0 ] && pass "exits 0" || fail "exits 0" "$(cat "$OUT")"
for r in alpha beta "gamma two"; do
  [ "$(bundles "$r")" = 2026-01-04.bundle ] && grep -Fq "SAME    $SRC/$r | refs unchanged since 2026-01-04.bundle" "$OUT" \
    && pass "$r: skipped, with no new bundle" || fail "$r: skipped, with no new bundle" "$(cat "$OUT")"
done
! calls_since "$calls" | grep -q ' bundle ' && pass "it ran no git bundle, so it read no bundle" || fail "it ran no git bundle, so it read no bundle"

section "a new commit, branch or stash makes a new bundle, and the old one stays"
commit "$SRC/alpha" more
git -C "$SRC/beta" branch topic
echo w >>"$SRC/gamma two/f-g.txt"
git -C "$SRC/gamma two" stash -q
cp -p "$A/2026-01-04.bundle" "$T/alpha-0104"
run 2026-01-18
[ "$RC" = 0 ] && pass "exits 0" || fail "exits 0" "$(cat "$OUT")"
for r in alpha beta "gamma two"; do
  [ "$(bundles "$r")" = "2026-01-04.bundle 2026-01-18.bundle" ] && holds "$r" "$SNAP/$r/2026-01-18.bundle" \
    && pass "$r: a new bundle with its new refs" || fail "$r: a new bundle with its new refs" "$(bundles "$r")"
done
grep -Fq "WROTE   $SRC/alpha | $A/2026-01-18.bundle | refs changed since 2026-01-04.bundle" "$OUT" \
  && pass "the log says what it wrote and why" || fail "the log says what it wrote and why" "$(cat "$OUT")"
cmp -s "$A/2026-01-04.bundle" "$T/alpha-0104" && pass "the earlier bundle is untouched" || fail "the earlier bundle is untouched"

section "a bundle that would not restore is never kept"
commit "$SRC/beta" cut
cp -p "$LOGS/state/beta" "$T/beta.state"
touch "$T/corrupt-bundles"
run 2026-01-25
rm "$T/corrupt-bundles"
[ "$RC" = 1 ] && pass "the run exits 1" || fail "the run exits 1" "$(cat "$OUT")"
grep -Fq "FAILED  $SRC/beta | the new bundle failed its check: a clone of it failed:" "$OUT" \
  && pass "git bundle verify passes the cut bundle, and the clone of it catches it" || fail "git bundle verify passes the cut bundle, and the clone of it catches it" "$(cat "$OUT")"
[ "$(ls -A "$SNAP/beta" | tr '\n' ' ')" = "2026-01-04.bundle 2026-01-18.bundle " ] \
  && pass "no bundle and no temporary file is left for that day" || fail "no bundle and no temporary file is left for that day" "$(ls -lA "$SNAP/beta")"
cmp -s "$LOGS/state/beta" "$T/beta.state" && pass "its fingerprint is not recorded" || fail "its fingerprint is not recorded"
grep -Fq "$SRC/beta | snapshot failed: the new bundle failed its check: a clone of it failed:" "$ATT" \
  && pass "attention says so" || fail "attention says so" "$(cat "$ATT")"
run 2026-01-25
[ "$RC" = 0 ] && [ "$(bundles beta)" = "2026-01-04.bundle 2026-01-18.bundle 2026-01-25.bundle" ] && holds beta "$SNAP/beta/2026-01-25.bundle" \
  && pass "the next run writes it" || fail "the next run writes it" "$(cat "$OUT")"

section "it keeps the newest 4 bundles and deletes nothing else"
echo n >"$A/notes.txt"
echo x >"$A/2026-01-01.bundle.bak"
echo x >"$A/old.bundle"
echo x >"$A/2026-1-1.bundle"
mkdir "$A/2025-12-28.bundle"
ln -s notes.txt "$A/2025-12-21.bundle"
for day in 2026-02-01 2026-02-08 2026-02-15; do
  commit "$SRC/alpha" "$day"
  run "$day"
  [ "$RC" = 0 ] || fail "the run for $day exits 0" "$(cat "$OUT")"
done
[ "$(bundles alpha)" = "2026-01-18.bundle 2026-02-01.bundle 2026-02-08.bundle 2026-02-15.bundle" ] \
  && pass "alpha keeps its newest 4" || fail "alpha keeps its newest 4" "$(ls -lA "$A")"
grep -Fq "DELETED $A/2026-01-04.bundle | older than the newest 4" "$OUT" \
  && pass "the log names the one it deleted" || fail "the log names the one it deleted" "$(cat "$OUT")"
[ -f "$A/notes.txt" ] && [ -f "$A/2026-01-01.bundle.bak" ] && [ -f "$A/old.bundle" ] && [ -f "$A/2026-1-1.bundle" ] &&
  [ -d "$A/2025-12-28.bundle" ] && [ -L "$A/2025-12-21.bundle" ] \
  && pass "other files, and a folder and a link named like a bundle, all stay" || fail "other files, and a folder and a link named like a bundle, all stay" "$(ls -lA "$A")"
[ "$(bundles beta)" = "2026-01-04.bundle 2026-01-18.bundle 2026-01-25.bundle" ] \
  && pass "the other repos' bundles are as they were" || fail "the other repos' bundles are as they were" "$(bundles beta)"

section "--dry-run writes nothing"
commit "$SRC/alpha" dry
state_of "$HOME" "$T/tmp" >"$T/dry.before"
logged=$(wc -l <"$T/logger.log")
run 2026-02-22 --dry-run --keep 2
state_of "$HOME" "$T/tmp" >"$T/dry.after"
[ "$RC" = 0 ] && pass "exits 0" || fail "exits 0" "$(cat "$OUT")"
cmp -s "$T/dry.before" "$T/dry.after" \
  && pass "no bundle, folder, fingerprint, log, attention file or scratch folder" || fail "no bundle, folder, fingerprint, log, attention file or scratch folder" "$(diff "$T/dry.before" "$T/dry.after" | head -20)"
[ "$(wc -l <"$T/logger.log")" = "$logged" ] && pass "and nothing for the system log" || fail "and nothing for the system log"
grep -Fq "WOULD   $SRC/alpha | refs changed since 2026-02-15.bundle | would write $A/2026-02-22.bundle" "$OUT" \
  && pass "it says what it would write" || fail "it says what it would write" "$(cat "$OUT")"
grep -Fq "WOULD   $A/2026-01-18.bundle | would delete it, as older than the newest 2" "$OUT" &&
  grep -Fq "WOULD   $A/2026-02-08.bundle | would delete it" "$OUT" && ! grep -Fq "WOULD   $A/2026-02-15.bundle" "$OUT" \
  && pass "and what --keep 2 would delete" || fail "and what --keep 2 would delete" "$(cat "$OUT")"
run 2026-02-22
[ "$RC" = 0 ] && [ "$(bundles alpha)" = "2026-02-01.bundle 2026-02-08.bundle 2026-02-15.bundle 2026-02-22.bundle" ] \
  && pass "a real run then does it, keeping 4" || fail "a real run then does it, keeping 4" "$(cat "$OUT")"

section "a missing backups folder: nothing is made, and attention says why"
commit "$SRC/alpha" nobackups
mv "$BK" "$T/backups.away"
state_of "$DBX" >"$T/nb.before"
run 2026-03-01
state_of "$DBX" >"$T/nb.after"
[ "$RC" = 1 ] && pass "the run exits 1" || fail "the run exits 1" "$(cat "$OUT")"
[ ! -e "$BK" ] && cmp -s "$T/nb.before" "$T/nb.after" \
  && pass "nothing is made in Dropbox, backups included" || fail "nothing is made in Dropbox, backups included" "$(diff "$T/nb.before" "$T/nb.after")"
grep -Fxq "$BK | $NOBACKUPS" "$ATT" && [ "$(wc -l <"$ATT" | tr -d ' ')" = 2 ] \
  && pass "attention says to sync it, not make it" || fail "attention says to sync it, not make it" "$(cat "$ATT")"
[ "$(head -n 1 "$LOGS/state/alpha")" = 2026-02-22.bundle ] && pass "alpha's fingerprint is unchanged" || fail "alpha's fingerprint is unchanged"
state_of "$HOME" "$T/tmp" >"$T/nbdry.before"
run 2026-03-01 --dry-run
state_of "$HOME" "$T/tmp" >"$T/nbdry.after"
[ "$RC" = 1 ] && cmp -s "$T/nbdry.before" "$T/nbdry.after" && grep -Fq "$BK | $NOBACKUPS" "$OUT" \
  && pass "a dry run prints the same and writes nothing" || fail "a dry run prints the same and writes nothing" "$(cat "$OUT")"
mv "$T/backups.away" "$BK"

section "a ~/src that is a link, or missing, is refused"
mv "$SRC" "$T/src.real"
ln -s "$T/src.real" "$SRC"
calls=$(wc -l <"$T/git-calls.log")
state_of "$DBX" >"$T/ln.before"
run 2026-03-08
state_of "$DBX" >"$T/ln.after"
[ "$RC" = 1 ] && cmp -s "$T/ln.before" "$T/ln.after" \
  && pass "a link: the run exits 1 and writes nothing in Dropbox" || fail "a link: the run exits 1 and writes nothing in Dropbox" "$(cat "$OUT")"
! calls_since "$calls" | grep -q 'for-each-ref' && pass "and reads no repo through it" || fail "and reads no repo through it"
grep -Fxq "$SRC | a link to $T/src.real, not a folder of clones, so no repo was snapshotted; remove just the link with unlink, never what it points to, then run chezmoi apply, which clones the repos into a real folder" "$ATT" \
  && pass "attention says how to replace it" || fail "attention says how to replace it" "$(cat "$ATT")"
rm "$SRC"
mv "$T/src.real" "$T/src.away"
run 2026-03-08
state_of "$DBX" >"$T/ln.after2"
[ "$RC" = 1 ] && cmp -s "$T/ln.before" "$T/ln.after2" \
  && pass "missing: the run exits 1 and writes nothing in Dropbox" || fail "missing: the run exits 1 and writes nothing in Dropbox" "$(cat "$OUT")"
grep -Fxq "$SRC | not there, so no repo was snapshotted; chezmoi apply clones the repos into it" "$ATT" \
  && pass "attention says the apply clones them" || fail "attention says the apply clones them" "$(cat "$OUT")"
mv "$T/src.away" "$SRC"

section "macOS refusing the job its folder in Dropbox"
# Listing backups refused, as on the mini before anyone lets the job in.
echo "$BK" >"$T/deny-ls"
state_of "$DBX" >"$T/deny.before"
run 2026-03-15
state_of "$DBX" >"$T/deny.after"
rm "$T/deny-ls"
[ "$RC" = 1 ] && cmp -s "$T/deny.before" "$T/deny.after" \
  && pass "refused at backups: the run exits 1 and writes nothing" || fail "refused at backups: the run exits 1 and writes nothing" "$(cat "$OUT")"
grep -Fxq "$BK | $KICK" "$ATT" \
  && pass "attention says to give /bin/bash Full Disk Access and run it again" || fail "attention says to give /bin/bash Full Disk Access and run it again" "$(cat "$ATT")"
# A write refused: alpha's folder locked with chflags, which fails a write
# with the same error. beta has a change too, to show the run stops at alpha.
commit "$SRC/beta" refused
cp -p "$LOGS/state/alpha" "$T/alpha.state"
chflags uchg "$A"
run 2026-03-15
chflags nouchg "$A"
[ "$RC" = 1 ] && grep -Fxq "$A | $KICK" "$ATT" \
  && pass "refused at a write: attention names that folder and says the same" || fail "refused at a write: attention names that folder and says the same" "$(cat "$OUT")"
! grep -Fq "$SRC/beta" "$OUT" && pass "the run stops there, before beta" || fail "the run stops there, before beta" "$(cat "$OUT")"
left=""
for f in "$A"/.~*; do [ -e "$f" ] && left="$left $f"; done
cmp -s "$LOGS/state/alpha" "$T/alpha.state" && [ -z "$left" ] \
  && pass "alpha's fingerprint is unchanged and nothing is left in its folder" || fail "alpha's fingerprint is unchanged and nothing is left in its folder" "$(ls -lA "$A")"
run 2026-03-15
[ "$RC" = 0 ] && [ -f "$A/2026-03-15.bundle" ] && [ -f "$SNAP/beta/2026-03-15.bundle" ] \
  && pass "once it is let in, the next run writes both" || fail "once it is let in, the next run writes both" "$(cat "$OUT")"
# A folder it may not write for an ordinary reason is a failed snapshot, and
# the run goes on.
commit "$SRC/beta" perm
commit "$SRC/gamma two" perm
chmod 500 "$SNAP/beta"
run 2026-03-22
chmod 700 "$SNAP/beta"
[ "$RC" = 1 ] && grep -F "$SRC/beta | snapshot failed: git bundle create: fatal: Unable to create" "$ATT" | grep -Fq "Permission denied; its older bundles are as they were, and the next run tries again" \
  && pass "permission denied is a failed snapshot, with git's error" || fail "permission denied is a failed snapshot, with git's error" "$(cat "$ATT")"
! grep -q kickstart "$ATT" && pass "and not taken for macOS refusing the job" || fail "and not taken for macOS refusing the job" "$(cat "$ATT")"
[ -f "$SNAP/gamma two/2026-03-22.bundle" ] && pass "the run goes on to the next repo" || fail "the run goes on to the next repo" "$(cat "$OUT")"

section "a temporary file a stopped run left"
touch "$A/.~2026-03-01.bundle.12345.lock"
run 2026-03-29
grep -Fxq "$A/.~2026-03-01.bundle.12345.lock | left by a run that stopped while writing a bundle; delete it" "$ATT" && [ -e "$A/.~2026-03-01.bundle.12345.lock" ] \
  && pass "attention names it, and the job leaves it" || fail "attention names it, and the job leaves it" "$(cat "$ATT")"
rm "$A/.~2026-03-01.bundle.12345.lock"

section "--root and --dest"
mkdir -p "$T/alt/src" "$T/alt/box/backups"
git init -q "$T/alt/src/one"
commit "$T/alt/src/one" one
run 2026-04-05 --root "$T/alt/src" --dest "$T/alt/box/backups/r/s"
[ "$RC" = 0 ] && [ -f "$T/alt/box/backups/r/s/one/2026-04-05.bundle" ] \
  && pass "bundles go in DEST/<repo>, and the two folders above DEST are made" || fail "bundles go in DEST/<repo>, and the two folders above DEST are made" "$(cat "$OUT")"
run 2026-04-05 --root "$T/alt/src" --dest "$T/alt/nobox/backups/r/s"
[ "$RC" = 1 ] && [ ! -e "$T/alt/nobox" ] && grep -Fxq "$T/alt/nobox/backups | $NOBACKUPS" "$ATT" \
  && pass "but never the folder two levels above DEST" || fail "but never the folder two levels above DEST" "$(cat "$OUT")"

section "guards"
mkdir "$LOGS/run.lock" && echo $$ >"$LOGS/run.lock/pid"
run 2026-04-12
[ "$RC" = 0 ] && grep -q "another run (pid $$) is still going" "$OUT" \
  && pass "a second run at the same time leaves at once" || fail "a second run at the same time leaves at once" "$(cat "$OUT")"
rm "$LOGS/run.lock/pid" && rmdir "$LOGS/run.lock"
mkdir "$LOGS/run.lock" && echo 99999 >"$LOGS/run.lock/pid"
run 2026-04-12
grep -q ' DONE ' "$OUT" && [ ! -e "$LOGS/run.lock" ] \
  && pass "a lock a dead run left is taken over, and let go after" || fail "a lock a dead run left is taken over, and let go after" "$(cat "$OUT")"
run 2026-04-12 --keep 0
[ "$RC" = 2 ] && pass "--keep 0 is refused" || fail "--keep 0 is refused"
run 2026-04-12 --keep x
[ "$RC" = 2 ] && pass "--keep x is refused" || fail "--keep x is refused"
run 2026-04-12 --nope
[ "$RC" = 2 ] && pass "an unknown option is refused" || fail "an unknown option is refused"
run 2026-4-12
[ "$RC" = 2 ] && pass "a day not in the form YYYY-MM-DD is refused" || fail "a day not in the form YYYY-MM-DD is refused"

section "the git commands it ran"
# Every one with the guards, and nothing but reading refs, making and
# checking a bundle, and a clone of it into the job's own scratch folder.
guards='-c maintenance\.auto=false -c gc\.auto=0 -c core\.fsmonitor=false -c core\.hooksPath=/dev/null'
tre=$(printf '%s' "$T" | sed 's/[][\.*^$()+?{|]/\\&/g')
odd=$(grep -Ev "^$guards (--version|-C .+ for-each-ref --format=.+|-C .+ bundle (create|verify) --quiet .+|clone --quiet --mirror -- .+ $tre/tmp/repo-snapshots\.[^/]+/check\.git)\$" "$T/git-calls.log")
[ -z "$odd" ] && pass "no fetch, gc or write to a repo, and every git call carries the guard settings" \
  || fail "no fetch, gc or write to a repo, and every git call carries the guard settings" "$(sort -u <<<"$odd" | head -10)"
[ -z "$(ls -A "$T/tmp")" ] && pass "its scratch folder goes when it is done" || fail "its scratch folder goes when it is done" "$(ls -lA "$T/tmp")"
state_of "$DBX/repositories" "$BK/other" | grep -v "^[0-9]* [0-9]* [0-9]* $BK/other\$" >"$T/untouched"
[ "$(grep -c . "$T/untouched")" = 6 ] && [ "$(cat "$DBX/repositories/old/file" "$BK/other/file")" = "keep"$'\n'"keep" ] \
  && pass "Dropbox's other folders are untouched" || fail "Dropbox's other folders are untouched" "$(cat "$T/untouched")"
[ "$(ls -A "$BK" | tr '\n' ' ')" = "other repositories " ] && [ "$(ls -A "$BK/repositories")" = snapshots ] \
  && pass "and in backups there is still only repositories/snapshots" || fail "and in backups there is still only repositories/snapshots" "$(ls -lAR "$BK")"
grep -q '^-t repo-snapshots wrote=' "$T/logger.log" && pass "the summary went to the logger shim" || fail "the summary went to the logger shim"

section "the apply script loads both jobs, each on its own marker"
# A launchctl that keeps each label's state in a file. With no-session there
# is no GUI session; with fail-bootstrap, bootstrap fails.
LC="$T/launchctl"
mkdir -p "$LC/bin" "$LC/home/Library/LaunchAgents"
cat >"$LC/bin/launchctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$LC/calls"
case \$1 in
  print)
    [ -e "$LC/no-session" ] && exit 113
    case \$2 in gui/*/*) [ -e "$LC/loaded.\${2##*/}" ] || exit 113 ;; esac ;;
  bootout) rm -f "$LC/loaded.\${2##*/}" ;;
  bootstrap)
    if [ -e "$LC/fail-bootstrap" ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
    touch "$LC/loaded.\$(basename "\$3" .plist)" ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' >"$LC/bin/sleep"
chmod +x "$LC/bin/launchctl" "$LC/bin/sleep"
RA="$LC/run_after.sh"
PL="$LC/repo-snapshots.plist"
if sandbox agent-mini >/dev/null 2>&1 &&
  cz execute-template <"$REPO/home/.chezmoiscripts/run_after_59-launch-agents.sh.tmpl" >"$RA" 2>/dev/null &&
  cz execute-template <"$REPO/home/private_Library/LaunchAgents/com.carlosetejada.repo-snapshots.plist.tmpl" >"$PL" 2>/dev/null &&
  [ -s "$RA" ] && [ -s "$PL" ]; then
  pass "the apply script and the plist render for the agent-mini"
else
  fail "the apply script and the plist render for the agent-mini"
fi
cleanup_sandbox
plutil -lint "$PL" >/dev/null 2>&1 &&
  [ "$(plutil -extract StartCalendarInterval.Weekday raw -o - "$PL")" = 0 ] &&
  [ "$(plutil -extract StartCalendarInterval.Hour raw -o - "$PL")" = 3 ] &&
  [ "$(plutil -extract StartCalendarInterval.Minute raw -o - "$PL")" = 47 ] &&
  [ "$(plutil -extract ProgramArguments.1 raw -o - "$PL")" = "$HOME/.local/bin/repo-snapshots" ] \
  && pass "the plist runs ~/.local/bin/repo-snapshots on Sundays at 03:47" || fail "the plist runs ~/.local/bin/repo-snapshots on Sundays at 03:47" "$(cat "$PL")"
P="$LC/home/Library/LaunchAgents"
MT="$LC/home/Library/Logs/worktree-ttl/.loaded"
MS="$LC/home/Library/Logs/repo-snapshots/.loaded"
apply() { : >"$LC/calls"; HOME="$LC/home" PATH="$LC/bin:$PATH" bash "$RA" >"$LC/out" 2>&1; }
loads() { grep -E '^(bootout|bootstrap) ' "$LC/calls"; }
echo '<plist/>' >"$P/com.carlosetejada.worktree-ttl.plist"
echo '<plist/>' >"$P/com.carlosetejada.repo-snapshots.plist"
apply
[ -e "$LC/loaded.com.carlosetejada.worktree-ttl" ] && [ -e "$LC/loaded.com.carlosetejada.repo-snapshots" ] && [ -e "$MT" ] && [ -e "$MS" ] \
  && pass "a first apply loads both and marks each" || fail "a first apply loads both and marks each" "$(cat "$LC/calls" "$LC/out")"
grep -q 'loaded the worktree cleanup job (daily at 04:17)' "$LC/out" && grep -q 'loaded the snapshot job (Sundays at 03:47)' "$LC/out" \
  && pass "and says so for each" || fail "and says so for each" "$(cat "$LC/out")"
apply
[ -z "$(loads)" ] && pass "a second apply with nothing changed reloads neither" || fail "a second apply with nothing changed reloads neither" "$(loads)"
touch -t 203001010000 "$MT"
touch -t 202001010000 "$MS"
apply
[ "$(loads | grep -c .)" = 2 ] && loads | grep -q '^bootout gui/[0-9]*/com\.carlosetejada\.repo-snapshots$' &&
  loads | grep -q '^bootstrap gui/[0-9]* .*/com\.carlosetejada\.repo-snapshots\.plist$' \
  && pass "a changed snapshot plist reloads that job alone" || fail "a changed snapshot plist reloads that job alone" "$(loads)"
[ "$(stat -f %Sm -t %Y "$MT")" = 2030 ] && [ ! "$P/com.carlosetejada.repo-snapshots.plist" -nt "$MS" ] \
  && pass "and refreshes that job's marker alone" || fail "and refreshes that job's marker alone"
touch -t 202001010000 "$MS"
touch "$LC/fail-bootstrap"
apply
rm "$LC/fail-bootstrap"
grep -q "so the snapshot job is not loaded and no snapshot is taken until the next apply, which tries again" "$LC/out" &&
  [ "$P/com.carlosetejada.repo-snapshots.plist" -nt "$MS" ] \
  && pass "a failed load says so and leaves the marker for the next apply" || fail "a failed load says so and leaves the marker for the next apply" "$(cat "$LC/out")"
rm -f "$LC"/loaded.* "$MT" "$MS"
touch "$LC/no-session"
apply
rm "$LC/no-session"
[ "$(grep -c 'no login session to load the cleanup and snapshot jobs into' "$LC/out")" = 1 ] && [ -z "$(loads)" ] \
  && pass "with no login session it loads neither, and says why once" || fail "with no login session it loads neither, and says why once" "$(cat "$LC/out")"
rm "$P/com.carlosetejada.repo-snapshots.plist"
apply
[ "$(loads | grep -c 'com\.carlosetejada\.worktree-ttl')" = 1 ] && ! grep -q 'com\.carlosetejada\.repo-snapshots' "$LC/calls" \
  && pass "a job whose plist isn't there is left alone" || fail "a job whose plist isn't there is left alone" "$(cat "$LC/calls")"

summary
