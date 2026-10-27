#!/usr/bin/env bash
# The weekly macOS job's own checks, on the machine this runs on: CI's macOS
# runner, or a throwaway macOS VM. Never on a Mac you use: it taps and
# installs from the Brewfile and applies both Macs' settings for real.
#
#   DOTFILES_CHANGE_THIS_MAC=yes bash tests/macos-ci.sh
#
# For each Mac role, every formula and cask the Brewfile lists must still
# exist in Homebrew (App Store apps and VS Code extensions aren't checked),
# and a few from the shared block install. Then each role's settings script
# runs for real and skips nothing, a dry run right after must find nothing
# left to change, and a second apply must print nothing.
#
# Run again on the same Mac, it still passes, but each role's apply reports
# two changes: the laptop and the mini set AutomaticallyInstallMacOSUpdates
# and the automatic time zone the other way round, so each puts back what the
# other set. A Mac with one role, and CI's fresh runner, never see that.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${DOTFILES_CHANGE_THIS_MAC:-}" != yes ]; then
  echo "macos-ci: this installs from the Brewfile and changes this Mac's settings. Run it in CI, or on a throwaway VM with DOTFILES_CHANGE_THIS_MAC=yes." >&2
  exit 1
fi
if [ "$(uname)" != Darwin ] || ! command -v brew >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "macos-ci: needs macOS with Homebrew, and sudo that asks no password, as CI's runner has" >&2
  exit 1
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macos-ci.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1

roles=(laptop agent-mini)

# entries <role> <--tap|--formula|--cask>: what the Brewfile lists for a role.
entries() {
  HOMEBREW_TILDE_ROLE="$1" HOMEBREW_TILDE_MAS=0 brew bundle list --file="$REPO/Brewfile" "$2"
}
# trusted_in <tap>: "formula <name>" or "cask <name>" for each entry from that
# tap the Brewfile marks trusted: true.
trusted_in() {
  sed -n -e "s|^ *brew \"\($1/[^\"]*\)\".*trusted: true.*|formula \1|p" \
         -e "s|^ *cask \"\($1/[^\"]*\)\".*trusted: true.*|cask \1|p" "$REPO/Brewfile"
}
# unknown <--formula|--cask> <name>...: the names Homebrew doesn't know. One
# call for the lot, and one per name only when that fails, to find which.
unknown() {
  local kind="$1" name
  shift
  [ "$#" -gt 0 ] || return 0
  brew info --json=v2 "$kind" "$@" >/dev/null 2>&1 && return 0
  for name in "$@"; do
    brew info --json=v2 "$kind" "$name" >/dev/null 2>&1 || echo "$name"
  done
}

for role in "${roles[@]}"; do
  section "the Brewfile's entries for $role"
  if ! taps=$(entries "$role" --tap 2>"$work/err"); then
    fail "lists them" "$(cat "$work/err")"
    continue
  fi
  for tap in $taps; do
    brew tap --quiet "$tap" >/dev/null 2>&1 && pass "taps $tap" || fail "taps $tap"
    # Homebrew loads nothing from a tap nobody has trusted, not even for brew
    # info, and brew bundle trusts what the Brewfile marks trusted: true
    # before it installs. So the same here, and only that: an entry from this
    # tap left unmarked fails below, as brew bundle would fail on the Mac.
    while read -r kind name; do
      brew trust --quiet "--$kind" "$name" >/dev/null 2>&1 && pass "trusts $name" || fail "trusts $name"
    done < <(trusted_in "$tap")
  done
  # brew bundle list names a tap's cask without its tap; brew info finds it
  # in the tap, now trusted.
  for kind in formula cask; do
    # shellcheck disable=SC2046 # one name per word, as brew bundle lists them
    missing=$(unknown "--$kind" $(entries "$role" "--$kind"))
    count=$(entries "$role" "--$kind" | wc -l | tr -d ' ')
    [ -z "$missing" ] && pass "all $count ${kind}s exist" || fail "all $count ${kind}s exist" "missing: $missing"
  done
done

section "a few install"
printf 'brew "age"\nbrew "sops"\ncask "font-libron"\n' > "$work/Brewfile"
if out=$(brew bundle install --file="$work/Brewfile" --no-upgrade 2>&1); then
  pass "age, sops and font-libron"
else
  fail "age, sops and font-libron" "$out"
fi

# Two things the Macs have and a fresh runner doesn't, given to CI's runner so
# the blocks that need them run rather than wait for them: a key in
# authorized_keys (the mini's SSH goes key-only only while one is there, and
# only then is a keyless login checked), and iCloud Drive's folder (the
# screenshots folder goes in it). The key is throwaway: its private half goes
# with $work. Anywhere else, bring your own key, or the mini's skip fails.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  if ! grep -qE '^(ssh-|ecdsa-|sk-)' "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C macos-ci-throwaway -f "$work/ci-key" \
      && cat "$work/ci-key.pub" >> "$HOME/.ssh/authorized_keys" \
      && chmod 600 "$HOME/.ssh/authorized_keys"
  fi
  mkdir -p "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
fi

# A dry run says "dry run: N would change, M already right", and each would-be
# change on a line of its own.
for role in "${roles[@]}"; do
  section "the $role's settings"
  sandbox "$role" >/dev/null 2>&1
  script="$work/settings-$role.sh"
  if ! cz execute-template < "$REPO/home/.chezmoiscripts/run_after_30-macos-settings.sh.tmpl" > "$script" 2>"$work/err"; then
    fail "renders" "$(cat "$work/err")"
    cleanup_sandbox
    continue
  fi
  cleanup_sandbox
  if bash "$script" > "$work/apply-$role.log" 2>&1; then
    pass "applies"
  else
    fail "applies" "$(tail -40 "$work/apply-$role.log")"
  fi
  grep -q 'FAILED\|didn.t stick' "$work/apply-$role.log" \
    && fail "nothing failed or didn't stick" "$(grep 'FAILED\|didn.t stick' "$work/apply-$role.log")" \
    || pass "nothing failed or didn't stick"
  # sudo asks nothing here, so a skip is something this Mac couldn't do, and
  # a dry run doesn't always count it as a change.
  grep -qE ', [1-9][0-9]* skipped,' "$work/apply-$role.log" \
    && fail "nothing skipped" "$(cat "$work/apply-$role.log")" \
    || pass "nothing skipped"
  DOTFILES_CHECK=1 bash "$script" > "$work/check-$role.log" 2>&1
  grep -q 'dry run: 0 would change' "$work/check-$role.log" \
    && pass "a dry run after finds nothing to change" \
    || fail "a dry run after finds nothing to change" "$(cat "$work/check-$role.log")"
  # The dry run doesn't make folders, flag them hidden or write the freeze
  # marker; a second apply does, and on a Mac that's in line says nothing.
  bash "$script" > "$work/again-$role.log" 2>&1
  [ ! -s "$work/again-$role.log" ] \
    && pass "a second apply changes nothing" \
    || fail "a second apply changes nothing" "$(cat "$work/again-$role.log")"
  # A power setting this Mac doesn't have (no battery on CI's runner) has
  # nothing to set, so nothing checks it here. Listed, so the log says so.
  grep "isn't on this Mac" "$work/check-$role.log" | sed 's/^/        /'
done

summary
