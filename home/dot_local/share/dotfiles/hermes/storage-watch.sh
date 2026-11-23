#!/bin/bash
#
# storage-watch: keep development sessions from filling the mini's disk.
#
# A Hermes cron job runs it every 3 hours with no agent and sends what it
# prints to Telegram as it is, so stdout holds the message and nothing else,
# and empty stdout sends nothing. Each run does two things, and a failure in
# one never skips the other:
#
# 1. Colima's upkeep, only while Colima is running, which it never starts,
#    stops or restarts: cut the build cache down to 15GB, then trim the
#    Docker disk. Colima's own weekly fstrim only reads /etc/fstab, so it
#    never trims that disk. Images, containers, volumes and Colima's config
#    are never touched.
# 2. One message when free space is under 50 GiB, or the per-user temp folder
#    or ~/agent-drafts is over 20 GiB, measured after the upkeep. A step that
#    failed is a condition of its own, keyed by its step, and the message
#    names only the step: what a tool said goes to the log alone. It prints
#    when a condition hasn't been in a message for 24 hours, so the same set
#    goes at most once a day and a new one at once.
#
# It exits 0 after any run it could make, so Hermes delivers the message, and
# non-zero only when it can't run at all, for Hermes's own failure notice. It
# deletes nothing on the Mac.
#
# Usage: storage-watch.sh [--dry-run]

set -u
umask 077

PROG=storage-watch
# Hermes can hand its scripts a profile's HOME; colima, docker and the
# folders measured here are in the real one.
HOME=${HERMES_REAL_HOME:-$HOME}
export HOME
DRY_RUN=0
STATE_DIR="$HOME/Library/Logs/storage-watch"
LOG_FILE="$STATE_DIR/storage-watch.log"
SENT_FILE="$STATE_DIR/sent"
LOG_MAX_LINES=5000
FREE_MIN_GIB=50
FOLDER_MAX_GIB=20
KIB_PER_GIB=1048576
RESEND_AFTER=86400
TAB=$(printf '\t')

# System tools come first, as in worktree-ttl. colima needs limactl and
# docker its plugins, which are in Homebrew's bin.
PATH=${STORAGE_WATCH_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin}
LC_ALL=C
export PATH LC_ALL
NOW=${STORAGE_WATCH_NOW:-$(date +%s)}

usage() {
  cat <<'EOF'
Usage: storage-watch.sh [options]

  -n, --dry-run   Print each measurement and the message it would send: no
                  upkeep, no state, no log.
  -h, --help      Show this help.

It logs to ~/Library/Logs/storage-watch/storage-watch.log.
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    -n | --dry-run) DRY_RUN=1 ;;
    -h | --help) usage; exit 0 ;;
    *) printf '%s: unknown option: %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- helpers

# The log goes to its file, or to stdout on a dry run, never both: a real
# run's stdout is the message.
log() {
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
  if [ "$DRY_RUN" = 1 ]; then printf '%s\n' "$line"; else printf '%s\n' "$line" >>"$LOG_FILE"; fi
}

# failed KEY STEP [DETAIL]: a step that broke. The message names the step
# only; DETAIL, which tools write, goes to the log printable and cut short.
failed() {
  printf 'failed-%s\tfailed: %s (see the storage log)\n' "$1" "${2//$TAB/ }" >>"$TMP/over"
  log "FAILED  $2${3+: $(printf '%s' "$3" | tr -cd '[:print:]' | cut -c 1-200)}"
}

# timed SECONDS INPUT COMMAND...: the command with worktree-ttl's watchdog,
# its output in $TMP/out and $TMP/err. Exit 124 when it ran out of time.
timed() {
  local limit=${STORAGE_WATCH_TIMEOUT:-$1} input=$2 pid ticks=0
  shift 2
  "$@" <"$input" >"$TMP/out" 2>"$TMP/err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 5)) ]; then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "timed out after ${limit}s" >"$TMP/err"
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

said() { tail -n 1 "$TMP/$1" 2>/dev/null; }
gib() { awk -v k="$1" -v g="$KIB_PER_GIB" 'BEGIN { printf "%.1f", k / g }'; }

# ----------------------------------------------------------------- upkeep

upkeep() {
  if ! timed 60 /dev/null colima status; then
    # Stopped and broken both exit 1, so only its own words say stopped.
    if grep -q 'is not running' "$TMP/err"; then log "SKIP    upkeep: Colima isn't running"
    else failed status "colima status" "$(said err)"; fi
    return
  fi
  # docker builder is buildx's alias, which prunes the builder buildx has
  # selected unless one is named.
  if timed 900 /dev/null docker --context colima builder prune --builder colima --all --force --max-used-space 15GB; then
    log "PRUNED  build cache: $(said out)"
  else
    failed prune "docker builder prune" "$(said err)"
  fi
  if timed 600 /dev/null colima ssh -- sudo -n fstrim -v /mnt/lima-colima; then
    log "TRIMMED $(said out)"
  else
    failed trim "fstrim in Colima" "$(said err)"
  fi
}

# ------------------------------------------------------------------ alert

# over KEY TEXT: one condition, for the message and for what was last sent.
over() {
  printf '%s\t%s\n' "$1" "$2" >>"$TMP/over"
  log "OVER    $2"
}

measure_free() {
  local free
  if ! timed 30 /dev/null df -kP /System/Volumes/Data; then
    failed df df "$(said err)"
    return
  fi
  free=$(awk 'NR == 2 { print $4 }' "$TMP/out")
  case $free in '' | *[!0-9]*) failed df df "it printed no free space"; return ;; esac
  log "SIZE    $(gib "$free") GiB free"
  if [ "$free" -lt $((FREE_MIN_GIB * KIB_PER_GIB)) ]; then
    over free "$(gib "$free") GiB free on the Data volume, under $FREE_MIN_GIB"
  fi
}

# du exits 1 for a file that went while it ran, with its total all the same,
# so only a missing total is a failure.
measure_folder() {
  local key=$1 dir=$2 used
  [ -e "$dir" ] || return 0
  # Every limit together stays under Hermes's cron.script_timeout_seconds, 3600.
  timed 900 /dev/null du -skxH "$dir"
  used=$(awk 'END { print $1 }' "$TMP/out")
  case $used in '' | *[!0-9]*) failed "du-$key" "du $dir" "$(said err)"; return ;; esac
  log "SIZE    $dir holds $(gib "$used") GiB"
  if [ "$used" -gt $((FOLDER_MAX_GIB * KIB_PER_GIB)) ]; then
    over "$key" "$dir holds $(gib "$used") GiB, over $FOLDER_MAX_GIB"
  fi
}

measure() {
  local dir
  measure_free
  if timed 30 /dev/null getconf DARWIN_USER_TEMP_DIR && dir=$(said out) && [ -n "$dir" ]; then
    measure_folder temp "${dir%/}"
  else
    failed getconf "getconf DARWIN_USER_TEMP_DIR" "$(said err)"
  fi
  measure_folder drafts "$HOME/agent-drafts"
}

# Whether any condition hasn't been in a message for RESEND_AFTER seconds.
due() {
  local key last
  while IFS="$TAB" read -r key _; do
    last=$(awk -F '\t' -v k="$key" '$1 == k { t = $2 } END { print t }' "$SENT_FILE" 2>/dev/null)
    case $last in '' | *[!0-9]*) return 0 ;; esac
    if [ "$last" -gt "$NOW" ] || [ $((NOW - last)) -ge "$RESEND_AFTER" ]; then return 0; fi
  done <"$TMP/over"
  return 1
}

message() {
  echo "The Mac mini's storage needs a look:"
  cut -f2 "$TMP/over" | sed 's/^/- /'
}

notify() {
  local keys
  if [ "$DRY_RUN" = 1 ]; then
    if [ -s "$TMP/over" ]; then
      echo "WOULD   send this, unless it went in the last 24 hours:"
      message
    else
      echo "WOULD   send nothing: nothing to send"
    fi
    return 0
  fi
  [ -s "$TMP/over" ] || return 0
  due || return 0
  keys=$(cut -f1 "$TMP/over" | sort -u)
  # Recorded before it prints: a record that fails, as on a full disk, is
  # said in the message, which then may repeat every run.
  # What is sent now, then when each other condition last was.
  if {
    awk -v now="$NOW" '{ print $0 "\t" now }' <<<"$keys" &&
      { [ ! -f "$SENT_FILE" ] || awk -F '\t' 'FILENAME == ARGV[1] { now[$1] = 1; next } !($1 in now)' "$TMP/over" "$SENT_FILE"; }
  } 2>/dev/null >"$SENT_FILE.tmp" && mv -- "$SENT_FILE.tmp" "$SENT_FILE" 2>/dev/null; then
    message
  else
    log "FAILED  could not record what was sent, so it may repeat"
    message
    echo "This alert couldn't be recorded, so it may repeat."
  fi
  log "SENT    $(tr '\n' ' ' <<<"$keys")"
}

# ------------------------------------------------------------------- main

if [ "$DRY_RUN" = 0 ]; then
  # With nowhere to log or to keep what was sent, every run would repeat
  # itself, so it is a run it can't make.
  mkdir -p -- "$STATE_DIR" || exit 1
  if [ -f "$LOG_FILE" ] && [ "$(wc -l <"$LOG_FILE")" -gt "$LOG_MAX_LINES" ]; then
    tail -n $((LOG_MAX_LINES / 2)) "$LOG_FILE" >"$LOG_FILE.tmp" && mv -- "$LOG_FILE.tmp" "$LOG_FILE"
  fi
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/$PROG.XXXXXX") || exit 1
trap 'rm -r -- "$TMP" 2>/dev/null' EXIT
: >"$TMP/over"

[ "$DRY_RUN" = 1 ] || upkeep
measure
notify
exit 0
