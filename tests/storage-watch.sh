#!/usr/bin/env bash
# The mini's storage job, storage-watch, in a throwaway HOME with stand-ins
# for colima, docker, hermes, df, du and getconf that record each call and
# fail or hang on request, so nothing is pruned, trimmed or sent. Last, the
# plist and the apply script that loads it, with a stand-in launchctl.
#
#   bash tests/storage-watch.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

# The job runs on the mini only, and its plist is read with plutil.
if [ "$(uname)" != Darwin ]; then
  echo "storage-watch: the job runs on the mini only; nothing to check here"
  exit 0
fi

JOB="$REPO/home/dot_local/bin/executable_storage-watch"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/storage-watch.XXXXXX")" && pwd -P)"
trap 'rm -rf -- "$T"' EXIT
export HOME="$T/home" TMPDIR="$T/tmp"
STATE="$HOME/Library/Logs/storage-watch"
LOG="$STATE/storage-watch.log"
mkdir -p "$T/bin" "$T/tmp" "$T/usertemp" "$T/mode" "$HOME/.local/bin" "$HOME/agent-drafts" "$HOME/.colima/default"
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
stub hermes <<EOF
cat >"$T/message"
echo sent >>"$T/sent"
EOF
mv "$T/bin/hermes" "$HOME/.local/bin/hermes"

# Never the real colima, docker or hermes: the job's PATH has only system tools.
export STORAGE_WATCH_PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
G=1048576
BASE=1800000000

reset() { # a fresh state, Colima up, nothing over a limit
  rm -rf "$STATE" "$T/mode" "$T/calls" "$T/sent" "$T/message"
  mkdir "$T/mode"
  : >"$T/calls"
  : >"$T/sent"
  sizes 200 1 1
}
sizes() { echo $(($1 * G)) >"$T/free"; echo $(($2 * G)) >"$T/temp"; echo $(($3 * G)) >"$T/drafts"; }
watch() { # hours since the first run, then the job's options
  local h=$1
  shift
  STORAGE_WATCH_NOW=$((BASE + h * 3600)) /bin/bash "$JOB" "$@" >"$T/out" 2>&1
  RC=$?
}
sent() { awk 'END { print NR }' "$T/sent"; }
called() { grep -Fqx -- "$1" "$T/calls"; }
check() { # what, then the command that must succeed
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what" "$(cat "$T/out")"; fi
}
says() { grep -Fq -- "$1" "$T/message" 2>/dev/null; }
logged() { grep -Fq -- "$1" "$LOG" 2>/dev/null; }
no() { ! "$@"; }

PRUNE="docker --context colima builder prune --all --force --max-used-space 15GB"
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
check "with nothing over a limit it sends nothing" test "$(sent)" = 0
check "it logs what the trim freed" logged "30 GiB trimmed"
check "Colima's config is untouched" test "$(cat "$HOME/.colima/default/colima.yaml")" = "docker: {}"
check "it deletes nothing on the Mac" test -f "$HOME/agent-drafts/keep" -a -f "$T/usertemp/keep"

reset
touch "$T/mode/stopped"
sizes 40 1 1
watch 0
check "with Colima stopped, only its status is asked" test "$(grep -E '^(colima|docker) ' "$T/calls")" = "colima status"
check "and that is no failure" test "$RC" = 0
check "and the alert still goes" says "40.0 GiB free"

section "a failure in one never skips the other"
for bad in docker trim; do
  for how in fail hang; do
    reset
    echo "$how" >"$T/mode/$bad"
    sizes 40 1 1
    STORAGE_WATCH_TIMEOUT=1 watch 0
    check "$bad $how: the prune and the trim both ran" test "$(grep -cF -e "$PRUNE" -e "$TRIM" "$T/calls")" = 2
    check "$bad $how: the alert still goes" test "$(sent)" = 1
    check "$bad $how: the run says it failed" test "$RC" != 0
    check "$bad $how: and logs it" logged "FAILED"
  done
done
for how in fail hang; do
  reset
  echo "$how" >"$T/mode/colima"
  sizes 40 1 1
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "colima status $how: no upkeep" no called "$PRUNE"
  check "colima status $how: the alert still goes" test "$(sent)" = 1
  check "colima status $how: the run says it failed, unlike a stopped Colima" test "$RC" != 0
done
check "a status that hangs is logged as a timeout" logged "timed out after 1s"
for how in fail hang; do
  reset
  echo "$how" >"$T/mode/df"
  sizes 200 25 1
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "df $how: the upkeep ran" called "$TRIM"
  check "df $how: the other sizes still alert" says "25.0 GiB"
  check "df $how: the run says it failed" test "$RC" != 0

  reset
  echo "$how" >"$T/mode/du-temp"
  sizes 200 1 25
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "du of the temp folder $how: agent-drafts still alerts" says "agent-drafts holds 25.0 GiB"
  check "du of the temp folder $how: the run says it failed" test "$RC" != 0

  reset
  echo "$how" >"$T/mode/getconf"
  sizes 40 1 1
  STORAGE_WATCH_TIMEOUT=1 watch 0
  check "getconf $how: free space still alerts" says "40.0 GiB free"
done
reset
touch "$T/mode/vanishing"
sizes 200 25 1
watch 0
check "files that vanish during du still give a size" says "25.0 GiB"
check "and are no failure" test "$RC" = 0

reset
rm "$HOME/agent-drafts/keep"
rmdir "$HOME/agent-drafts"
watch 0
check "no agent-drafts folder is no failure" test "$RC" = 0
mkdir "$HOME/agent-drafts"
echo keep >"$HOME/agent-drafts/keep"

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
reset
sizes 42 31 22
watch 0
check "one message" test "$(sent)" = 1
check "names free space with its size" says "42.0 GiB free"
check "names the temp folder with its size" says "$T/usertemp holds 31.0 GiB"
check "names agent-drafts with its size" says "agent-drafts holds 22.0 GiB"
check "it goes to Telegram as merge-notify's does" called "hermes send --to telegram -q"

section "how often it sends"
reset
sizes 40 1 1
watch 0
check "a condition sends" test "$(sent)" = 1
sizes 38 1 1
watch 3
check "the same one 3 hours later does not" test "$(sent)" = 1
sizes 38 25 1
watch 6
check "a new condition sends at once" test "$(sent)" = 2
check "naming the old one too" says "38.0 GiB free"
sizes 200 25 1
watch 9
check "fewer conditions are nothing new" test "$(sent)" = 2
sizes 38 25 1
watch 29
check "the same set waits its 24 hours from the last message" test "$(sent)" = 2
watch 30
check "and sends again after them" test "$(sent)" = 3

reset
sizes 40 1 1
echo fail >"$T/mode/hermes"
watch 0
check "a failed send fails the run" test "$RC" != 0
check "but not the upkeep" called "$TRIM"
check "and is logged" logged "hermes"
rm "$T/mode/hermes"
watch 3
check "and is retried the next run" test "$(sent)" = 1
reset
sizes 40 1 1
echo hang >"$T/mode/hermes"
STORAGE_WATCH_TIMEOUT=1 watch 0
check "a send that hangs is stopped" test "$RC" != 0
rm "$T/mode/hermes"
watch 3
check "and retried too" test "$(sent)" = 1
reset
sizes 40 1 1
mv "$HOME/.local/bin/hermes" "$T/hermes.away"
watch 0
check "with no hermes the run fails" test "$RC" != 0
mv "$T/hermes.away" "$HOME/.local/bin/hermes"
watch 3
check "and sends once there is one" test "$(sent)" = 1

section "dry run"
reset
sizes 40 25 1
watch 0 --dry-run
check "it exits 0" test "$RC" = 0
check "it prints each condition" test "$(grep -cE '40.0 GiB free|holds 25.0 GiB' "$T/out")" -ge 2
check "it runs no upkeep" no grep -qE '^(colima|docker) ' "$T/calls"
check "it sends nothing" test "$(sent)" = 0
check "it writes no state and no log" test ! -e "$STATE"
watch 3
watch 4 -n
check "-n after a real run sends nothing more" test "$(sent)" = 1
/bin/bash "$JOB" --wat >"$T/out" 2>&1
check "an unknown option is refused" test $? = 2

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
check "both answer as the job expects" test "$RC" = 0
check "and free space is measured" logged "GiB free"

section "the LaunchAgent"
LC="$T/launchctl"
P="$LC/home/Library/LaunchAgents"
PL="$P/com.carlosetejada.storage-watch.plist"
mkdir -p "$LC/bin" "$P"
cat >"$LC/bin/launchctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$LC/calls"
case \$1 in print) case \$2 in gui/*/*) exit 113 ;; esac ;; esac
exit 0
EOF
chmod +x "$LC/bin/launchctl"
if sandbox agent-mini >/dev/null 2>&1 &&
  cz execute-template <"$REPO/home/.chezmoiscripts/run_after_59-launch-agents.sh.tmpl" >"$LC/run_after.sh" 2>/dev/null &&
  cz execute-template <"$REPO/home/private_Library/LaunchAgents/com.carlosetejada.storage-watch.plist.tmpl" >"$PL" 2>/dev/null; then
  pass "the apply script and the plist render for the agent-mini"
else
  fail "the apply script and the plist render for the agent-mini"
fi
cleanup_sandbox
field() { plutil -extract "$1" raw -o - "$PL" 2>/dev/null; }
check "the plist is valid" plutil -lint -s "$PL"
check "it runs ~/.local/bin/storage-watch" test "$(field ProgramArguments.1)" = "$HOME/.local/bin/storage-watch"
check "with the system's bash" test "$(field ProgramArguments.0)" = /bin/bash
check "every 3 hours" test "$(field StartInterval)" = 10800
check "with low-priority IO" test "$(field LowPriorityIO)" = true
check "system tools first" test "$(field EnvironmentVariables.PATH)" = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
HOME="$LC/home" PATH="$LC/bin:$PATH" bash "$LC/run_after.sh" >"$T/out" 2>&1
check "the apply loads it" grep -q '^bootstrap gui/[0-9]* .*/com\.carlosetejada\.storage-watch\.plist$' "$LC/calls"
check "and says so" grep -q 'loaded the storage job (every 3 hours)' "$T/out"

summary
