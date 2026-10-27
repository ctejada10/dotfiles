# Compare-then-write wrappers around `defaults` and `pmset`, ported from the
# old tilde's scripts/lib/defaults.sh. Each setting is read first and written
# only when it differs, then read back, and every outcome is counted, so a run
# says what it changed. Root is asked for only when a root setting has drifted.
# Set DOTFILES_CHECK=1 for a dry run that writes nothing.
# Needs script-lib.sh for as_root, can_root, say and warn.

CHECK="${DOTFILES_CHECK:-0}"
CHANGED=0
UNCHANGED=0
SKIPPED=0
FAILED=0
# pmset settings this Mac doesn't have, such as a battery one on a desktop.
ABSENT=0
TOUCHED_DOMAINS=" "
UNSET="__dotfiles_unset__"

_norm() {
  [ "$2" = "$UNSET" ] && { printf '%s' "$UNSET"; return; }
  case "$1" in
    bool)
      case "$2" in
        true|TRUE|True|yes|YES|Yes|1) printf '1' ;;
        *)                            printf '0' ;;
      esac ;;
    float) printf '%g' "$2" ;;
    *) printf '%s' "$2" ;;
  esac
}

# A key that doesn't exist reads as unset, never as false or 0: macOS's own
# default for a missing key is often true.
_read() {
  local out
  case "$1" in
    host) out=$(defaults -currentHost read "$2" "$3" 2>/dev/null) || out="$UNSET" ;;
    *)    out=$(defaults read "$2" "$3" 2>/dev/null) || out="$UNSET" ;;
  esac
  printf '%s' "$out"
}

_write() {
  case "$1" in
    user) defaults write "$2" "$3" "-$4" "$5" ;;
    host) defaults -currentHost write "$2" "$3" "-$4" "$5" ;;
    root) as_root defaults write "$2" "$3" "-$4" "$5" ;;
  esac
}

# The files under /Library/Preferences are readable without root, so root
# settings are compared without asking for anything; sudo comes in only to
# write one that differs.
_apply() {
  local mode="$1" domain="$2" key="$3" type="$4" value="$5" current want
  current="$(_norm "$type" "$(_read "$mode" "$domain" "$key")")"
  want="$(_norm "$type" "$value")"
  if [ "$current" = "$want" ]; then
    UNCHANGED=$((UNCHANGED + 1))
    return 0
  fi
  [ "$current" = "$UNSET" ] && current="unset"
  if [ "$CHECK" = 1 ]; then
    say "would set $domain $key = $want (now: $current)"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  if [ "$mode" = root ] && ! can_root; then
    warn "skipped $domain $key = $want (now: $current): it needs sudo, which would ask for a password. The next attended apply sets it."
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if ! _write "$mode" "$domain" "$key" "$type" "$value"; then
    warn "FAILED to set $domain $key"
    FAILED=$((FAILED + 1))
    return 0
  fi
  if [ "$(_norm "$type" "$(_read "$mode" "$domain" "$key")")" = "$want" ]; then
    say "set $domain $key = $want"
    CHANGED=$((CHANGED + 1))
    TOUCHED_DOMAINS="$TOUCHED_DOMAINS$domain "
  else
    warn "$domain $key didn't stick: it still reads $(_read "$mode" "$domain" "$key"), not $want"
    FAILED=$((FAILED + 1))
  fi
}

# defaults_set <domain> <key> <type> <value>
defaults_set()      { _apply user "$@"; }
defaults_set_host() { _apply host "$@"; }
defaults_set_root() { _apply root "$@"; }

# defaults_unset <domain> <key>: back to macOS's own default.
defaults_unset() {
  if [ "$(_read user "$1" "$2")" = "$UNSET" ]; then
    UNCHANGED=$((UNCHANGED + 1))
    return 0
  fi
  if [ "$CHECK" = 1 ]; then
    say "would remove $1 $2"
  else
    defaults delete "$1" "$2" && say "removed $1 $2"
    TOUCHED_DOMAINS="$TOUCHED_DOMAINS$1 "
  fi
  CHANGED=$((CHANGED + 1))
}

# pmset -g custom prints one block per power source ("Battery Power:", "AC
# Power:"), each listing only the settings this Mac has for that source. A
# desktop has only the AC block, and a virtual Mac (CI's runner, a test VM)
# also lists no womp, autorestart, hibernatemode or powermode. pmset takes a
# write to a setting that isn't listed and changes nothing, so it would never
# stick and every dry run would want it again. Such a setting has nothing to
# set: it counts as not on this Mac, which only a dry run mentions. Read once
# and again after writes.
PMSET_CUSTOM=""
_pm_refresh() { PMSET_CUSTOM=$(pmset -g custom 2>/dev/null); }
_pm_sections() {
  case "$1" in
    -b) echo "Battery Power" ;;
    -c) echo "AC Power" ;;
    -a) printf '%s\n' "$PMSET_CUSTOM" | sed -n 's/^\([A-Za-z][A-Za-z ]*\):$/\1/p' ;;
  esac
}
_pm_value() {
  printf '%s\n' "$PMSET_CUSTOM" | awk -v s="$1:" -v k="$2" '
    /^[A-Za-z].*:$/ { in_s = ($0 == s); next }
    in_s && $1 == k { print $2; exit }'
}
# _pm_targets <flag> <key>: the blocks the flag writes that list the key.
_pm_targets() {
  local section
  while IFS= read -r section; do
    [ -z "$(_pm_value "$section" "$2")" ] || printf '%s\n' "$section"
  done < <(_pm_sections "$1")
}
_pm_drift() {
  local section
  while IFS= read -r section; do
    [ "$(_pm_value "$section" "$1")" = "$2" ] || return 0
  done < <(_pm_targets "$3" "$1")
  return 1
}

# pm_set <-a|-b|-c> <key> <value>. Written, then read back and tried once
# more, because some values (disksleep, for one) have been seen not to stick
# on the first try.
pm_set() {
  local flag="$1" key="$2" value="$3"
  [ -n "$(_pm_sections -a)" ] || _pm_refresh
  # No blocks at all is pmset failing, not a Mac without the setting: whether
  # it printed nothing or only a line that isn't a block.
  if [ -z "$(_pm_sections -a)" ]; then
    if [ "$CHECK" = 1 ]; then
      say "would run pmset $flag $key $value (pmset -g custom printed no power blocks to compare with)"
      CHANGED=$((CHANGED + 1))
    else
      warn "FAILED to check pmset $flag $key $value: pmset -g custom printed no power blocks"
      FAILED=$((FAILED + 1))
    fi
    return 0
  fi
  if [ -z "$(_pm_targets "$flag" "$key")" ]; then
    ABSENT=$((ABSENT + 1))
    [ "$CHECK" = 1 ] && say "pmset $flag $key isn't on this Mac: nothing to set"
    return 0
  fi
  if ! _pm_drift "$key" "$value" "$flag"; then
    UNCHANGED=$((UNCHANGED + 1))
    return 0
  fi
  if [ "$CHECK" = 1 ]; then
    say "would run pmset $flag $key $value"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  if ! can_root; then
    warn "skipped pmset $flag $key $value: sudo would ask for a password. The next attended apply sets it."
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  for _ in 1 2; do
    as_root pmset "$flag" "$key" "$value" >/dev/null 2>&1
    _pm_refresh
    _pm_drift "$key" "$value" "$flag" || break
  done
  # With no blocks to read back, nothing would show as drifting, so the write
  # would pass as set without having been seen.
  if [ -z "$(_pm_sections -a)" ]; then
    warn "FAILED to read back pmset $flag $key $value: pmset -g custom printed no power blocks"
    FAILED=$((FAILED + 1))
  elif _pm_drift "$key" "$value" "$flag"; then
    warn "pmset $flag $key $value didn't stick (pmset -g custom shows otherwise)"
    FAILED=$((FAILED + 1))
  else
    say "set pmset $flag $key $value"
    CHANGED=$((CHANGED + 1))
  fi
}

# Restarts the apps whose settings changed, so they take effect now.
restart_touched() {
  [ "$CHECK" = 1 ] && return 0
  case "$TOUCHED_DOMAINS" in *" com.apple.dock "*) killall Dock 2>/dev/null ;; esac
  case "$TOUCHED_DOMAINS" in *" com.apple.finder "*) killall Finder 2>/dev/null ;; esac
  case "$TOUCHED_DOMAINS" in *" com.apple.screencapture "*|*" NSGlobalDomain "*) killall SystemUIServer 2>/dev/null ;; esac
  return 0
}

# Quiet when nothing changed, so a routine apply prints nothing.
defaults_summary() {
  local absent=""
  [ "$ABSENT" -eq 0 ] || absent=", $ABSENT not on this Mac"
  if [ "$CHECK" = 1 ]; then
    # Skipped and failed only when there are any, so a clean dry run reads the
    # same as ever; dotfiles update and doctor count them as not matching.
    local trouble=""
    [ $((SKIPPED + FAILED)) -eq 0 ] || trouble=", $SKIPPED skipped, $FAILED failed"
    say "dry run: $CHANGED would change, $UNCHANGED already right$trouble$absent"
  elif [ $((CHANGED + SKIPPED + FAILED)) -gt 0 ]; then
    say "$CHANGED changed, $UNCHANGED already right, $SKIPPED skipped, $FAILED failed"
  fi
}
