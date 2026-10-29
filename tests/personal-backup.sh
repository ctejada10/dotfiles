#!/usr/bin/env bash
# The laptop's personal backup, personal-backup, in throwaway repos: a fake
# HOME with a ~/src of clones, a data folder and a stand-in Dropbox folder,
# an isolated git config, and a throwaway age key from age-keygen. Shims
# record every git and age command the job runs, and can slow git down or
# make age write something wrong; a stand-in op hands the throwaway key over
# or fails; an ls shim can refuse a folder as macOS does; and a logger shim
# keeps the system log out of it. Each run stands for a day of its own.
# Nothing here reads the real Dropbox, ~/src or 1Password. Last, the plist
# that runs the job.
#
#   bash tests/personal-backup.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

# The job runs on the laptop only, and some cases lock a folder with chflags.
if [ "$(uname)" != Darwin ]; then
  echo "personal-backup: the job runs on the laptop only; nothing to check here"
  exit 0
fi
for tool in age age-keygen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "personal-backup: $tool is not installed" >&2
    exit 1
  fi
done

JOB="$REPO/home/dot_local/bin/executable_personal-backup"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/personal-backup-test.XXXXXX")" && pwd -P)"
# Some cases lock a folder or make a file unreadable; open them up so the
# sandbox can go.
trap 'chflags -R nouchg "$T" 2>/dev/null; chmod -R u+rwx "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
REALGIT=$(command -v git)
REALAGE=$(command -v age)
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
EOF

# git: records each command, with the GIT_OPTIONAL_LOCKS the job set. With
# slow-git there, git ls-files says so in in-ls-files and waits, so a run can
# be stopped partway.
cat >"$T/bin/git" <<EOF
#!/bin/bash
printf 'locks=%s %s\n' "\${GIT_OPTIONAL_LOCKS:-unset}" "\$*" >>"$T/git-calls.log"
if [ -e "$T/slow-git" ]; then
  case " \$* " in *" ls-files "*) touch "$T/in-ls-files"; sleep 2 ;; esac
fi
exec "$REALGIT" "\$@"
EOF
# age: records each command. When it encrypts, with age-empty there it
# writes an empty file where -o points, and with age-junk a file that is not
# age's, and exits 0 either way, as a disk or sync fault might leave one.
cat >"$T/bin/age" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/age-calls.log"
out="" prev="" enc=""
for a in "\$@"; do
  [ "\$prev" = -o ] && out=\$a
  [ "\$a" = -r ] && enc=1
  prev=\$a
done
if [ -n "\$enc" ] && [ -n "\$out" ] && [ -e "$T/age-empty" ]; then : >"\$out"; exit 0; fi
if [ -n "\$enc" ] && [ -n "\$out" ] && [ -e "$T/age-junk" ]; then echo "not age" >"\$out"; exit 0; fi
exec "$REALAGE" "\$@"
EOF
# age's secret-key prefix, put together from parts as tests/check-secrets.sh
# does, so this file never holds it whole.
AGEKEY='AGE-SECRET'"-KEY-"
# op: hands over the throwaway key as op item get --fields --reveal does,
# with one newline after it, and records each word it was given, one call a
# line. With op-fail there, it fails as op does when no one approves.
cat >"$T/bin/op" <<EOF
#!/bin/bash
printf '[%s]' "\$@" >>"$T/op-calls.log"
printf '\n' >>"$T/op-calls.log"
if [ -e "$T/op-fail" ]; then
  echo "[ERROR] 2026/01/01 00:00:00 authorization prompt dismissed, please try again" >&2
  exit 1
fi
[ "\$1 \$2" = "item get" ] || exit 1
grep '^$AGEKEY' "$T/key.txt"
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
chmod +x "$T/bin/git" "$T/bin/age" "$T/bin/op" "$T/bin/ls" "$T/bin/logger"
: >"$T/git-calls.log"
: >"$T/age-calls.log"
: >"$T/op-calls.log"
: >"$T/logger.log"
PERSONAL_BACKUP_PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PERSONAL_BACKUP_GIT="$T/bin/git"
PERSONAL_BACKUP_AGE="$T/bin/age"
PERSONAL_BACKUP_OP="$T/bin/op"
export PERSONAL_BACKUP_PATH PERSONAL_BACKUP_GIT PERSONAL_BACKUP_AGE PERSONAL_BACKUP_OP

# The throwaway key. Its private half is in $T/key.txt, outside HOME.
age-keygen -o "$T/key.txt" 2>/dev/null
PUB=$(age-keygen -y "$T/key.txt")
SECRET=$(grep "^$AGEKEY" "$T/key.txt")
# Where the stand-in op is asked for it.
ITEM="test age key"
VAULT=Test
FIELD=password
KEYNAME="1Password item \"$ITEM\" in $VAULT"

SRC="$HOME/src"
SHARE="$HOME/.local/share"
OPS="$SHARE/career-ops"
DBX="$HOME/Library/CloudStorage/Dropbox"
BK="$DBX/backups"
DEST="$BK/personal"
LOGS="$HOME/Library/Logs/personal-backup"
ATT="$LOGS/attention.txt"
PRINT="$LOGS/state/fingerprint"
# Another folder in backups, which the job must never touch.
mkdir -p "$SRC" "$OPS" "$BK/other" "$SHARE/dotfiles"
echo keep >"$BK/other/file"
# The settings, as chezmoi writes them, with a comment, a blank line and a
# key with blanks around it, which the job reads past.
cat >"$SHARE/dotfiles/personal-backup.conf" <<EOF
# personal-backup's settings, for the tests

REPOS=jobs cv
DATA=career-ops
RECIPIENT=$PUB
KEY_ITEM=$ITEM
KEY_VAULT=$VAULT
KEY_FIELD=$FIELD
  KEEP = 3
EOF

# The exact attention lines, less the path each starts with.
KICK="macOS hasn't let the job into Dropbox's folder (Operation not permitted), so the run stopped; give /bin/bash Full Disk Access in System Settings > Privacy & Security, then run launchctl kickstart gui/\$(id -u)/com.carlosetejada.personal-backup"
NOBACKUPS="not there, so nothing was archived; tick it in Dropbox's Preferences > Sync, under Select folders to sync to this Mac, rather than making it by hand, which would give a conflicting copy"
TARHINT="run personal-backup from a terminal to see tar's own errors, which name files and so are never logged"
TRUSTED="check where the file came from, and restore with --from an archive you trust"
REFUSEDALL="so the archive was refused and nothing was restored; $TRUSTED"

commit() { (cd "$1" && echo "$2" >>"f-$2.txt" && git add "f-$2.txt" && git commit -q -m "$2"); }
# An accented name, kept out of this file's own bytes.
CAFE="Initech caf$(printf '\303\251').md"

# jobs, as ai-job-search: a clone whose profile is two commits of its own on
# main, with one more on a branch of its own, an edit, a file staged but not
# committed, untracked and ignored files, and caches.
git init -q --bare "$T/remote/jobs.git"
git clone -q "$T/remote/jobs.git" "$T/seed-jobs" 2>/dev/null
(
  cd "$T/seed-jobs" || exit 1
  printf '%s\n' .env applications/ node_modules/ .venv/ venv/ __pycache__/ '*.pyc' >.gitignore
  echo "name: TBD" >profile.md
  echo "level: 1" >config.yml
  echo "old" >retired.md
  git add . && git commit -q -m base && git push -q origin main
) >/dev/null 2>&1
git clone -q "$T/remote/jobs.git" "$SRC/jobs" 2>/dev/null
J="$SRC/jobs"
echo "name: Carlos" >"$J/profile.md"
git -C "$J" commit -q -am "My profile"
echo "salary: SALARY-150000" >"$J/answers.md"
git -C "$J" add answers.md && git -C "$J" commit -q -m Answers
git -C "$J" switch -q -c side && commit "$J" side && git -C "$J" switch -q main
echo "level: 2" >"$J/config.yml"
echo staged >"$J/staged.md" && git -C "$J" add staged.md
mkdir -p "$J/notes" "$J/bin" "$J/applications/Globex"
echo "Interview at Acme Robotics" >"$J/notes/Acme Robotics.md"
echo "Initech" >"$J/notes/$CAFE"
printf '#!/bin/sh\necho hi\n' >"$J/bin/run.sh" && chmod 755 "$J/bin/run.sh"
ln -s "notes/Acme Robotics.md" "$J/latest"
echo "TOKEN=x" >"$J/.env"
echo "Dear Globex" >"$J/applications/Globex/cover.md"
mkdir -p "$J/node_modules/left" "$J/.venv/bin" "$J/venv" "$J/__pycache__" "$J/.pytest_cache" \
  "$J/.mypy_cache" "$J/.ruff_cache" "$J/.tox" "$J/notes/node_modules"
for f in node_modules/left/index.js .venv/bin/python venv/x __pycache__/m.pyc .pytest_cache/v \
  .mypy_cache/m .ruff_cache/r .tox/t notes/node_modules/n.js tool.pyc .DS_Store notes/.DS_Store; do
  echo cache >"$J/$f"
done
# cv: a clone with no commits of its own, an ignored folder of applications
# and an edit.
git init -q --bare "$T/remote/cv.git"
git clone -q "$T/remote/cv.git" "$T/seed-cv" 2>/dev/null
(
  cd "$T/seed-cv" || exit 1
  echo applications/ >.gitignore
  echo "# CV" >cv.md
  git add . && git commit -q -m base && git push -q origin main
) >/dev/null 2>&1
git clone -q "$T/remote/cv.git" "$SRC/cv" 2>/dev/null
C="$SRC/cv"
mkdir -p "$C/applications/Umbrella Corp"
echo "Dear Umbrella" >"$C/applications/Umbrella Corp/letter.md"
echo "## Experience" >>"$C/cv.md"
# career-ops's data folder, with Finder's litter and an empty folder.
mkdir -p "$OPS/reports" "$OPS/data" "$OPS/output"
echo "# Carlos" >"$OPS/cv.md"
echo "Hooli: offer SALARY-160000" >"$OPS/reports/Hooli.md"
printf 'company\tstatus\nHooli\tapplied\n' >"$OPS/data/applications.tsv"
echo finder >"$OPS/.DS_Store"
echo finder >"$OPS/reports/.DS_Store"

N=0
# run DAY [option...]: one run, standing for DAY. Sets OUT and RC.
run() {
  local day=$1
  shift
  N=$((N + 1))
  OUT="$T/run$N.out"
  PERSONAL_BACKUP_TODAY=$day /bin/bash "$JOB" "$@" >"$OUT" 2>&1
  RC=$?
}
# archives [DIR]: the dated archives in DIR, DEST by default, oldest first.
archives() {
  local f names=""
  for f in "${1:-$DEST}"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].tar.age; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then names="$names${names:+ }${f##*/}"; fi
  done
  printf '%s\n' "$names"
}
# open_archive ARCHIVE DIR: ARCHIVE, decrypted with the throwaway key and
# unpacked into DIR.
open_archive() {
  rm -rf "$2" && mkdir -p "$2" && age -d -i "$T/key.txt" "$1" | tar -x -f - -C "$2"
}
# composed: names as APFS compares them. macOS's bsdtar writes an accented
# name decomposed (NFD) wherever it was composed, and APFS and git take the
# two as the same name.
composed() { iconv -f UTF-8-MAC -t UTF-8; }
# files_in DIR: every file and link under DIR, sorted.
files_in() { (cd "$1" && find . ! -type d | composed | LC_ALL=C sort); }
# manifest DIR: every file and link under DIR but .git and the caches, with
# each file's mode and checksum and each link's target.
manifest() {
  (
    cd "$1" || exit 1
    find . \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -name __pycache__ \
      -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name .tox \) -prune \
      -o \( ! -type d ! -name '*.pyc' ! -name .DS_Store \) -print |
      while IFS= read -r f; do
        if [ -L "$f" ]; then
          printf 'link %s -> %s\n' "$f" "$(readlink "$f")"
        else
          printf 'file %s %s %s\n' "$(stat -f %Lp "$f")" "$(cksum <"$f" | tr -s ' ' | cut -d ' ' -f 1,2)" "$f"
        fi
      done | composed | LC_ALL=C sort
  )
}
# state_of PATH...: every path below them with its mtime, size and mode, and
# each file's checksum.
state_of() {
  find "$@" -exec stat -f '%m %z %p %N' {} + 2>/dev/null | sort
  find "$@" -type f -exec cksum {} + 2>/dev/null | sort
}
# stage_left: any private folder of the job's left in TMPDIR.
stage_left() {
  local d
  for d in "$T/tmp"/personal-backup.*; do
    if [ -e "$d" ]; then printf '%s\n' "${d##*/}"; fi
  done
}
calls_since() { tail -n +"$(($1 + 1))" "$T/git-calls.log"; }
fresh_clone() { git clone -q "$T/remote/$1.git" "$2" 2>/dev/null; }

section "the first run archives each clone's own files and the data folder"
state_of "$SRC" "$OPS" >"$T/src.before"
run 2026-01-04
[ "$RC" = 0 ] && pass "exits 0" || fail "exits 0" "$(cat "$OUT")"
A1="$DEST/2026-01-04.tar.age"
[ "$(ls -A "$DEST")" = 2026-01-04.tar.age ] \
  && pass "one archive, named for the day, and no temporary file" || fail "one archive, named for the day, and no temporary file" "$(ls -lA "$DEST" 2>&1)"
[ "$(head -c 21 "$A1")" = age-encryption.org/v1 ] && pass "it is in age's format" || fail "it is in age's format"
X="$T/x1"
open_archive "$A1" "$X" && pass "it decrypts with the throwaway key and unpacks" || fail "it decrypts with the throwaway key and unpacks"
want=$(printf '%s\n' ./.env ./applications/Globex/cover.md ./bin/run.sh ./config.yml ./latest \
  "./notes/Acme Robotics.md" "./notes/$CAFE" ./staged.md | LC_ALL=C sort)
[ "$(files_in "$X/jobs/checkout")" = "$want" ] \
  && pass "jobs: its untracked and ignored files, its edit and its staged file, and nothing else" \
  || fail "jobs: its untracked and ignored files, its edit and its staged file, and nothing else" "$(files_in "$X/jobs/checkout")"
same=1
while IFS= read -r f; do
  if [ -L "$J/$f" ]; then
    [ "$(readlink "$X/jobs/checkout/$f")" = "$(readlink "$J/$f")" ] || same=0
  else
    cmp -s "$X/jobs/checkout/$f" "$J/$f" && [ "$(stat -f %Lp "$X/jobs/checkout/$f")" = "$(stat -f %Lp "$J/$f")" ] || same=0
  fi
done <<<"$want"
[ "$same" = 1 ] && pass "jobs: each with its content, its mode, or its link's target" || fail "jobs: each with its content, its mode, or its link's target"
heads=$(git bundle list-heads "$X/jobs/local.bundle" 2>&1)
[ "$heads" = "$(git -C "$J" rev-parse main) refs/heads/main"$'\n'"$(git -C "$J" rev-parse side) refs/heads/side" ] \
  && pass "jobs: its bundle holds both branches with commits on no remote" || fail "jobs: its bundle holds both branches with commits on no remote" "$heads"
[ "$(cat "$X/jobs/HEAD")" = main ] && pass "jobs: HEAD names the branch it is on" || fail "jobs: HEAD names the branch it is on"
[ "$(files_in "$X/cv/checkout")" = "$(printf '%s\n' "./applications/Umbrella Corp/letter.md" ./cv.md)" ] && [ ! -e "$X/cv/local.bundle" ] \
  && [ "$(cat "$X/cv/HEAD")" = main ] \
  && pass "cv: its ignored applications and its edit, and no bundle, since it has no commit of its own" \
  || fail "cv: its ignored applications and its edit, and no bundle, since it has no commit of its own" "$(files_in "$X/cv")"
[ "$(files_in "$X/career-ops/data")" = "$(printf '%s\n' ./cv.md ./data/applications.tsv ./reports/Hooli.md)" ] && [ -d "$X/career-ops/data/output" ] \
  && [ "$(manifest "$X/career-ops/data")" = "$(manifest "$OPS")" ] \
  && pass "career-ops: its whole data folder, an empty folder too, and no .DS_Store" \
  || fail "career-ops: its whole data folder, an empty folder too, and no .DS_Store" "$(files_in "$X/career-ops")"
state_of "$SRC" "$OPS" >"$T/src.after"
cmp -s "$T/src.before" "$T/src.after" && pass "the clones and the data folder are exactly as they were" \
  || fail "the clones and the data folder are exactly as they were" "$(diff "$T/src.before" "$T/src.after" | head -20)"
[ "$(head -n 1 "$PRINT")" = 2026-01-04.tar.age ] && [ "$(wc -l <"$PRINT" | tr -d ' ')" = 2 ] && grep -Eq '^[0-9a-f]{64}$' <<<"$(sed -n 2p "$PRINT")" \
  && pass "the fingerprint is kept on this Mac, as a hash" || fail "the fingerprint is kept on this Mac, as a hash" "$(cat "$PRINT")"
[ "$(ls -A "$BK" | tr '\n' ' ')" = "other personal " ] && pass "in backups it made only personal" || fail "in backups it made only personal" "$(ls -lAR "$BK")"
[ "$(stat -f %Lp "$A1")" = 600 ] && pass "the archive is readable by this account alone" || fail "the archive is readable by this account alone"
grep -q '^DONE backup wrote=1 unchanged=0 repos=2 data=1 skipped=0 failed=0 attention=0 dry_run=0$' <<<"$(sed 's/^[^ ]* //; s/  */ /' "$OUT")" \
  && pass "the log ends with the counts" || fail "the log ends with the counts" "$(tail -n 1 "$OUT")"
[ "$(wc -l <"$ATT" | tr -d ' ')" = 1 ] && grep -q ' personal-backup: 0 item(s) need a person$' "$ATT" \
  && pass "attention says no one needs to do anything" || fail "attention says no one needs to do anything" "$(cat "$ATT")"
[ -z "$(stage_left)" ] && pass "the plaintext folder is gone" || fail "the plaintext folder is gone" "$(stage_left)"

section "a run with nothing changed writes nothing"
touch "$J/notes/Acme Robotics.md"
encrypts=$(grep -c -- '^-r ' "$T/age-calls.log")
run 2026-01-11
[ "$RC" = 0 ] && [ "$(archives)" = 2026-01-04.tar.age ] && grep -Fq "SAME    unchanged since 2026-01-04.tar.age" "$OUT" \
  && pass "SAME, and no new archive, though a file's time changed" || fail "SAME, and no new archive, though a file's time changed" "$(cat "$OUT")"
[ "$encrypts" = 1 ] && [ "$(grep -c -- '^-r ' "$T/age-calls.log")" = 1 ] && pass "and nothing was encrypted" || fail "and nothing was encrypted" "$(cat "$T/age-calls.log")"
[ -z "$(stage_left)" ] && pass "the plaintext folder is gone" || fail "the plaintext folder is gone" "$(stage_left)"

section "a changed file, or a new commit, makes a new archive, and the old ones stay"
echo "second round" >>"$J/notes/Acme Robotics.md"
cp -p "$A1" "$T/a1.copy"
run 2026-01-18
[ "$RC" = 0 ] && [ "$(archives)" = "2026-01-04.tar.age 2026-01-18.tar.age" ] \
  && grep -Fq "WROTE   $DEST/2026-01-18.tar.age | changed since 2026-01-04.tar.age |" "$OUT" \
  && pass "a changed file: a new archive, and the log says why" || fail "a changed file: a new archive, and the log says why" "$(cat "$OUT")"
cmp -s "$A1" "$T/a1.copy" && pass "the earlier archive is untouched" || fail "the earlier archive is untouched"
commit "$C" edu
run 2026-01-25
open_archive "$DEST/2026-01-25.tar.age" "$T/x3"
[ "$RC" = 0 ] && [ "$(git bundle list-heads "$T/x3/cv/local.bundle" 2>&1)" = "$(git -C "$C" rev-parse main) refs/heads/main" ] \
  && pass "a new commit: a new archive, with cv's bundle" || fail "a new commit: a new archive, with cv's bundle" "$(cat "$OUT")"

section "a restore puts it all back, byte for byte, into fresh clones and an empty data folder"
F="$T/fresh"
mkdir -p "$F/src" "$F/share"
fresh_clone jobs "$F/src/jobs"
fresh_clone cv "$F/src/cv"
run 2026-01-26 restore --root "$F/src" --data-root "$F/share" --identity-file "$T/key.txt"
[ "$RC" = 0 ] && pass "exits 0" || fail "exits 0" "$(cat "$OUT")"
grep -Fq "OPENED  $DEST/2026-01-25.tar.age" "$OUT" && pass "it reads the newest archive" || fail "it reads the newest archive" "$(cat "$OUT")"
for r in jobs cv; do
  [ "$(manifest "$F/src/$r")" = "$(manifest "$SRC/$r")" ] \
    && pass "$r: every file and link, with its content and mode, as in the original" \
    || fail "$r: every file and link, with its content and mode, as in the original" "$(diff <(manifest "$SRC/$r") <(manifest "$F/src/$r"))"
  [ "$(git -C "$F/src/$r" rev-parse HEAD)" = "$(git -C "$SRC/$r" rev-parse HEAD)" ] \
    && pass "$r: the bundle reset puts its commits back" || fail "$r: the bundle reset puts its commits back"
done
[ "$(git -C "$F/src/jobs" ls-files -z --others -- "notes/$CAFE" | tr '\0' '\n')" = "notes/$CAFE" ] && cmp -s "$F/src/jobs/notes/$CAFE" "$J/notes/$CAFE" \
  && pass "jobs: git sees the accented name as it was, though tar wrote it decomposed" || fail "jobs: git sees the accented name as it was, though tar wrote it decomposed"
[ "$(git -C "$F/src/jobs" log --format=%s main)" = "$(printf '%s\n' Answers "My profile" base)" ] \
  && pass "jobs: main has its own two commits on the remote's" || fail "jobs: main has its own two commits on the remote's" "$(git -C "$F/src/jobs" log --oneline)"
[ "$(git -C "$F/src/jobs" rev-parse side 2>&1)" = "$(git -C "$J" rev-parse side)" ] \
  && pass "jobs: its other branch is made from the archive's commits" || fail "jobs: its other branch is made from the archive's commits"
[ "$(manifest "$F/share/career-ops")" = "$(manifest "$OPS")" ] && [ -d "$F/share/career-ops/output" ] \
  && pass "career-ops: its data folder, as it was" || fail "career-ops: its data folder, as it was" "$(diff <(manifest "$OPS") <(manifest "$F/share/career-ops"))"
[ "$(stat -f %Lp "$F/share/career-ops")" = 700 ] && pass "career-ops: the folder is made private, 0700" || fail "career-ops: the folder is made private, 0700" "$(stat -f %Lp "$F/share/career-ops")"
grep -Fq "RESET   jobs | main to the archive's commits" "$OUT" && grep -Fq "BRANCH  jobs | side, from the archive's commits" "$OUT" &&
  grep -Fq "COPIED  jobs | 8 file(s) into $F/src/jobs" "$OUT" && grep -Fq "COPIED  career-ops | 3 file(s) into $F/share/career-ops" "$OUT" \
  && pass "the log says what it put back" || fail "the log says what it put back" "$(cat "$OUT")"
grep -q '^DONE restore restored=3 nothing=0 refused=0 failed=0 attention=0 dry_run=0$' <<<"$(sed 's/^[^ ]* //; s/  */ /' "$OUT")" \
  && pass "the log ends with the counts" || fail "the log ends with the counts" "$(tail -n 1 "$OUT")"
[ -z "$(stage_left)" ] && pass "the plaintext folder is gone" || fail "the plaintext folder is gone" "$(stage_left)"
state_of "$F" >"$T/f.before"
run 2026-01-26 restore --root "$F/src" --data-root "$F/share" --identity-file "$T/key.txt"
state_of "$F" >"$T/f.after"
[ "$RC" = 1 ] && cmp -s "$T/f.before" "$T/f.after" && [ "$(grep -c '^REFUSED ' <<<"$(sed 's/^[^ ]* //' "$OUT")")" = 3 ] \
  && pass "a second restore over them refuses all three and writes nothing" || fail "a second restore over them refuses all three and writes nothing" "$(cat "$OUT")"

section "without --identity-file the key comes from op, and never touches the disk"
G="$T/fresh2"
mkdir -p "$G/src" "$G/share"
fresh_clone cv "$G/src/cv"
: >"$T/op-calls.log"
: >"$T/age-calls.log"
run 2026-01-26 restore cv --root "$G/src" --data-root "$G/share"
[ "$RC" = 0 ] && [ "$(manifest "$G/src/cv")" = "$(manifest "$C")" ] \
  && pass "the restore works through op" || fail "the restore works through op" "$(cat "$OUT")"
[ "$(cat "$T/op-calls.log")" = "[item][get][$ITEM][--vault][$VAULT][--fields][label=$FIELD][--reveal]" ] \
  && pass "op was asked once, for the item, vault and field in the settings" || fail "op was asked once, for the item, vault and field in the settings" "$(cat "$T/op-calls.log")"
grep -Eq -- '^-d -i /dev/fd/[0-9]+ -o ' "$T/age-calls.log" && pass "age read the key through a pipe" || fail "age read the key through a pipe" "$(cat "$T/age-calls.log")"
! grep -rqF -- "$SECRET" "$HOME" "$T/tmp" "$G" "$T"/run*.out && pass "the key is in no file under HOME, TMPDIR or the clone" || fail "the key is in no file under HOME, TMPDIR or the clone"
[ ! -e "$G/share/career-ops" ] && pass "a name given limits the restore to it" || fail "a name given limits the restore to it"

section "a restore refuses a clone with local state and a data folder that isn't empty"
R="$T/refuse"
mkdir -p "$R/src" "$R/share/career-ops"
fresh_clone jobs "$R/src/jobs"
echo mine >"$R/src/jobs/mine.txt"
fresh_clone cv "$R/src/cv"
commit "$R/src/cv" mine
echo mine >"$R/share/career-ops/mine.md"
state_of "$R" >"$T/r.before"
run 2026-01-27 restore --root "$R/src" --data-root "$R/share" --identity-file "$T/key.txt"
state_of "$R" >"$T/r.after"
[ "$RC" = 1 ] && cmp -s "$T/r.before" "$T/r.after" \
  && pass "exits 1, and writes nothing into any of them" || fail "exits 1, and writes nothing into any of them" "$(cat "$OUT")"
grep -Fxq "$R/src/jobs | has 1 untracked or ignored file(s) of its own, so nothing was restored into it; move the clone aside, run chezmoi apply to clone it again, then run personal-backup restore jobs" "$ATT" \
  && pass "an untracked file: attention says what to do" || fail "an untracked file: attention says what to do" "$(cat "$ATT")"
grep -Fxq "$R/src/cv | has 1 commit(s) on no remote of its own, so nothing was restored into it; move the clone aside, run chezmoi apply to clone it again, then run personal-backup restore cv" "$ATT" \
  && pass "a commit of its own: the same" || fail "a commit of its own: the same" "$(cat "$ATT")"
grep -Fxq "$R/share/career-ops | not empty, so nothing was restored into it; move it aside, then run personal-backup restore career-ops" "$ATT" \
  && pass "a data folder that isn't empty: attention says to move it aside" || fail "a data folder that isn't empty: attention says to move it aside" "$(cat "$ATT")"
grep -q ' personal-backup restore: 3 item(s) need a person$' "$ATT" && pass "the attention file says it is the restore's" || fail "the attention file says it is the restore's" "$(head -n 1 "$ATT")"
# One refused, the others restored: it carries on.
rm -rf "$R/src/cv" "$R/share/career-ops"
fresh_clone cv "$R/src/cv"
run 2026-01-27 restore --root "$R/src" --data-root "$R/share" --identity-file "$T/key.txt"
[ "$RC" = 1 ] && [ "$(manifest "$R/src/cv")" = "$(manifest "$C")" ] && [ "$(manifest "$R/share/career-ops")" = "$(manifest "$OPS")" ] \
  && [ ! -e "$R/src/jobs/.env" ] \
  && pass "it refuses the one and restores the others" || fail "it refuses the one and restores the others" "$(cat "$OUT")"
# An edit to a tracked file, and a clone on another branch.
rm -rf "$R"
mkdir -p "$R/src" "$R/share"
fresh_clone cv "$R/src/cv"
echo edit >>"$R/src/cv/cv.md"
fresh_clone jobs "$R/src/jobs"
git -C "$R/src/jobs" switch -q -c elsewhere
state_of "$R" >"$T/r.before"
run 2026-01-27 restore jobs cv --root "$R/src" --identity-file "$T/key.txt"
state_of "$R" >"$T/r.after"
[ "$RC" = 1 ] && cmp -s "$T/r.before" "$T/r.after" \
  && grep -Fxq "$R/src/cv | has 1 changed file(s) of its own, so nothing was restored into it; move the clone aside, run chezmoi apply to clone it again, then run personal-backup restore cv" "$ATT" \
  && pass "an edit to a tracked file is refused" || fail "an edit to a tracked file is refused" "$(cat "$OUT")"
grep -Fxq "$R/src/jobs | on elsewhere, but the archive's commits are on main, so nothing was restored into it; switch it to main with git switch, adding -c if no such branch is there, then run personal-backup restore jobs" "$ATT" \
  && pass "a clone on another branch than the archive's is refused" || fail "a clone on another branch than the archive's is refused" "$(cat "$ATT")"
# Caches alone, and a data folder with only Finder's .DS_Store, count as empty.
rm -rf "$R"
mkdir -p "$R/src" "$R/share/career-ops"
fresh_clone jobs "$R/src/jobs"
mkdir -p "$R/src/jobs/node_modules/x" && echo c >"$R/src/jobs/node_modules/x/i.js" && echo c >"$R/src/jobs/.DS_Store"
echo finder >"$R/share/career-ops/.DS_Store"
run 2026-01-27 restore jobs career-ops --root "$R/src" --data-root "$R/share" --identity-file "$T/key.txt"
[ "$RC" = 0 ] && [ "$(manifest "$R/src/jobs")" = "$(manifest "$J")" ] && [ "$(manifest "$R/share/career-ops")" = "$(manifest "$OPS")" ] \
  && pass "a clone with only caches, and a folder with only .DS_Store, take the restore" || fail "a clone with only caches, and a folder with only .DS_Store, take the restore" "$(cat "$OUT")"
rm -rf "$R"
mkdir -p "$R/share"
echo x >"$R/share/career-ops"
run 2026-01-27 restore career-ops --data-root "$R/share" --identity-file "$T/key.txt"
[ "$RC" = 1 ] && [ "$(cat "$R/share/career-ops")" = x ] \
  && grep -Fxq "$R/share/career-ops | not a folder, so nothing was restored into it; move it aside, then run personal-backup restore career-ops" "$ATT" \
  && pass "a file where the data folder goes is refused" || fail "a file where the data folder goes is refused" "$(cat "$OUT")"
run 2026-01-27 restore jobs --root "$R/src" --identity-file "$T/key.txt"
[ "$RC" = 1 ] && grep -Fxq "$R/src/jobs | not a clone, so nothing was restored into it; chezmoi apply clones it, then run personal-backup restore jobs" "$ATT" \
  && pass "a clone that isn't there is refused, with how to get it" || fail "a clone that isn't there is refused, with how to get it" "$(cat "$ATT")"
[ -z "$(stage_left)" ] && pass "after each, the plaintext folder is gone" || fail "after each, the plaintext folder is gone" "$(stage_left)"

section "it keeps the newest KEEP archives and deletes nothing else"
echo n >"$DEST/notes.txt"
echo x >"$DEST/2026-01-01.tar.age.bak"
echo x >"$DEST/old.tar.age"
echo x >"$DEST/2026-1-1.tar.age"
mkdir "$DEST/2025-12-28.tar.age"
ln -s notes.txt "$DEST/2025-12-21.tar.age"
for day in 2026-02-01 2026-02-08; do
  echo "$day" >>"$J/notes/Acme Robotics.md"
  run "$day"
  [ "$RC" = 0 ] || fail "the run for $day exits 0" "$(cat "$OUT")"
done
[ "$(archives)" = "2026-01-25.tar.age 2026-02-01.tar.age 2026-02-08.tar.age" ] \
  && pass "it keeps the newest 3, as KEEP says" || fail "it keeps the newest 3, as KEEP says" "$(ls -lA "$DEST")"
grep -Fq "DELETED $DEST/2026-01-18.tar.age | older than the newest 3" "$OUT" \
  && pass "the log names the one it deleted" || fail "the log names the one it deleted" "$(cat "$OUT")"
[ -f "$DEST/notes.txt" ] && [ -f "$DEST/2026-01-01.tar.age.bak" ] && [ -f "$DEST/old.tar.age" ] && [ -f "$DEST/2026-1-1.tar.age" ] &&
  [ -d "$DEST/2025-12-28.tar.age" ] && [ -L "$DEST/2025-12-21.tar.age" ] && [ "$(cat "$BK/other/file")" = keep ] \
  && pass "other files, a folder and a link named like an archive, and backups/other all stay" \
  || fail "other files, a folder and a link named like an archive, and backups/other all stay" "$(ls -lA "$DEST")"

section "--dry-run writes nothing"
echo dry >>"$J/notes/Acme Robotics.md"
state_of "$HOME" >"$T/dry.before"
logged=$(wc -l <"$T/logger.log")
run 2026-02-15 --dry-run --keep 2
state_of "$HOME" >"$T/dry.after"
[ "$RC" = 0 ] && pass "exits 0" || fail "exits 0" "$(cat "$OUT")"
cmp -s "$T/dry.before" "$T/dry.after" && [ -z "$(ls -A "$T/tmp")" ] \
  && pass "no archive, fingerprint, log or attention file, and no plaintext left" || fail "no archive, fingerprint, log or attention file, and no plaintext left" "$(diff "$T/dry.before" "$T/dry.after" | head -20)"
[ "$(wc -l <"$T/logger.log")" = "$logged" ] && pass "and nothing for the system log" || fail "and nothing for the system log"
grep -Fq "WOULD   changed since 2026-02-08.tar.age | would write $DEST/2026-02-15.tar.age" "$OUT" \
  && pass "it says what it would write" || fail "it says what it would write" "$(cat "$OUT")"
grep -Fq "WOULD   $DEST/2026-01-25.tar.age | would delete it, as older than the newest 2" "$OUT" &&
  grep -Fq "WOULD   $DEST/2026-02-01.tar.age | would delete it" "$OUT" && ! grep -Fq "WOULD   $DEST/2026-02-08.tar.age" "$OUT" \
  && pass "and what --keep 2, which wins over KEEP, would delete" || fail "and what --keep 2, which wins over KEEP, would delete" "$(cat "$OUT")"
D="$T/dry"
mkdir -p "$D/src" "$D/share"
fresh_clone jobs "$D/src/jobs"
state_of "$HOME" "$D" >"$T/dry.before"
run 2026-02-15 restore -n --root "$D/src" --data-root "$D/share" --identity-file "$T/key.txt"
state_of "$HOME" "$D" >"$T/dry.after"
[ "$RC" = 1 ] && cmp -s "$T/dry.before" "$T/dry.after" && [ -z "$(ls -A "$T/tmp")" ] \
  && pass "a restore with -n writes nothing either" || fail "a restore with -n writes nothing either" "$(diff "$T/dry.before" "$T/dry.after" | head -20; cat "$OUT")"
grep -Fq "WOULD   jobs | would reset main to the archive's commits, make or move forward side from them, copy 8 file(s) into $D/src/jobs" "$OUT" &&
  grep -Fq "WOULD   career-ops | would copy 3 file(s) into $D/share/career-ops" "$OUT" &&
  grep -Fq "$D/src/cv | not a clone, so nothing was restored into it" "$OUT" \
  && pass "and says what it would do, and what it would refuse" || fail "and says what it would do, and what it would refuse" "$(cat "$OUT")"
run 2026-02-15
[ "$RC" = 0 ] && [ "$(archives)" = "2026-02-01.tar.age 2026-02-08.tar.age 2026-02-15.tar.age" ] \
  && pass "a real run then writes it" || fail "a real run then writes it" "$(cat "$OUT")"

section "a missing backups folder: nothing is written, and attention says why"
echo nobackups >>"$J/notes/Acme Robotics.md"
cp -p "$PRINT" "$T/print.before"
mv "$BK" "$T/backups.away"
state_of "$DBX" >"$T/nb.before"
run 2026-02-22
state_of "$DBX" >"$T/nb.after"
[ "$RC" = 1 ] && pass "the run exits 1" || fail "the run exits 1" "$(cat "$OUT")"
[ ! -e "$BK" ] && cmp -s "$T/nb.before" "$T/nb.after" \
  && pass "nothing is made in Dropbox, backups included" || fail "nothing is made in Dropbox, backups included" "$(diff "$T/nb.before" "$T/nb.after")"
grep -Fxq "$BK | $NOBACKUPS" "$ATT" && [ "$(wc -l <"$ATT" | tr -d ' ')" = 2 ] \
  && pass "attention says to sync it, not make it" || fail "attention says to sync it, not make it" "$(cat "$ATT")"
cmp -s "$PRINT" "$T/print.before" && [ -z "$(stage_left)" ] && pass "the fingerprint is unchanged, and no plaintext is left" || fail "the fingerprint is unchanged, and no plaintext is left"
state_of "$HOME" >"$T/nbdry.before"
run 2026-02-22 --dry-run
state_of "$HOME" >"$T/nbdry.after"
[ "$RC" = 1 ] && cmp -s "$T/nbdry.before" "$T/nbdry.after" && grep -Fq "$BK | $NOBACKUPS" "$OUT" \
  && pass "a dry run prints the same and writes nothing" || fail "a dry run prints the same and writes nothing" "$(cat "$OUT")"
mv "$T/backups.away" "$BK"

section "macOS refusing the job its folder in Dropbox"
# Listing backups refused, as on the laptop before anyone lets the job in.
echo "$BK" >"$T/deny-ls"
state_of "$DBX" >"$T/deny.before"
run 2026-02-22
state_of "$DBX" >"$T/deny.after"
rm "$T/deny-ls"
[ "$RC" = 1 ] && cmp -s "$T/deny.before" "$T/deny.after" \
  && pass "refused at backups: the run exits 1 and writes nothing" || fail "refused at backups: the run exits 1 and writes nothing" "$(cat "$OUT")"
grep -Fxq "$BK | $KICK" "$ATT" \
  && pass "attention says to give /bin/bash Full Disk Access and run it again" || fail "attention says to give /bin/bash Full Disk Access and run it again" "$(cat "$ATT")"
# The write refused: the folder locked with chflags, which fails a write with
# the same error, though age says it in lower case.
chflags uchg "$DEST"
run 2026-02-22
chflags nouchg "$DEST"
left=""
for f in "$DEST"/.~*; do [ -e "$f" ] && left="$left $f"; done
[ "$RC" = 1 ] && grep -Fxq "$DEST | $KICK" "$ATT" && [ -z "$left" ] && [ ! -e "$DEST/2026-02-22.tar.age" ] \
  && pass "refused at the write: attention names the folder, and nothing is left in it" || fail "refused at the write: attention names the folder, and nothing is left in it" "$(cat "$OUT")"
cmp -s "$PRINT" "$T/print.before" && [ -z "$(stage_left)" ] && pass "the fingerprint is unchanged, and no plaintext is left" || fail "the fingerprint is unchanged, and no plaintext is left"
run 2026-02-22
[ "$RC" = 0 ] && [ -f "$DEST/2026-02-22.tar.age" ] && pass "once it is let in, the next run writes it" || fail "once it is let in, the next run writes it" "$(cat "$OUT")"

section "an archive that fails its check is never kept"
for fault in age-empty age-junk; do
  echo "$fault" >>"$J/notes/Acme Robotics.md"
  cp -p "$PRINT" "$T/print.before"
  touch "$T/$fault"
  run 2026-03-01
  rm "$T/$fault"
  left=""
  for f in "$DEST"/.~*; do [ -e "$f" ] && left="$left $f"; done
  [ "$RC" = 1 ] && [ ! -e "$DEST/2026-03-01.tar.age" ] && [ -z "$left" ] && cmp -s "$PRINT" "$T/print.before" \
    && grep -Fxq "$DEST | no archive was written: what age wrote is empty, or does not start as age's format does; the older archives are as they were, and the next run tries again" "$ATT" \
    && pass "$fault: no archive, no temporary file, no fingerprint, and attention says so" \
    || fail "$fault: no archive, no temporary file, no fingerprint, and attention says so" "$(cat "$OUT")"
  [ -z "$(stage_left)" ] && pass "$fault: the plaintext folder is gone after the failure" || fail "$fault: the plaintext folder is gone after the failure" "$(stage_left)"
done
run 2026-03-01
[ "$RC" = 0 ] && [ -f "$DEST/2026-03-01.tar.age" ] && pass "the next run writes it" || fail "the next run writes it" "$(cat "$OUT")"

section "a repo that isn't there or isn't a clone, and a data folder not made yet"
mkdir -p "$SRC/plain" "$T/alt/backups"
echo x >"$SRC/plain/x.txt"
run 2026-03-02 --repos "jobs gone plain" --data "career-ops later" --dest "$T/alt/backups/personal"
[ "$RC" = 1 ] && [ "$(archives "$T/alt/backups/personal")" = 2026-03-02.tar.age ] \
  && pass "the run exits 1, and still writes the others' archive" || fail "the run exits 1, and still writes the others' archive" "$(cat "$OUT")"
open_archive "$T/alt/backups/personal/2026-03-02.tar.age" "$T/x5"
[ "$(ls -A "$T/x5" | tr '\n' ' ')" = "career-ops jobs " ] && pass "with jobs and career-ops in it" || fail "with jobs and career-ops in it" "$(ls -A "$T/x5")"
grep -Fxq "$SRC/gone | not there, so it was left out of the archive; chezmoi apply clones it" "$ATT" &&
  grep -Fxq "$SRC/plain | not a git clone, so it was left out of the archive" "$ATT" \
  && pass "attention names each, and why" || fail "attention names each, and why" "$(cat "$ATT")"
grep -Fq "SKIP    later | no data folder at $SHARE/later" "$OUT" && ! grep -q later "$ATT" \
  && pass "a data folder not made yet is logged and skipped, and needs no one" || fail "a data folder not made yet is logged and skipped, and needs no one" "$(cat "$OUT")"
rm -rf "$SRC/plain"

section "an archive from when career-ops was a clone restores into its data folder"
# career-ops as it was: a clone whose personal files are untracked, an edit
# to a tracked file, a cache, and a commit of its own.
git init -q --bare "$T/remote/career-ops.git"
git clone -q "$T/remote/career-ops.git" "$T/seed-ops" 2>/dev/null
(
  cd "$T/seed-ops" || exit 1
  mkdir -p config
  echo "# career-ops" >README.md
  echo "name: TBD" >config/profile.yml
  git add . && git commit -q -m base && git push -q origin main
) >/dev/null 2>&1
O="$T/old/src/career-ops"
mkdir -p "$T/old/src" "$T/old/backups"
fresh_clone career-ops "$O"
mkdir -p "$O/reports" "$O/node_modules/x"
echo "# Carlos" >"$O/cv.md"
echo "Hooli: offer" >"$O/reports/Hooli.md"
echo "name: Carlos" >"$O/config/profile.yml"
echo cache >"$O/node_modules/x/i.js"
commit "$O" mine
run 2026-03-03 --root "$T/old/src" --repos career-ops --data "" --dest "$T/old/backups/personal"
[ "$RC" = 0 ] && pass "the old clone archives as a repo" || fail "the old clone archives as a repo" "$(cat "$OUT")"
NS="$T/new/share"
mkdir -p "$NS"
run 2026-03-04 restore career-ops --data-root "$NS" --from "$T/old/backups/personal/2026-03-03.tar.age" --identity-file "$T/key.txt"
[ "$RC" = 0 ] && [ "$(files_in "$NS/career-ops")" = "$(printf '%s\n' ./config/profile.yml ./cv.md ./reports/Hooli.md)" ] \
  && cmp -s "$NS/career-ops/config/profile.yml" "$O/config/profile.yml" && cmp -s "$NS/career-ops/reports/Hooli.md" "$O/reports/Hooli.md" \
  && pass "its checkout's files land in the data folder, at the same paths" || fail "its checkout's files land in the data folder, at the same paths" "$(cat "$OUT"; files_in "$NS/career-ops")"
grep -Fq "COPIED  career-ops | 3 file(s) into $NS/career-ops, from the checkout the archive kept while it was a clone" "$OUT" \
  && pass "the log says it came from the checkout" || fail "the log says it came from the checkout" "$(cat "$OUT")"
grep -Fxq "$NS/career-ops | the archive also holds the commits career-ops had on no remote while it was a clone; a data folder has no place for them, so they stay in the archive" "$ATT" \
  && pass "attention says its commits stay in the archive" || fail "attention says its commits stay in the archive" "$(cat "$ATT")"
[ "$(stat -f %Lp "$NS/career-ops")" = 700 ] && pass "the folder is made private, 0700" || fail "the folder is made private, 0700"

section "no archive to restore, and 1Password not handing over the key"
H="$T/fresh3"
mkdir -p "$H/src" "$T/empty/backups/personal"
fresh_clone cv "$H/src/cv"
state_of "$H" >"$T/h.before"
run 2026-03-05 restore cv --root "$H/src" --dest "$T/empty/backups/personal"
[ "$RC" = 3 ] && grep -Fxq "$T/empty/backups/personal | no archive there, so nothing was restored; run personal-backup restore cv once Dropbox has synced it" "$ATT" \
  && pass "an empty folder: exit 3, and attention says to run it once Dropbox has synced" || fail "an empty folder: exit 3, and attention says to run it once Dropbox has synced" "$(cat "$OUT")"
run 2026-03-05 restore --root "$H/src" --dest "$T/nobox/backups/personal"
[ "$RC" = 3 ] && grep -Fxq "$T/nobox/backups/personal | no archive there, so nothing was restored; run personal-backup restore once Dropbox has synced it" "$ATT" \
  && pass "no folder at all: exit 3 too" || fail "no folder at all: exit 3 too" "$(cat "$OUT")"
run 2026-03-05 restore --root "$H/src" --from "$T/nope.tar.age"
[ "$RC" = 3 ] && grep -Fxq "$T/nope.tar.age | not there, so nothing was restored" "$ATT" \
  && pass "a --from that isn't there: exit 3" || fail "a --from that isn't there: exit 3" "$(cat "$OUT")"
: >"$T/op-calls.log"
touch "$T/op-fail"
run 2026-03-05 restore cv --root "$H/src"
rm "$T/op-fail"
[ "$RC" = 4 ] && grep -Fxq "$KEYNAME | 1Password didn't hand over its key ([ERROR] 2026/01/01 00:00:00 authorization prompt dismissed, please try again), so nothing was restored; unlock 1Password with its CLI integration turned on, then run personal-backup restore cv" "$ATT" \
  && pass "op failing: exit 4, and attention says to unlock 1Password with its CLI integration on" || fail "op failing: exit 4, and attention says to unlock 1Password with its CLI integration on" "$(cat "$OUT")"
PERSONAL_BACKUP_OP="$T/no-op" run 2026-03-05 restore cv --root "$H/src"
[ "$RC" = 4 ] && grep -Fxq "$KEYNAME | op, 1Password's CLI, is not installed, so nothing was restored; run brew install --cask 1password-cli, unlock 1Password with its CLI integration turned on, then run personal-backup restore cv" "$ATT" \
  && pass "op missing: exit 4 too" || fail "op missing: exit 4 too" "$(cat "$OUT")"
state_of "$H" >"$T/h.after"
cmp -s "$T/h.before" "$T/h.after" && [ -z "$(stage_left)" ] && pass "none of them writes anything, or leaves plaintext" || fail "none of them writes anything, or leaves plaintext"
run 2026-03-05 restore cv --root "$H/src" --identity-file "$T/x1/jobs/HEAD"
[ "$RC" = 1 ] && grep -Fq "$DEST/2026-03-01.tar.age | age could not decrypt it (" "$ATT" && [ -z "$(stage_left)" ] \
  && pass "a key that doesn't open it: exit 1, and no plaintext left" || fail "a key that doesn't open it: exit 1, and no plaintext left" "$(cat "$OUT")"

section "--root may be a link"
ln -s "$SRC" "$T/srclink"
mkdir -p "$T/linkbox/backups"
run 2026-03-06 --root "$T/srclink" --dest "$T/linkbox/backups/personal"
open_archive "$T/linkbox/backups/personal/2026-03-06.tar.age" "$T/x6"
[ "$RC" = 0 ] && [ "$(files_in "$T/x6/jobs/checkout")" = "$(files_in "$X/jobs/checkout")" ] && [ -f "$T/x6/jobs/local.bundle" ] && [ -f "$T/x6/cv/local.bundle" ] \
  && pass "a backup through a linked root archives the clones behind it" || fail "a backup through a linked root archives the clones behind it" "$(cat "$OUT")"
L="$T/linked"
mkdir -p "$L/src" "$L/share"
fresh_clone jobs "$L/src/jobs"
ln -s "$L/src" "$T/restorelink"
run 2026-03-06 restore jobs --root "$T/restorelink" --data-root "$L/share" --identity-file "$T/key.txt"
[ "$RC" = 0 ] && [ "$(manifest "$L/src/jobs")" = "$(manifest "$J")" ] \
  && pass "and a restore through one puts them back" || fail "and a restore through one puts them back" "$(cat "$OUT")"

section "the plaintext goes, even when a run is stopped or killed"
echo stopped >>"$J/notes/Acme Robotics.md"
touch "$T/slow-git"
PERSONAL_BACKUP_TODAY=2026-03-08 /bin/bash "$JOB" >"$T/stopped.out" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [ -e "$T/in-ls-files" ] && break
  sleep 0.1
done
seen=$(stage_left)
kill -TERM "$pid"
wait "$pid"
rc=$?
rm -f "$T/slow-git" "$T/in-ls-files"
[ -n "$seen" ] && [ "$rc" = 143 ] && [ -z "$(stage_left)" ] && [ ! -e "$LOGS/run.lock" ] && [ ! -e "$DEST/2026-03-08.tar.age" ] \
  && pass "stopped partway: it exits 143, removes its plaintext and lets go of its lock" || fail "stopped partway: it exits 143, removes its plaintext and lets go of its lock" "rc=$rc seen=$seen left=$(stage_left)"
# A run killed outright leaves its lock and its plaintext; the next run
# clears both.
mkdir -p "$T/tmp/personal-backup.dead01"
echo "Dear Globex" >"$T/tmp/personal-backup.dead01/cover.md"
mkdir "$LOGS/run.lock" && echo 99999 >"$LOGS/run.lock/pid" && echo "$T/tmp/personal-backup.dead01" >"$LOGS/run.lock/stage"
run 2026-03-08
[ "$RC" = 0 ] && [ -z "$(stage_left)" ] && [ ! -e "$LOGS/run.lock" ] && grep -Fq "CLEANED the private folder a stopped run (pid 99999) left" "$OUT" \
  && pass "killed outright: the next run takes over its lock and removes its plaintext" || fail "killed outright: the next run takes over its lock and removes its plaintext" "$(cat "$OUT")"

section "tar failing on a file"
# A file tar cannot read, so that tar's own errors, which name it, exist.
echo "Dear Initrode" >"$J/notes/Initrode offer.md"
chmod 000 "$J/notes/Initrode offer.md"
run 2026-03-09
chmod 644 "$J/notes/Initrode offer.md"
[ "$RC" = 1 ] && grep -Fxq "$J | tar could not copy all of its files, so the archive may lack some of them; $TARHINT" "$ATT" \
  && pass "attention says so, and where to see tar's own errors" || fail "attention says so, and where to see tar's own errors" "$(cat "$OUT"; cat "$ATT")"
[ -z "$(stage_left)" ] && pass "the plaintext folder is gone after the failure" || fail "the plaintext folder is gone after the failure" "$(stage_left)"
run 2026-03-09
[ "$RC" = 0 ] && pass "once the file is readable again, the run passes" || fail "once the file is readable again, the run passes" "$(cat "$OUT")"

section "a deleted tracked file is left out"
git -C "$J" rm -q retired.md
run 2026-03-10
[ "$RC" = 0 ] && grep -Fq "SAME    unchanged since 2026-03-09.tar.age" "$OUT" \
  && pass "a deletion alone changes nothing it keeps, so the run is SAME" || fail "a deletion alone changes nothing it keeps, so the run is SAME" "$(cat "$OUT")"
echo deleted >>"$J/notes/Acme Robotics.md"
run 2026-03-10
open_archive "$DEST/2026-03-10.tar.age" "$T/x7"
[ "$RC" = 0 ] && [ ! -e "$T/x7/jobs/checkout/retired.md" ] && [ -f "$T/x7/jobs/checkout/config.yml" ] \
  && pass "with another change, a new archive, with nothing of the deleted file" || fail "with another change, a new archive, with nothing of the deleted file" "$(cat "$OUT")"

section "guards"
mkdir "$LOGS/run.lock" && echo $$ >"$LOGS/run.lock/pid"
run 2026-03-11
[ "$RC" = 0 ] && grep -q "SKIP    another run (pid $$) is still going" "$OUT" \
  && pass "a backup while another run is going leaves at once" || fail "a backup while another run is going leaves at once" "$(cat "$OUT")"
run 2026-03-11 restore --identity-file "$T/key.txt"
[ "$RC" = 1 ] && grep -q "ABORT   another run (pid $$) is still going; run personal-backup restore again once it is done" "$OUT" \
  && pass "a restore then exits 1 and says to run it again" || fail "a restore then exits 1 and says to run it again" "$(cat "$OUT")"
rm "$LOGS/run.lock/pid" && rmdir "$LOGS/run.lock"
mkdir "$LOGS/run.lock" && echo 99999 >"$LOGS/run.lock/pid"
run 2026-03-11
grep -q ' DONE ' "$OUT" && [ ! -e "$LOGS/run.lock" ] \
  && pass "a lock a dead run left is taken over, and let go after" || fail "a lock a dead run left is taken over, and let go after" "$(cat "$OUT")"
usage_fails() {
  local what=$1
  shift
  run 2026-03-11 "$@"
  [ "$RC" = 2 ] && pass "$what" || fail "$what" "rc=$RC $(cat "$OUT")"
}
usage_fails "--keep 0 is refused" --keep 0
usage_fails "--keep x is refused" --keep x
usage_fails "an unknown option is refused" --nope
usage_fails "an option with no value is refused" --root
usage_fails "a name with a slash is refused" --repos "jobs ../cv"
usage_fails "a name that starts with a dash is refused" --repos "-x"
usage_fails "a name in both REPOS and DATA is refused" --repos "jobs" --data "jobs"
usage_fails "a recipient that isn't an age key is refused" --recipient "ssh-ed25519 AAAA"
usage_fails "the backup takes no names" cv
usage_fails "--from is for the restore" --from "$A1"
usage_fails "a name in neither REPOS nor DATA is refused" restore other
usage_fails "--keep is for the backup" restore --keep 2
usage_fails "a settings file that isn't there is refused" --config "$T/nope.conf"
run 2026-4-12
[ "$RC" = 2 ] && pass "a day not in the form YYYY-MM-DD is refused" || fail "a day not in the form YYYY-MM-DD is refused"
printf 'REPOS="jobs cv"\n' >"$T/quoted.conf"
usage_fails "a value in quotes is refused" --config "$T/quoted.conf"
printf 'REPO=jobs\n' >"$T/typo.conf"
usage_fails "an unknown key is refused" --config "$T/typo.conf"
printf 'REPOS=jobs\nRECIPIENT=%s\nKEY_VAULT=%s\nKEY_FIELD=%s\n' "$PUB" "$VAULT" "$FIELD" >"$T/nokey.conf"
usage_fails "a restore with no KEY_ITEM and no --identity-file is refused" restore --config "$T/nokey.conf"
usage_fails "an empty --key-field is refused" restore --key-field ""
usage_fails "a vault name with a control character is refused" restore --key-vault "$(printf 'Te\033st')"
printf 'REPOS=jobs\nKEY_ITEM=test\tage key\nKEY_VAULT=%s\nKEY_FIELD=%s\n' "$VAULT" "$FIELD" >"$T/tab.conf"
usage_fails "an item name with a tab in it is refused" restore --config "$T/tab.conf"
usage_fails "the --key options are for the restore" --key-item other
# The file is read, never run: a command in a value stays text.
printf 'REPOS=$(touch %s/pwned)\n' "$T" >"$T/run.conf"
usage_fails "a command in REPOS is refused as a name" --config "$T/run.conf"
printf 'REPOS=cv\nKEY_ITEM=$(touch %s/pwned) key\nKEY_VAULT=%s\nKEY_FIELD=%s\n' "$T" "$VAULT" "$FIELD" >"$T/item.conf"
: >"$T/op-calls.log"
newest=$(archives | awk '{print $NF}')
run 2026-03-11 restore --config "$T/item.conf" --root "$H/src" --from "$DEST/$newest"
[ -n "$newest" ] && [ ! -e "$T/pwned" ] && grep -Fq "[item][get][\$(touch $T/pwned) key][--vault][$VAULT]" "$T/op-calls.log" \
  && pass "a command in the settings file is never run, only passed on as text" || fail "a command in the settings file is never run, only passed on as text" "$(cat "$T/op-calls.log")"

section "a repo nested in an untracked folder comes without its .git, and links that lead out stay out"
NS="$T/nest"
git init -q --bare "$T/remote/nest.git"
git clone -q "$T/remote/nest.git" "$T/seed-nest" 2>/dev/null
(
  cd "$T/seed-nest" || exit 1
  echo "# nest" >README.md
  git add . && git commit -q -m base && git push -q origin main
) >/dev/null 2>&1
mkdir -p "$NS/src" "$NS/share/stash/reports" "$NS/share/stash/vault/.git" "$T/nbox/backups"
fresh_clone nest "$NS/src/nest"
K="$NS/src/nest"
# An untracked folder that holds a repo of its own, with a commit and a file
# not in one yet.
mkdir -p "$K/vendor/lib" "$K/notes"
git -C "$K/vendor/lib" init -q
echo lib >"$K/vendor/lib/lib.txt"
git -C "$K/vendor/lib" add lib.txt && git -C "$K/vendor/lib" commit -q -m lib
echo notes >"$K/vendor/lib/notes.txt"
# Links that stay inside the clone, and links that lead out of it.
ln -s ../README.md "$K/notes/up"
ln -s notes "$K/here"
ln -s /etc/hosts "$K/abs"
ln -s ../outside.txt "$K/escape"
# A data folder with a link inside it, one out of it, and a .git.
echo a >"$NS/share/stash/reports/a.md"
ln -s reports/a.md "$NS/share/stash/latest"
ln -s /tmp "$NS/share/stash/elsewhere"
echo kept >"$NS/share/stash/vault/kept.md"
echo "[core]" >"$NS/share/stash/vault/.git/config"
NB="$T/nbox/backups/personal"
run 2026-03-12 --root "$NS/src" --data-root "$NS/share" --repos nest --data stash --dest "$NB"
[ "$RC" = 0 ] && pass "the backup passes" || fail "the backup passes" "$(cat "$OUT")"
open_archive "$NB/2026-03-12.tar.age" "$T/x8"
[ "$(files_in "$T/x8/nest/checkout")" = "$(printf '%s\n' ./here ./notes/up ./vendor/lib/lib.txt ./vendor/lib/notes.txt)" ] \
  && pass "the nested repo's files come along, and so do the links that stay inside" \
  || fail "the nested repo's files come along, and so do the links that stay inside" "$(files_in "$T/x8/nest/checkout")"
[ -z "$(find "$T/x8" -iname .git)" ] && pass "there is no .git anywhere in the archive" || fail "there is no .git anywhere in the archive" "$(find "$T/x8" -iname .git)"
[ "$(readlink "$T/x8/nest/checkout/notes/up")" = ../README.md ] && [ "$(readlink "$T/x8/nest/checkout/here")" = notes ] &&
  [ "$(readlink "$T/x8/stash/data/latest")" = reports/a.md ] \
  && pass "links are kept as links, with their targets" || fail "links are kept as links, with their targets"
[ "$(files_in "$T/x8/stash/data")" = "$(printf '%s\n' ./latest ./reports/a.md ./vault/kept.md)" ] \
  && pass "the data folder comes without its .git or the link that leads out" || fail "the data folder comes without its .git or the link that leads out" "$(files_in "$T/x8/stash/data")"
grep -Fq "STAGED  nest | 5 untracked or ignored, 0 changed, 0 commit(s) on no remote; left out 1 .git and 2 link(s) leading out" "$OUT" &&
  grep -Fq "STAGED  stash | 3 file(s) from its data folder; left out 1 .git and 1 link(s) leading out" "$OUT" \
  && pass "the log counts what it left out" || fail "the log counts what it left out" "$(cat "$OUT")"
mkdir -p "$NS/fresh/src" "$NS/fresh/share"
fresh_clone nest "$NS/fresh/src/nest"
NF="$NS/fresh/src/nest"
run 2026-03-12 restore --root "$NS/fresh/src" --data-root "$NS/fresh/share" --repos nest --data stash --dest "$NB" --identity-file "$T/key.txt"
[ "$RC" = 0 ] && ! grep -q '^[^ ]* REFUSED' "$OUT" && [ "$(cat "$NF/vendor/lib/notes.txt")" = notes ] && [ ! -e "$NF/vendor/lib/.git" ] &&
  [ "$(readlink "$NF/notes/up")" = ../README.md ] && [ "$(readlink "$NS/fresh/share/stash/latest")" = reports/a.md ] &&
  [ ! -e "$NS/fresh/share/stash/vault/.git" ] \
  && pass "and the archive restores, without being refused" || fail "and the archive restores, without being refused" "$(cat "$OUT")"

section "a planted archive is refused whole, before any of it is copied"
# Each is made from nothing but the public key, as anyone could make one.
P="$T/planted"
PL="$T/planted.tar.age"
mkdir -p "$P/src" "$P/share" "$T/victim"
fresh_clone jobs "$P/src/jobs"
fresh_clone cv "$P/src/cv"
# bones DIR: the bones of an archive, which pass on their own.
bones() {
  rm -rf "$1" && mkdir -p "$1/jobs/checkout" "$1/cv/checkout"
  echo main >"$1/jobs/HEAD"
  echo main >"$1/cv/HEAD"
  echo planted >"$1/jobs/checkout/planted.txt"
}
# plant DIR: DIR, tarred and encrypted to the public key, into $PL.
plant() { (cd "$1" && tar -cf - .) | age -r "$PUB" -o "$PL"; }
# refused WHAT LINE: a restore from $PL exits 1 with LINE for it in the
# attention file, writes nothing in the clones, the data root or where any
# link points, and leaves no plaintext.
refused() {
  state_of "$P" "$T/victim" >"$T/p.before"
  run 2026-03-13 restore --from "$PL" --root "$P/src" --data-root "$P/share" --identity-file "$T/key.txt"
  state_of "$P" "$T/victim" >"$T/p.after"
  [ "$RC" = 1 ] && grep -Fxq "$PL | $2" "$ATT" && cmp -s "$T/p.before" "$T/p.after" && [ -z "$(stage_left)" ] \
    && pass "$1: refused, and nothing is written" || fail "$1: refused, and nothing is written" "$(cat "$OUT" "$ATT")"
}
bones "$T/pl"
plant "$T/pl"
run 2026-03-13 restore -n --from "$PL" --root "$P/src" --data-root "$P/share" --identity-file "$T/key.txt"
[ "$RC" = 0 ] && grep -Fq "WOULD   jobs | would copy 1 file(s) into $P/src/jobs" "$OUT" \
  && pass "the bones alone pass, so each refusal below is for what was added to them" \
  || fail "the bones alone pass, so each refusal below is for what was added to them" "$(cat "$OUT")"
bones "$T/pl"
mkdir -p "$T/pl/jobs/checkout/.git/hooks"
printf '#!/bin/sh\ntouch %s/hook-ran\n' "$T" >"$T/pl/jobs/checkout/.git/hooks/pre-commit"
chmod +x "$T/pl/jobs/checkout/.git/hooks/pre-commit"
plant "$T/pl"
refused "a checkout/.git/hooks/pre-commit" "holds a .git in the files of jobs, which no backup writes and which could plant git hooks or settings, $REFUSEDALL"
[ ! -e "$P/src/jobs/.git/hooks/pre-commit" ] && [ ! -e "$T/hook-ran" ] && pass "no hook lands in the clone" || fail "no hook lands in the clone"
bones "$T/pl"
mkdir -p "$T/pl/jobs/checkout/sub/.GIT/hooks"
echo x >"$T/pl/jobs/checkout/sub/.GIT/hooks/post-checkout"
plant "$T/pl"
refused "a .GIT further down, which APFS takes for .git" "holds a .git in the files of jobs, which no backup writes and which could plant git hooks or settings, $REFUSEDALL"
bones "$T/pl"
mkdir -p "$T/pl/career-ops/data/.git"
echo "[core]" >"$T/pl/career-ops/data/.git/config"
plant "$T/pl"
refused "a .git in a data folder" "holds a .git in the files of career-ops, which no backup writes and which could plant git hooks or settings, $REFUSEDALL"
bones "$T/pl"
mkdir -p "$T/pl/scripts/checkout"
echo "echo planted" >"$T/pl/scripts/checkout/deploy.sh"
plant "$T/pl"
refused "a name the settings don't list" "holds scripts, which is in neither REPOS nor DATA, $REFUSEDALL; if scripts left the settings after this archive was made, name it with --repos or --data for this restore"
bones "$T/pl"
echo stray >"$T/pl/README"
plant "$T/pl"
refused "a stray file at the top" "holds a file or link at its top, where a backup writes only a folder for each name in REPOS and DATA, $REFUSEDALL"
bones "$T/pl"
mkdir -p "$T/pl/.hidden"
plant "$T/pl"
refused "a folder at the top whose name no backup uses" "holds a folder at its top whose name is not one a backup uses, $REFUSEDALL"
bones "$T/pl"
echo stray >"$T/pl/jobs/notes.txt"
plant "$T/pl"
refused "a stray file in a name's folder" "holds something in jobs/ that no backup writes, $REFUSEDALL"
bones "$T/pl"
rm -rf "$T/pl/jobs/checkout"
ln -s "$HOME" "$T/pl/jobs/checkout"
plant "$T/pl"
refused "a checkout that is a link, here to HOME" "holds something in jobs/ that no backup writes, $REFUSEDALL"
bones "$T/pl"
printf 'main\nmore\n' >"$T/pl/jobs/HEAD"
plant "$T/pl"
refused "a HEAD that isn't a branch name" "holds something in jobs/ that no backup writes, $REFUSEDALL"
# Links: a backup keeps a link as a link, so one that stays inside its files
# is one a backup writes, as above. One that leads out is not.
bones "$T/pl"
ln -s "$HOME/.ssh" "$T/pl/jobs/checkout/keys"
plant "$T/pl"
refused "a link that leads out by an absolute path" "holds a link in the files of jobs that leads out of them, which no backup writes, $REFUSEDALL"
bones "$T/pl"
mkdir -p "$T/pl/jobs/checkout/deep"
ln -s ../../../.zshrc "$T/pl/jobs/checkout/deep/rc"
plant "$T/pl"
refused "a link that climbs out" "holds a link in the files of jobs that leads out of them, which no backup writes, $REFUSEDALL"
bones "$T/pl"
mkdir -p "$T/pl/jobs/checkout/a"
ln -s .. "$T/pl/jobs/checkout/a/b"
ln -s b/.. "$T/pl/jobs/checkout/a/c"
plant "$T/pl"
refused "a link that climbs out through another link" "holds a link in the files of jobs that leads out of them, which no backup writes, $REFUSEDALL"
# A file written through a link: the link, then a file under its name. tar
# will not write through a link, so the archive doesn't unpack.
bones "$T/pl"
ln -s "$T/victim" "$T/pl/jobs/checkout/x"
rm -rf "$T/pl2" && mkdir -p "$T/pl2/jobs/checkout/x" && echo pwn >"$T/pl2/jobs/checkout/x/pwn"
(cd "$T/pl" && tar -cf "$T/pl1.tar" .) && (cd "$T/pl2" && tar -cf "$T/pl2.tar" jobs/checkout/x/pwn) &&
  tar -cf - @"$T/pl1.tar" @"$T/pl2.tar" | age -r "$PUB" -o "$PL"
refused "a file written through a link" "what it decrypts to is not a tar that unpacks safely, $REFUSEDALL"
[ -z "$(ls -A "$T/victim")" ] && pass "and nothing lands where the link points" || fail "and nothing lands where the link points" "$(ls -lA "$T/victim")"
# A bundle whose commit holds a .GIT with a hook in it, made on the remote's
# own commits, which are public. git checks every object it fetches, so the
# commit never gets into the clone.
EV="$T/evil"
rm -rf "$EV" && fresh_clone jobs "$EV"
hook=$(printf '#!/bin/sh\ntouch %s/hook-ran\n' "$T" | git -C "$EV" hash-object -w --stdin)
hooks=$(printf '100755 blob %s\tpre-commit\n' "$hook" | git -C "$EV" mktree)
dotgit=$(printf '040000 tree %s\thooks\n' "$hooks" | git -C "$EV" mktree)
tree=$( (git -C "$EV" ls-tree HEAD; printf '040000 tree %s\t.GIT\n' "$dotgit") | git -C "$EV" mktree)
evil=$(git -C "$EV" commit-tree "$tree" -p HEAD -m planted)
git -C "$EV" update-ref refs/heads/main "$evil"
bones "$T/pl"
git -C "$EV" bundle create -q "$T/pl/jobs/local.bundle" --branches --not --remotes
plant "$T/pl"
head_before=$(git -C "$P/src/jobs" rev-parse HEAD)
run 2026-03-13 restore jobs --from "$PL" --root "$P/src" --identity-file "$T/key.txt"
[ "$RC" = 1 ] && grep -F "$P/src/jobs | git could not fetch the archive's commits (" "$ATT" | grep -q hasDotgit &&
  [ "$(git -C "$P/src/jobs" rev-parse HEAD)" = "$head_before" ] && ! git -C "$P/src/jobs" cat-file -e "$evil" 2>/dev/null &&
  [ ! -e "$P/src/jobs/.git/hooks/pre-commit" ] && [ ! -e "$P/src/jobs/planted.txt" ] && [ ! -e "$T/hook-ran" ] \
  && pass "a bundle whose commit holds a .GIT is stopped at the fetch, and none of it gets into the clone" \
  || fail "a bundle whose commit holds a .GIT is stopped at the fetch, and none of it gets into the clone" "$(cat "$OUT" "$ATT")"

section "an archive named for a day after tomorrow is passed over, or refused"
FB="$T/fbox/backups/personal"
FC="$T/future"
mkdir -p "$FB" "$FC/src"
fresh_clone cv "$FC/src/cv"
# A real archive, named for tomorrow, which still counts, and a planted one
# named for the day after.
cp -p "$DEST/$(archives | awk '{print $NF}')" "$FB/2026-03-22.tar.age"
bones "$T/pl"
echo planted >"$T/pl/cv/checkout/planted.txt"
plant "$T/pl"
mv "$PL" "$FB/2026-03-23.tar.age"
run 2026-03-21 restore cv --root "$FC/src" --dest "$FB" --identity-file "$T/key.txt"
[ "$RC" = 0 ] && grep -Fq "OPENED  $FB/2026-03-22.tar.age" "$OUT" && [ ! -e "$FC/src/cv/planted.txt" ] &&
  [ -f "$FC/src/cv/applications/Umbrella Corp/letter.md" ] \
  && pass "the real one, named for tomorrow, is the one restored" || fail "the real one, named for tomorrow, is the one restored" "$(cat "$OUT")"
grep -Fq "IGNORED $FB/2026-03-23.tar.age | named for a day after tomorrow (2026-03-22), so it was passed over" "$OUT" \
  && pass "the log says it passed the later one over, and why" || fail "the log says it passed the later one over, and why" "$(cat "$OUT")"
grep -Fxq "$FB/2026-03-23.tar.age | named for a day after tomorrow (2026-03-22), which no backup made by now can be, so the restore passed it over for 2026-03-22.tar.age; check where the file came from" "$ATT" \
  && pass "and attention says to check where it came from" || fail "and attention says to check where it came from" "$(cat "$ATT")"
state_of "$FC" >"$T/fc.before"
run 2026-03-21 restore cv --root "$FC/src" --from "$FB/2026-03-23.tar.age" --identity-file "$T/key.txt"
state_of "$FC" >"$T/fc.after"
[ "$RC" = 1 ] && cmp -s "$T/fc.before" "$T/fc.after" &&
  grep -Fxq "$FB/2026-03-23.tar.age | named for a day after tomorrow (2026-03-22), which no backup made by now can be, so it was refused and nothing was restored; $TRUSTED" "$ATT" \
  && pass "--from naming it is refused, and nothing is written" || fail "--from naming it is refused, and nothing is written" "$(cat "$OUT")"
rm "$FB/2026-03-22.tar.age"
run 2026-03-21 restore cv --root "$FC/src" --dest "$FB" --identity-file "$T/key.txt"
[ "$RC" = 1 ] &&
  grep -Fxq "$FB | holds only archives named for a day after tomorrow (2026-03-22), which no backup made by now can be, so nothing was restored; check where they came from, and restore with --from an archive you trust" "$ATT" \
  && pass "with only such archives there, nothing is restored, and attention says why" || fail "with only such archives there, nothing is restored, and attention says why" "$(cat "$OUT")"
[ -z "$(stage_left)" ] && pass "and no plaintext is left" || fail "and no plaintext is left" "$(stage_left)"

section "the git commands it ran"
# Every one with the guards and GIT_OPTIONAL_LOCKS=0. The backup only reads
# the clones and makes a bundle in its own folder; only a restore fetches or
# resets, only into the fresh clones the tests made, and every fetch checks
# the objects it gets.
guards='locks=0 -c maintenance\.auto=false -c gc\.auto=0 -c core\.fsmonitor=false -c core\.hooksPath=/dev/null'
odd=$(grep -Ev "^$guards (--version|check-ref-format refs/heads/.+|bundle list-heads .+|-c fetch\.fsckObjects=true -C .+ fetch --quiet --no-tags .+|-C .+ (rev-parse -q --verify HEAD|ls-files --others -z( --exclude=[^ ]+)+|diff --name-only -z( --diff-filter=d --ignore-submodules=all)? HEAD|rev-list --count( HEAD)? --branches --not --remotes|bundle (create|verify) --quiet .+|symbolic-ref --short -q HEAD|reset --quiet --hard FETCH_HEAD))\$" "$T/git-calls.log")
[ -z "$odd" ] && pass "every git call carries the guard settings, and is one of the expected few" \
  || fail "every git call carries the guard settings, and is one of the expected few" "$(sort -u <<<"$odd" | head -10)"
tre=$(printf '%s' "$SRC" | sed 's/[][\.*^$()+?{|]/\\&/g')
writes=$(grep -E ' (fetch|reset) ' "$T/git-calls.log" | grep -E -- "-C $tre/" || true)
[ -z "$writes" ] && grep -q ' fetch ' "$T/git-calls.log" \
  && pass "nothing fetched or reset in the clones it backs up" || fail "nothing fetched or reset in the clones it backs up" "$writes"
grep -q '^-t personal-backup backup wrote=' "$T/logger.log" && grep -q '^-t personal-backup restore restored=' "$T/logger.log" \
  && pass "the summaries went to the logger shim" || fail "the summaries went to the logger shim"
[ -z "$(stage_left)" ] && pass "no plaintext folder is left after any run" || fail "no plaintext folder is left after any run" "$(stage_left)"

section "the log and the attention file never name a file it archived"
# Every name and every line of content the tests archived, looked for in
# the log, the attention file, the fingerprint, the system log and what
# every run above printed, the failures' included.
leaks=""
for s in Acme Initech Initrode Globex Umbrella Hooli SALARY Dear TOKEN cover.md letter.md run.sh applications.tsv profile.yml; do
  hits=$(grep -rlF -- "$s" "$LOGS" "$T/logger.log" "$T"/run*.out "$T/stopped.out" 2>/dev/null)
  [ -z "$hits" ] || leaks="$leaks$s in: $hits"$'\n'
done
[ -z "$leaks" ] && pass "no file's name or content in any of them" || fail "no file's name or content in any of them" "$leaks"

section "the plist that runs it"
PL="$T/personal-backup.plist"
if sandbox laptop >/dev/null 2>&1 &&
  cz execute-template <"$REPO/home/private_Library/LaunchAgents/com.carlosetejada.personal-backup.plist.tmpl" >"$PL" 2>/dev/null &&
  [ -s "$PL" ]; then
  pass "it renders for the laptop"
else
  fail "it renders for the laptop"
fi
cleanup_sandbox
plutil -lint "$PL" >/dev/null 2>&1 &&
  [ "$(plutil -extract Label raw -o - "$PL")" = com.carlosetejada.personal-backup ] &&
  [ "$(plutil -extract StartCalendarInterval.Weekday raw -o - "$PL")" = 0 ] &&
  [ "$(plutil -extract StartCalendarInterval.Hour raw -o - "$PL")" = 3 ] &&
  [ "$(plutil -extract StartCalendarInterval.Minute raw -o - "$PL")" = 47 ] &&
  [ "$(plutil -extract ProgramArguments.0 raw -o - "$PL")" = /bin/bash ] &&
  [ "$(plutil -extract ProgramArguments.1 raw -o - "$PL")" = "$HOME/.local/bin/personal-backup" ] &&
  ! plutil -extract ProgramArguments.2 raw -o - "$PL" >/dev/null 2>&1 \
  && pass "it runs /bin/bash ~/.local/bin/personal-backup on Sundays at 03:47" || fail "it runs /bin/bash ~/.local/bin/personal-backup on Sundays at 03:47" "$(cat "$PL")"
for role in agent-mini ci; do
  if sandbox "$role" >/dev/null 2>&1 &&
    out=$(cz execute-template <"$REPO/home/private_Library/LaunchAgents/com.carlosetejada.personal-backup.plist.tmpl" 2>/dev/null) &&
    [ -z "$(tr -d '[:space:]' <<<"$out")" ]; then
    pass "it renders to nothing for $role"
  else
    fail "it renders to nothing for $role" "$out"
  fi
  cleanup_sandbox
done

summary
