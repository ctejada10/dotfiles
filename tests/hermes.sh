#!/usr/bin/env bash
# tilde's adoption of Hermes on the mini: which roles get it, what the off
# switches keep out, and the apply script in a fake home with a stand-in hermes,
# op, security, launchctl, pmset and sudo.
#
#   bash tests/hermes.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

sync=$REPO/home/dot_local/bin/executable_hermes-config-sync
ON='{"hermes":{"secrets":{"enabled":true},"hurin":{"enabled":true,"host":"dor-lomin.test","port":8000,"webhookHost":"100.64.0.1","telegramChatId":"1","bridge":{"tag":"bridge-v1","port":8001}}}}'

roles=(ci laptop)
[ "$(uname)" = Linux ] && roles=(ci server)
for role in "${roles[@]}"; do
  section "role $role gets nothing Hermes-related"
  sandbox "$role" >/dev/null 2>&1
  bad=$(cz managed --include=files 2>/dev/null | grep -i -E 'hermes|hurin' || true)
  script=$(cz execute-template <"$REPO/home/.chezmoiscripts/run_after_61-hermes.sh.tmpl")
  cleanup_sandbox
  [ -z "$bad" ] && pass "manages no Hermes or Hurin file" || fail "manages no Hermes or Hurin file" "$bad"
  [ -z "$script" ] && pass "its apply script renders empty, so it never runs" || fail "its apply script renders empty, so it never runs"
done

section "hermes-config-sync env"
T=$(mktemp -d "${TMPDIR:-/tmp}/hermes-test.XXXXXX")
printf 'OWN=mine\nTOKEN=old\n' >"$T/target"
printf '# a comment\nTOKEN=s3cret\n' >"$T/rendered"
out=$(python3 -B "$sync" env "$T/rendered" "$T/target")
[ "$out" = changed ] && pass "says only that it changed" || fail "says only that it changed" "$out"
grep -q '^OWN=mine$' "$T/target" && pass "keeps lines it doesn't own" || fail "keeps lines it doesn't own"
[ "$(grep -c '^TOKEN=' "$T/target")" = 1 ] && grep -q '^TOKEN=s3cret$' "$T/target" \
  && pass "replaces a key it owns" || fail "replaces a key it owns" "$(grep -c TOKEN "$T/target")"
perm=$(stat -f %Lp "$T/target" 2>/dev/null || stat -c %a "$T/target")
[ "$perm" = 600 ] && pass "writes mode 600" || fail "writes mode 600" "$perm"
before=$(cat "$T/target")
out=$(python3 -B "$sync" env "$T/rendered" "$T/target")
[ -z "$out" ] && [ "$before" = "$(cat "$T/target")" ] && pass "changes nothing on a second run" || fail "changes nothing on a second run" "$out"

section "hermes-config-sync config"
mkdir -p "$T/bin"
cat >"$T/bin/hermes" <<EOF
#!/bin/bash
case "\$2" in
  get) f="$T/cfg/\$3"; if [ -f "\$f" ]; then cat "\$f"; else echo "Config key not set: \$3"; fi ;;
  set) echo "\$3" >>"$T/sets"; python3 -c 'import json,sys
v=sys.argv[1]
try:
    j=json.loads(v)
except ValueError:
    j=v
print("\n".join("- "+x for x in j) if isinstance(j,list) and j else "[]" if j==[] else v)' "\$4" >"$T/cfg/\$3" ;;
esac
EOF
chmod +x "$T/bin/hermes"
mkdir -p "$T/cfg"
printf 'smart\n' >"$T/cfg/approvals.mode"
printf -- '- shell:rm\n' >"$T/cfg/command_allowlist"
cat >"$T/want.json" <<'EOF'
{"approvals.mode":"smart","approvals.deny":["*curl *"],"command_allowlist":[],"web.keyless_fallback":false,"mcp_servers.a":{"url":"u"}}
EOF
out=$(HERMES_BIN=$T/bin/hermes python3 -B "$sync" config "$T/want.json" "$T/state.json")
grep -q 'removed from command_allowlist: shell:rm' <<<"$out" && pass "reports an allowlist entry it removes" || fail "reports an allowlist entry it removes" "$out"
grep -qx 'approvals.mode' "$T/sets" && fail "leaves a key that matches alone" || pass "leaves a key that matches alone"
grep -qx 'mcp_servers.a' "$T/sets" && pass "sets a map" || fail "sets a map"
out=$(HERMES_BIN=$T/bin/hermes python3 -B "$sync" config "$T/want.json" "$T/state.json")
[ -z "$out" ] && pass "changes nothing on a second run" || fail "changes nothing on a second run" "$out"
rm -rf "$T"

if [ "$(uname)" != Darwin ]; then
  summary
  exit
fi

section "role agent-mini, switches off"
sandbox agent-mini >/dev/null 2>&1
list=$(cz managed --include=files 2>/dev/null)
for f in .local/bin/hermes-config-sync .local/bin/hermes-health .local/share/dotfiles/hermes/SKILL.md Library/LaunchAgents/com.carlosetejada.hermes-logs.plist; do
  grep -qx "$f" <<<"$list" && pass "manages $f" || fail "manages $f"
done
grep -q 'hurin-bridge\|bridge.env' <<<"$list" && fail "has no bridge" || pass "has no bridge"
grep -q '^\.hermes' <<<"$list" && fail "manages nothing in ~/.hermes" "$(grep '^\.hermes' <<<"$list")" || pass "manages nothing in ~/.hermes"
off=$(cz cat "$SANDBOX/home/.local/share/dotfiles/hermes/config.json")
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["command_allowlist"]==[] and d["approvals.mode"]=="smart" and not any("hurin" in k or k.startswith("platforms") for k in d)' <<<"$off" \
  && pass "config has no Hurin keys and an empty allowlist" || fail "config has no Hurin keys and an empty allowlist" "$off"
off_script=$(cz --override-data '{"hermes":{"secrets":{"enabled":true}}}' execute-template <"$REPO/home/.chezmoiscripts/run_after_61-hermes.sh.tmpl")
grep -q 'op://Hermes/Telegram' <<<"$off_script" && pass "renders the Telegram secrets" || fail "renders the Telegram secrets"
grep -q 'op://Hermes/Hurin' <<<"$off_script" && fail "renders no Hurin secrets" || pass "renders no Hurin secrets"

section "role agent-mini, switches on"
script=$REPO/home/.chezmoiscripts/run_after_61-hermes.sh.tmpl
on=$(cz --override-data "$ON" execute-template <"$REPO/home/dot_local/share/dotfiles/hermes/config.json.tmpl")
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert len(d["command_allowlist"])==5 and all(e.startswith("mcp:hurin_act/") for e in d["command_allowlist"])
assert d["mcp_servers.hurin_read"]["trust"]=="full" and d["mcp_servers.hurin_act"]["trust"]=="untrusted"
assert d["mcp_servers.hurin_act"]["url"]=="http://dor-lomin.test:8000/mcp/act"
assert d["platforms.webhook"]["extra"]["host"]=="100.64.0.1"
assert "s3" not in json.dumps(d) and "${HURIN_MCP_ACT_TOKEN}" in json.dumps(d)
' <<<"$on" && pass "config has the five allowlist entries, both servers and the bound route" || fail "config has the five allowlist entries, both servers and the bound route" "$on"
for t in "$script" "$REPO/home/dot_local/bin/executable_hermes-health.tmpl" "$REPO/home/.chezmoiscripts/run_after_59-launch-agents.sh.tmpl"; do
  for data in '{}' "$ON"; do
    cz --override-data "$data" execute-template <"$t" | bash -n && pass "$(basename "$t") parses" || fail "$(basename "$t") parses"
  done
done
plist=$(cz --override-data "$ON" execute-template <"$REPO/home/private_Library/LaunchAgents/com.carlosetejada.hurin-bridge.plist.tmpl")
plutil -lint - <<<"$plist" >/dev/null && pass "the bridge plist is valid" || fail "the bridge plist is valid"

section "the apply script"
F=$(mktemp -d "${TMPDIR:-/tmp}/hermes-apply.XXXXXX")
mkdir -p "$F/home/.hermes/skills/x" "$F/home/.local/bin" "$F/home/.local/share/dotfiles/hermes" "$F/stub" "$F/cfg"
printf 'model: x\n' >"$F/home/.hermes/config.yaml"
printf 'OWN=mine\n' >"$F/home/.hermes/.env"
cp "$sync" "$F/home/.local/bin/hermes-config-sync"; chmod +x "$F/home/.local/bin/hermes-config-sync"
cp "$REPO/home/dot_local/share/dotfiles/hermes/SKILL.md" "$F/home/.local/share/dotfiles/hermes/"
printf '{"approvals.mode":"smart"}\n' >"$F/home/.local/share/dotfiles/hermes/config.json"
cat >"$F/home/.local/bin/hermes" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "--version "*) echo "Hermes Agent v\$(cat "$F/version") (x)" ;;
  "config get") if [ -f "$F/cfg/\$3" ]; then cat "$F/cfg/\$3"; else echo "Config key not set: \$3"; fi ;;
  "config set") echo "\$4" >"$F/cfg/\$3" ;;
  "gateway restart") echo restart >>"$F/restarts" ;;
esac
EOF
chmod +x "$F/home/.local/bin/hermes"
printf '#!/bin/sh\nprintf "TOKEN=s3cret\\n" >"$4"\n' >"$F/stub/op"
printf '#!/bin/sh\necho token\n' >"$F/stub/security"
printf '#!/bin/sh\nexit 0\n' >"$F/stub/launchctl"
printf '#!/bin/sh\nprintf " sleep 0\\n disksleep 0\\n womp 1\\n autorestart 1\\n powernap 1\\n"\n' >"$F/stub/pmset"
printf '#!/bin/sh\n[ "$1" = -n ] && shift\n[ "$1" = true ] && exit 0\necho "$*" >>"%s/root"\n' "$F" >"$F/stub/sudo"
chmod +x "$F"/stub/*
rendered=$F/apply.sh
cz --override-data '{"hermes":{"secrets":{"enabled":true}}}' execute-template <"$script" >"$rendered"
apply() { HOME="$F/home" PATH="$F/stub:$PATH" bash "$rendered" </dev/null 2>&1; }
state=$F/home/.local/state/dotfiles/hermes

printf '0.0.1' >"$F/version"
out=$(apply); code=$?
[ "$code" = 1 ] && grep -q 'tilde pins' <<<"$out" && [ ! -d "$state" ] && [ ! -f "$F/restarts" ] \
  && pass "a version off the pin stops before touching anything" || fail "a version off the pin stops before touching anything" "$code: $out"

printf '%s' "$(sed -n 's/^  version: "\(.*\)"$/\1/p' "$REPO/home/.chezmoidata/hermes.yaml")" >"$F/version"
out=$(apply); code=$?
[ "$code" = 0 ] && pass "applies" || fail "applies" "$out"
grep -q s3cret <<<"$out" && fail "never prints a secret" "$out" || pass "never prints a secret"
ls -d "$state"/backup-*/skills/x >/dev/null 2>&1 && ls "$state"/backup-*/config.yaml >/dev/null 2>&1 \
  && pass "backs up config and skills" || fail "backs up config and skills"
grep -q '^TOKEN=s3cret$' "$F/home/.hermes/.env" && grep -q '^OWN=mine$' "$F/home/.hermes/.env" \
  && pass "renders into the marked block" || fail "renders into the marked block"
grep -q '^-a powernap 0$\|pmset -a powernap 0' "$F/root" && pass "sets only the pmset value that differs" || fail "sets only the pmset value that differs" "$(cat "$F/root" 2>/dev/null)"
[ "$(grep -c pmset "$F/root")" = 1 ] && pass "touches no other pmset value" || fail "touches no other pmset value"
[ "$(grep -c restart "$F/restarts")" = 1 ] && pass "restarts the gateway after a change" || fail "restarts the gateway after a change"

before=$(cd "$F/home/.hermes" && cat .env config.yaml | cksum)
backups=$(ls -d "$state"/backup-* | wc -l)
apply >/dev/null
[ "$(grep -c restart "$F/restarts")" = 1 ] && pass "a second run doesn't restart the gateway" || fail "a second run doesn't restart the gateway"
[ "$before" = "$(cd "$F/home/.hermes" && cat .env config.yaml | cksum)" ] && pass "a second run changes nothing" || fail "a second run changes nothing"
[ "$backups" = "$(ls -d "$state"/backup-* | wc -l)" ] && pass "backs up only once" || fail "backs up only once"
ls "$state"/render.* >/dev/null 2>&1 && fail "leaves no rendered temp file" || pass "leaves no rendered temp file"
rm -rf "$F"
cleanup_sandbox
summary
