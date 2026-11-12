#!/usr/bin/env bash
# The laptop's `ssh amonsul`, through the Cloudflare Tunnel: its SSH config,
# the helper ssh runs as ProxyCommand, the service token in the Keychain
# (a throwaway keychain here) and the pinned host key. macOS only.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ "$(uname)" = Darwin ] || { echo "cf-amonsul: macOS only, skipped"; exit 0; }

key=$(sed -n 's/^      hostKey: "\(.*\)"$/\1/p' "$REPO/home/.chezmoidata/hosts.yaml")

section "the laptop's SSH config"
sandbox laptop >/dev/null 2>&1
cz apply --exclude=scripts,externals >/dev/null 2>&1
cfg="$SANDBOX/home/.ssh/config"
g() { ssh -G -F "$cfg" "$1" 2>/dev/null | grep -Ei "^$2 " | cut -d' ' -f2-; }
got="$(g amonsul hostname)|$(g amonsul hostkeyalias)|$(g amonsul user)|$(g amonsul identitiesonly)|$(g amonsul proxycommand)|$(g amonsul serveraliveinterval)|$(g amonsul forwardagent)"
[ "$got" = "amonsul.middlearth.io|amonsul|ctejada|yes|~/.ssh/cf-amonsul.sh %h|30|no" ] \
  && pass "amonsul goes through the tunnel" || fail "amonsul goes through the tunnel" "$got"
# Like the servers: one Host line, the name and then the address.
names=$(grep -i '^Host .*amon' "$cfg")
[ "$names" = "Host amonsul amonsul.middlearth.io" ] && pass "the mini has one Host line, name and address" || fail "the mini has one Host line, name and address" "$names"
# shellcheck disable=SC2088 # ssh -G prints the ~ as written
[ "$(g amonsul.middlearth.io proxycommand)" = "~/.ssh/cf-amonsul.sh %h" ] && pass "its address goes through the tunnel too" || fail "its address goes through the tunnel too"
# shellcheck disable=SC2088 # ssh -G prints the ~ as written
[ "$(g amonsul identityfile)" = "~/.ssh/login.pub" ] && pass "offers only the login key" || fail "offers only the login key" "$(g amonsul identityfile)"
# ssh -G doesn't print UseKeychain, so look in the file.
[ "$(grep -c '^  UseKeychain yes$' "$cfg")" = 1 ] && pass "uses the Keychain" || fail "uses the Keychain"

helper="$SANDBOX/home/.ssh/cf-amonsul.sh"
[ "$(stat -f %Lp "$helper" 2>/dev/null)" = 700 ] && pass "writes cf-amonsul.sh as 0700" || fail "writes cf-amonsul.sh as 0700"
zsh -n "$helper" 2>/dev/null && pass "cf-amonsul.sh parses" || fail "cf-amonsul.sh parses"
if grep -qE -- '--(id|secret|service-token)' "$helper"; then fail "passes the token only in the environment"; else pass "passes the token only in the environment"; fi

section "cf-token, against a throwaway keychain"
export CF_TOKEN_KEYCHAIN="$SANDBOX/test.keychain-db"
security create-keychain -p test "$CF_TOKEN_KEYCHAIN" && security unlock-keychain -p test "$CF_TOKEN_KEYCHAIN"
tok="$SANDBOX/home/.local/bin/cf-token"
val() { security find-generic-password -s cf-access-amonsul -a "$1" -w "$CF_TOKEN_KEYCHAIN" 2>/dev/null; }
if "$tok" status; then fail "status says missing at first"; else pass "status says missing at first"; fi
printf 'a1b2.access\ns3cr3t\n' | "$tok" >/dev/null 2>&1
[ "$(val id)|$(val secret)" = "a1b2.access|s3cr3t" ] && pass "stores the ID and the secret" || fail "stores the ID and the secret" "$(val id)|$(val secret)"
"$tok" status && pass "status says present after" || fail "status says present after"
printf 'other.access\nother\n' | "$tok" >/dev/null 2>&1
[ "$(val id)" = a1b2.access ] && pass "asks nothing once both are stored" || fail "asks nothing once both are stored" "$(val id)"
printf 'new.access\nn3w\n' | "$tok" rotate >/dev/null 2>&1
[ "$(val id)|$(val secret)" = "new.access|n3w" ] && pass "rotate overwrites both" || fail "rotate overwrites both" "$(val id)|$(val secret)"
if printf 'bad id" -s x\nx\n' | "$tok" rotate >/dev/null 2>&1; then fail "refuses a value it can't pass safely"; else pass "refuses a value it can't pass safely"; fi
[ "$(val id)" = new.access ] && pass "and keeps the old one" || fail "and keeps the old one" "$(val id)"

section "the host key pin"
script="$SANDBOX/pin.sh"
cz execute-template < "$REPO/home/.chezmoiscripts/run_after_62-amonsul-tunnel.sh.tmpl" > "$script"
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

security delete-keychain "$CF_TOKEN_KEYCHAIN" 2>/dev/null
cleanup_sandbox

section "other roles"
sandbox agent-mini >/dev/null 2>&1
list=$(cz managed --include=all --path-style=relative 2>/dev/null)
if grep -qxE '\.ssh/cf-amonsul\.sh|\.local/bin/cf-token' <<< "$list"; then fail "the mini has no tunnel client"; else pass "the mini has no tunnel client"; fi
cleanup_sandbox

summary
