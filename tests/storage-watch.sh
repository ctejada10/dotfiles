#!/usr/bin/env bash
# The mini's storage job, storage-watch.sh, which a Hermes cron job runs with
# no agent and whose stdout it sends to Telegram as it is. Run here in a
# throwaway HOME with stand-ins for colima, docker, df, du and getconf that
# record each call and fail or hang on request, so nothing is pruned, trimmed
# or sent: what it prints is what Hermes would send.
#
#   bash tests/storage-watch.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

# The job runs on the mini only.
if [ "$(uname)" != Darwin ]; then
  echo "storage-watch: the job runs on the mini only; nothing to check here"
  exit 0
fi

JOB="$REPO/home/dot_local/share/dotfiles/hermes/storage-watch.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/storage-watch.XXXXXX")" && pwd -P)"
trap 'rm -rf -- "$T"' EXIT
export HOME="$T/home" TMPDIR="$T/tmp"
unset HERMES_REAL_HOME
STATE="$HOME/Library/Logs/storage-watch"
LOG="$STATE/storage-watch.log"
mkdir -p "$T/bin" "$T/tmp" "$T/usertemp" "$T/mode" "$HOME/agent-drafts" "$HOME/.colima/default"
echo "docker: {}" >"$HOME/.colima/default/colima.yaml"
echo keep >"$HOME/agent-drafts/keep"
echo keep >"$T/usertemp/keep"

# stub NAME: records the call, then does what mode/NAME says: fail or hang.
stub() {
  cat >"$T/bin/$1" <<EOF
#!/bin/bash
printf '%s\n' "$1 \$*" >>"$T/calls"
case "\$(cat "$T/mode/$1" 2>/dev/null)" in
  fail) echo "$1 broke" >&2; exit 1 ;;
  hang) exec sleep 30 ;;
esac
EOF
  cat >>"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
stub colima <<EOF
printf '%s\n' "\$HOME" >"$T/colima-home"
case \$1 in
  status) [ ! -e "$T/mode/stopped" ] || { echo "colima is not running" >&2; exit 1; } ;;
  ssh)
    case "\$(cat "$T/mode/trim" 2>/dev/null)" in
      fail) echo "fstrim broke" >&2; exit 1 ;;
      hang) exec sleep 30 ;;
    esac
    echo "/mnt/lima-colima: 30 GiB trimmed" ;;
esac
EOF
stub docker <<EOF
echo "Total: 12GB"
EOF
stub getconf <<EOF
echo "$T/usertemp/"
EOF
stub df <<EOF
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/disk3s5 482746452 1 \$(cat "$T/free") 52% /System/Volumes/Data"
EOF
# A file that goes while du runs makes it complain and exit 1, total and all.
stub du <<EOF
for p in "\$@"; do :; done
case \$p in *usertemp*) f=temp ;; *) f=drafts ;; esac
case "\$(cat "$T/mode/du-\$f" 2>/dev/null)" in
  fail) echo "du: \$p: Permission denied" >&2; exit 1 ;;
  hang) exec sleep 30 ;;
esac
printf '%s\t%s\n' "\$(cat "$T/\$f")" "\$p"
[ ! -e "$T/mode/vanishing" ] || { echo "du: \$p/gone: No such file or directory" >&2; exit 1; }
EOF

# Never the real colima or docker: the job's PATH has only system tools.
export STORAGE_WATCH_PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
G=1048576
BASE=1800000000

reset() { # a fresh state, Colima up, nothing over a limit
  rm -rf "$STATE" "$T/mode" "$T/calls" "$T/sent"
  mkdir "$T/mode"
  : >"$T/calls"
  : >"$T/sent"
  sizes 200 1 1
}
sizes() { echo $(($1 * G)) >"$T/free"; echo $(($2 * G)) >"$T/temp"; echo $(($3 * G)) >"$T/drafts"; }
watch() { # hours since the first run, then the job's options
  local h=$1
  shift
  STORAGE_WATCH_NOW=$((BASE + h * 3600)) /bin/bash "$JOB" "$@" >"$T/out" 2>"$T/err"
  RC=$?
  # What Hermes would send: stdout, when there is any.
  [ ! -s "$T/out" ] || echo printed >>"$T/sent"
}
sent() { awk 'END { print NR }' "$T/sent"; }
called() { grep -Fqx -- "$1" "$T/calls"; }
check() { # what, then the command that must succeed
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what" "$(cat "$T/out" "$T/err")"; fi
}
says() { grep -Fq -- "$1" "$T/out"; }
quiet() { test ! -s "$T/out"; }
logged() { grep -Fq -- "$1" "$LOG" 2>/dev/null; }
no() { ! "$@"; }

PRUNE="docker --context colima builder prune --builder colima --all --force --max-used-space 15GB"
TRIM="colima ssh -- sudo -n fstrim -v /mnt/lima-colima"

section "upkeep"
reset
watch 0
check "a good run exits 0" test "$RC" = 0
check "it prunes the build cache down to 15GB, exactly so" called "$PRUNE"
check "it trims Colima's disk, exactly so" called "$TRIM"
check "it runs no other colima or docker command" \
  test "$(grep -E '^(colima|docker) ' "$T/calls")" = "colima status"$'\n'"$PRUNE"$'\n'"$TRIM"
check "it measures after the upkeep" \
  test "$(grep -n '^df ' "$T/calls" | cut -d: -f1)" -gt "$(grep -nF "$TRIM" "$T/calls" | cut -d: -f1)"
check "with nothing over a limit and nothing failed it prints nothing" quiet
check "and writes nothing to stderr" test ! -s "$T/err"
check "it logs what the trim freed" logged "30 GiB trimmed"
check "Colima's config is untouched" test "$(cat "$HOME/.colima/default/colima.yaml")" = "docker: {}"
check "it deletes nothing on the Mac" test -f "$HOME/agent-drafts/keep" -a -f "$T/usertemp/keep"

reset
touch "$T/mode/stopped"
sizes 40 1 1
watch 0
check "with Colima stopped, only its status is asked" test "$(grep -E '^(colima|docker) ' "$T/calls")" = "colima status"
check "and that is no failure" no says "failed"
check "and the alert still goes" says "40.0 GiB free"

section "a failure in one never skips the other"
for bad in docker trim; do
  for how in fail hang; do
    reset
    echo "$how" >"$T/mode/$bad"
    sizes 40 1 1
    STORAGE_WATCH_TIMEOUT=1 watch 0
    check "$bad $how: the prune and the trim both ran" test "$(grep -cF -e "$PRUNE" -e "$TRIM" "$T/calls")" = 2
    check "$bad $how: the alert still goes" says "40.0 GiB free"
    check "$bad $how: the message names the failure" says "failed: "
    check "$bad $how: and the run exits 0, so Hermes sends it" test "$RC" = 0
    check "$bad $how: and logs it" logged "FAILED"
  done
done
reset
echo fail >"$T/mode/docker"
watch 0
check "a failure alone prints a message" test "$(sent)" = 1
check "naming the step and what it said" says "docker builder prune: docker broke"
check "one line per failure" test "$(grep -c 'failed: ' "$T/out")" = 1
for how in fail hang; do
  reset
  echo "$how" >"$T/mode/colima"
  sizes 40 1 1
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "colima status $how: no upkeep" no called "$PRUNE"
  check "colima status $how: the alert still goes" says "40.0 GiB free"
  check "colima status $how: the message says it failed, unlike a stopped Colima" says "failed: colima status"
  check "colima status $how: and the run exits 0" test "$RC" = 0
done
check "a status that hangs is logged as a timeout" logged "timed out after 1s"
for how in fail hang; do
  reset
  echo "$how" >"$T/mode/df"
  sizes 200 25 1
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "df $how: the upkeep ran" called "$TRIM"
  check "df $how: the other sizes still alert" says "25.0 GiB"
  check "df $how: the message says it failed" says "failed: df"

  reset
  echo "$how" >"$T/mode/du-temp"
  sizes 200 1 25
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "du of the temp folder $how: agent-drafts still alerts" says "agent-drafts holds 25.0 GiB"
  check "du of the temp folder $how: the message says it failed" says "failed: du $T/usertemp"

  reset
  echo "$how" >"$T/mode/getconf"
  sizes 40 1 1
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "getconf $how: free space still alerts" says "40.0 GiB free"
  check "getconf $how: the message says it failed" says "failed: getconf"
done
reset
touch "$T/mode/vanishing"
sizes 200 25 1
watch 0
check "files that vanish during du still give a size" says "25.0 GiB"
check "and are no failure" no says "failed"

reset
rm "$HOME/agent-drafts/keep"
rmdir "$HOME/agent-drafts"
watch 0
check "no agent-drafts folder is no failure" quiet
mkdir "$HOME/agent-drafts"
echo keep >"$HOME/agent-drafts/keep"

section "what it prints"
reset
sizes 42 31 22
echo fail >"$T/mode/trim"
watch 0
check "one message" test "$(sent)" = 1
check "it starts with what it is about" test "$(head -n 1 "$T/out")" = "The Mac mini's storage needs a look:"
check "and holds nothing else: one line per condition" test "$(awk 'END { print NR }' "$T/out")" = 5
check "with no log line in it" no grep -qE '^[0-9]{4}-|SIZE|OVER|PRUNED' "$T/out"
check "names free space with its size" says "42.0 GiB free"
check "names the temp folder with its size" says "$T/usertemp holds 31.0 GiB"
check "names agent-drafts with its size" says "agent-drafts holds 22.0 GiB"
check "names the failed step" says "failed: fstrim in Colima: fstrim broke"
check "nothing goes to stderr" test ! -s "$T/err"

section "the limits"
reset
sizes 50 20 20
watch 0
check "50 free and 20 in each folder are inside the limits" test "$(sent)" = 0
reset
echo $((50 * G - 1)) >"$T/free"
watch 0
check "a KiB under 50 free alerts" test "$(sent)" = 1
reset
echo $((20 * G + 1)) >"$T/temp"
watch 0
check "a KiB over 20 in the temp folder alerts" test "$(sent)" = 1
reset
echo $((20 * G + 1)) >"$T/drafts"
watch 0
check "a KiB over 20 in agent-drafts alerts" test "$(sent)" = 1

section "how often it prints"
reset
sizes 40 1 1
watch 0
check "a condition prints" test "$(sent)" = 1
sizes 38 1 1
watch 3
check "the same one 3 hours later prints nothing" quiet
sizes 38 25 1
watch 6
check "a new condition prints at once" test "$(sent)" = 2
check "naming the old one too" says "38.0 GiB free"
sizes 200 25 1
watch 9
check "fewer conditions are nothing new" test "$(sent)" = 2
sizes 38 25 1
watch 29
check "the same set waits its 24 hours from the last message" test "$(sent)" = 2
watch 30
check "and prints again after them" test "$(sent)" = 3

reset
echo fail >"$T/mode/docker"
watch 0
check "a failure prints" test "$(sent)" = 1
watch 3
check "the same failure 3 hours later prints nothing" quiet
sizes 40 1 1
watch 6
check "a new condition prints at once" test "$(sent)" = 2
check "naming the failure too" says "failed: docker builder prune"
rm "$T/mode/docker"
sizes 200 1 1
watch 9
check "once all is well it prints nothing" quiet
echo fail >"$T/mode/docker"
watch 31
check "a failure 25 hours after the last one prints again" test "$(sent)" = 3

section "when it can't run"
reset
rm -rf "$HOME/Library/Logs"
touch "$HOME/Library/Logs"
sizes 40 1 1
watch 0
check "with no folder for its state it exits non-zero, so Hermes says so" test "$RC" != 0
check "and prints nothing to send" quiet
check "and says why on stderr" test -s "$T/err"
rm "$HOME/Library/Logs"
reset
TMPDIR="$T/nowhere" watch 0
check "with no temp folder it exits non-zero" test "$RC" != 0
check "and prints nothing to send" quiet

section "under Hermes"
reset
sizes 200 1 25
HOME="$T/profile" HERMES_REAL_HOME="$T/home" watch 0
check "it keeps its state in the real home Hermes names" logged "GiB free"
check "and runs colima there" test "$(cat "$T/colima-home")" = "$T/home"
check "and measures the real agent-drafts" says "$T/home/agent-drafts holds 25.0 GiB"
check "and writes nothing in the profile's home" test ! -e "$T/profile"
rm -rf "$T/profile"

section "dry run"
reset
sizes 40 25 1
watch 0 --dry-run
check "it exits 0" test "$RC" = 0
check "it prints each measurement" test "$(grep -cE 'SIZE .*(GiB free|usertemp holds 25.0 GiB|agent-drafts holds 1.0 GiB)' "$T/out")" = 3
check "and the message it would send" says "The Mac mini's storage needs a look:"
check "naming each condition" test "$(grep -cE '^- .*(40.0 GiB free|holds 25.0 GiB)' "$T/out")" = 2
check "it runs no upkeep" no grep -qE '^(colima|docker) ' "$T/calls"
check "it writes no state and no log" test ! -e "$STATE"
reset
watch 0 --dry-run
check "with nothing over it still prints the measurements" test "$(grep -c 'SIZE' "$T/out")" = 3
check "and says there is nothing to send" says "nothing to send"
reset
sizes 40 1 1
watch 3
watch 4 -n
check "-n after a real run records nothing" test "$(awk 'END { print NR }' "$STATE/sent")" = 1
watch 5
check "so the next real run still holds its message back" quiet
/bin/bash "$JOB" --wat >"$T/out" 2>"$T/err"
check "an unknown option is refused" test $? = 2
check "on stderr" quiet

section "its log"
reset
mkdir -p "$STATE"
seq 1 6000 >"$LOG"
watch 0
check "the log stays bounded" test "$(wc -l <"$LOG")" -lt 3000

section "with the real df and du"
reset
mkdir "$T/bin2"
cp "$T/bin/colima" "$T/bin/docker" "$T/bin/getconf" "$T/bin2/"
STORAGE_WATCH_PATH="$T/bin2:/usr/bin:/bin:/usr/sbin:/sbin" watch 0
check "both answer as the job expects" no says "failed"
check "and free space is measured" logged "GiB free"

summary
