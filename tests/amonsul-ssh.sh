#!/usr/bin/env bash
# The laptop's `ssh amonsul`, over the tailnet: its SSH config and the pinned
# host key. macOS only.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ "$(uname)" = Darwin ] || { echo "amonsul-ssh: macOS only, skipped"; exit 0; }

key=$(sed -n 's/^    hostKey: "\(.*\)"$/\1/p' "$REPO/home/.chezmoidata/hosts.yaml")

section "the laptop's SSH config"
sandbox laptop >/dev/null 2>&1
cz apply --exclude=scripts,externals >/dev/null 2>&1
cfg="$SANDBOX/home/.ssh/config"
g() { ssh -G -F "$cfg" "$1" 2>/dev/null | grep -Ei "^$2 " | cut -d' ' -f2-; }
got="$(g amonsul hostname)|$(g amonsul hostkeyalias)|$(g amonsul user)|$(g amonsul identitiesonly)|$(g amonsul proxycommand)|$(g amonsul serveraliveinterval)|$(g amonsul forwardagent)"
[ "$got" = "amon-sul|amonsul|ctejada|yes||30|no" ] \
  && pass "amonsul goes to its tailnet name, with no proxy" || fail "amonsul goes to its tailnet name, with no proxy" "$got"
# Like the servers: one Host line, the name and then the address.
names=$(grep -i '^Host .*amon' "$cfg")
[ "$names" = "Host amonsul amon-sul" ] && pass "the mini has one Host line, name and address" || fail "the mini has one Host line, name and address" "$names"
[ "$(g amon-sul hostkeyalias)" = amonsul ] && pass "its address checks the same pinned key" || fail "its address checks the same pinned key" "$(g amon-sul hostkeyalias)"
# shellcheck disable=SC2088 # ssh -G prints the ~ as written
[ "$(g amonsul identityfile)" = "~/.ssh/login.pub" ] && pass "offers only the login key" || fail "offers only the login key" "$(g amonsul identityfile)"
if grep -qiE 'cloudflare|cf-amonsul|middlearth' <<< "$(grep -A12 -i '^Host amonsul' "$cfg")"; then fail "nothing of the tunnel is left"; else pass "nothing of the tunnel is left"; fi
[ -e "$SANDBOX/home/.ssh/cf-amonsul.sh" ] || [ -e "$SANDBOX/home/.local/bin/cf-token" ] \
  && fail "writes no tunnel helper or token tool" || pass "writes no tunnel helper or token tool"

section "the host key pin"
script="$SANDBOX/pin.sh"
cz execute-template < "$REPO/home/.chezmoiscripts/run_after_62-mac-host-keys.sh.tmpl" > "$script"
kh="$SANDBOX/home/.ssh/known_hosts"
printf 'github.com ssh-ed25519 AAAAgithub\namonsul ssh-ed25519 AAAAstale\namon-sul ssh-ed25519 AAAAold\namon-sul.local,192.0.2.1 ssh-ed25519 AAAAold\n' > "$kh"
HOME="$SANDBOX/home" bash "$script" </dev/null >/dev/null 2>&1
[ "$(grep -c '^amonsul ' "$kh")" = 1 ] && grep -qxF "amonsul $key" "$kh" \
  && pass "replaces a stale entry with the mini's key" || fail "replaces a stale entry with the mini's key" "$(cat "$kh")"
grep -q '^amon-sul' "$kh" && fail "forgets the mini's other names" "$(cat "$kh")" || pass "forgets the mini's other names"
grep -qxF 'github.com ssh-ed25519 AAAAgithub' "$kh" && pass "leaves other hosts alone" || fail "leaves other hosts alone" "$(cat "$kh")"
before=$(cat "$kh")
out=$(HOME="$SANDBOX/home" bash "$script" </dev/null 2>&1)
[ "$(cat "$kh")" = "$before" ] && [ -z "$out" ] && pass "a second run changes and says nothing" || fail "a second run changes and says nothing" "$out"

cleanup_sandbox
summary
