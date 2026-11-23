#!/usr/bin/env bash
# tilde's adoption of Hermes on the mini: which roles get it, what the off
# switches keep out, and the apply script in a fake home with a stand-in hermes,
# op, security, launchctl, pmset and sudo.
#
#   bash tests/hermes.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

sync=$REPO/home/dot_local/bin/executable_hermes-config-sync
# The data turns the rivendell route on, so the cases that want it off say so.
OFF='{"hermes":{"rivendell":{"enabled":false}}}'
ON='{"hermes":{"secrets":{"enabled":true},"rivendell":{"enabled":false},"hurin":{"enabled":true,"host":"dor-lomin.test","port":8000,"webhookHost":"100.64.0.1","telegramChatId":"1","bridge":{"tag":"bridge-v1","port":8001}}}}'
RIV='{"hermes":{"secrets":{"enabled":true},"rivendell":{"enabled":true,"webhookHost":"100.64.0.1","telegramChatId":"7"}}}'
BOTH='{"hermes":{"secrets":{"enabled":true},"hurin":{"enabled":true,"host":"dor-lomin.test","port":8000,"webhookHost":"100.64.0.1","telegramChatId":"1","bridge":{"tag":"bridge-v1","port":8001}},"rivendell":{"enabled":true,"webhookHost":"100.64.0.1","telegramChatId":"7"}}}'

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
perm=$(stat -c %a "$T/target" 2>/dev/null || stat -f %Lp "$T/target")
[ "$perm" = 600 ] && pass "writes mode 600" || fail "writes mode 600" "$perm"
before=$(cat "$T/target")
out=$(python3 -B "$sync" env "$T/rendered" "$T/target")
[ -z "$out" ] && [ "$before" = "$(cat "$T/target")" ] && pass "changes nothing on a second run" || fail "changes nothing on a second run" "$out"

section "hermes-config-sync config"
mkdir -p "$T/bin"
cat >"$T/bin/hermes" <<EOF
#!/bin/bash
case "\$2" in
  get) f="$T/cfg/\$3"; if [ -f "\$f" ]; then cat "\$f"; else echo "Config key not set: \$3"; exit 1; fi ;;
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
before=$(cksum <"$T/state.json"; stat -c %Y "$T/state.json" 2>/dev/null || stat -f %m "$T/state.json")
sleep 1
HERMES_BIN=$T/bin/hermes python3 -B "$sync" config "$T/want.json" "$T/state.json" >/dev/null
[ "$before" = "$(cksum <"$T/state.json"; stat -c %Y "$T/state.json" 2>/dev/null || stat -f %m "$T/state.json")" ] \
  && pass "doesn't rewrite its state when nothing changed" || fail "doesn't rewrite its state when nothing changed"
echo edited >"$T/cfg/mcp_servers.a"
out=$(HERMES_BIN=$T/bin/hermes python3 -B "$sync" config "$T/want.json" "$T/state.json")
[ "$out" = mcp_servers.a ] && pass "repairs a map edited by hand" || fail "repairs a map edited by hand" "$out"
printf '#!/bin/bash\nexit 3\n' >"$T/bin/broken"; chmod +x "$T/bin/broken"
HERMES_BIN=$T/bin/broken python3 -B "$sync" config "$T/want.json" "$T/state2.json" >/dev/null 2>&1 \
  && fail "fails when hermes fails" || pass "fails when hermes fails"
chmod 644 "$T/target"
python3 -B "$sync" env "$T/rendered" "$T/target" >/dev/null
perm=$(stat -c %a "$T/target" 2>/dev/null || stat -f %Lp "$T/target")
[ "$perm" = 600 ] && pass "tightens the mode with nothing to render" || fail "tightens the mode with nothing to render" "$perm"
rm -rf "$T"

if [ "$(uname)" != Darwin ]; then
  summary
  exit
fi

section "role agent-mini, switches off"
sandbox agent-mini >/dev/null 2>&1
list=$(cz managed --include=files 2>/dev/null)
for f in .local/bin/hermes-config-sync .local/bin/hermes-health .local/share/dotfiles/hermes/SKILL.md .local/share/dotfiles/hermes/storage-watch.sh .local/share/dotfiles/hermes/storage-watch/SKILL.md .local/share/dotfiles/hermes/rivendell/SKILL.md .local/share/dotfiles/hermes/rivendell/rivendell-state.py Library/LaunchAgents/com.carlosetejada.hermes-logs.plist; do
  grep -qx "$f" <<<"$list" && pass "manages $f" || fail "manages $f"
done
grep -q 'hurin-bridge\|bridge.env' <<<"$list" && fail "has no bridge" || pass "has no bridge"
grep -q '^\.hermes' <<<"$list" && fail "manages nothing in ~/.hermes" "$(grep '^\.hermes' <<<"$list")" || pass "manages nothing in ~/.hermes"
off=$(cz --override-data "$OFF" cat "$SANDBOX/home/.local/share/dotfiles/hermes/config.json")
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["command_allowlist"]==[] and d["approvals.mode"]=="smart" and not any("hurin" in k or k.startswith("platforms") for k in d)' <<<"$off" \
  && pass "config has no Hurin keys and an empty allowlist" || fail "config has no Hurin keys and an empty allowlist" "$off"
grep -qi rivendell <<<"$off" && fail "config has no rivendell route" "$off" || pass "config has no rivendell route"
# Hermes matches approvals.deny with fnmatch, lowercased, against an agent's
# terminal command. A no-agent cron script runs outside it, so the storage
# job's own prune is not gated.
storage_skill=$REPO/home/dot_local/share/dotfiles/hermes/storage-watch/SKILL.md
python3 -c '
import fnmatch, json, sys
deny = [p.lower() for p in json.load(sys.stdin)["approvals.deny"]]
hit = lambda c: [p for p in deny if fnmatch.fnmatchcase(c.lower(), p)]
for p in ("*docker*prune*", "*colima delete*", "*colima stop*", "*find*-delete*"):
    assert p in deny, p
for c in ("docker system prune -af --volumes", "docker --context colima image prune -a", "docker volume prune",
          "colima delete --force", "colima stop", "find ~/agent-drafts -type f -delete"):
    assert hit(c), c
lines, fence = [], False
for line in open(sys.argv[1]):
    if line.startswith("```"):
        fence = not fence
    elif fence and line.strip():
        lines.append(line.strip())
assert len(lines) == 4, lines
for c in lines:
    assert not hit(c), (c, hit(c))
' "$storage_skill" <<<"$off" \
  && pass "the deny list blocks the cleanups the storage skill forbids, and none of its own commands" \
  || fail "the deny list blocks the cleanups the storage skill forbids, and none of its own commands" "$off"
off_script=$(cz --override-data '{"hermes":{"secrets":{"enabled":true},"rivendell":{"enabled":false}}}' execute-template <"$REPO/home/.chezmoiscripts/run_after_61-hermes.sh.tmpl")
grep -q 'op://Hermes/Telegram' <<<"$off_script" && pass "renders the Telegram secrets" || fail "renders the Telegram secrets"
grep -q 'op://Hermes/Hurin' <<<"$off_script" && fail "renders no Hurin secrets" || pass "renders no Hurin secrets"
grep -q 'op://Hermes/Rivendell' <<<"$off_script" && fail "renders no Rivendell secret" || pass "renders no Rivendell secret"
grep -q 'skills/rivendell' <<<"$off_script" && fail "installs no rivendell skill" || pass "installs no rivendell skill"
grep -q 'rivendell-state.py' <<<"$off_script" && fail "installs no rivendell state script" || pass "installs no rivendell state script"
grep -q 'scripts/storage-watch.sh' <<<"$off_script" && grep -q 'skills/mini/storage-watch/SKILL.md' <<<"$off_script" \
  && pass "installs the storage job's script and skill with every switch off" || fail "installs the storage job's script and skill with every switch off"

section "role agent-mini, rivendell on"
default=$(cz cat "$SANDBOX/home/.local/share/dotfiles/hermes/config.json")
python3 -c 'import json,sys; w=json.load(sys.stdin)["platforms.webhook"]; assert list(w["extra"]["routes"])==["rivendell","rivendell-state"] and w["extra"]["host"].startswith("100."), w' <<<"$default" \
  && pass "the data turns the rivendell routes on, bound to a tailnet address" || fail "the data turns the rivendell routes on, bound to a tailnet address" "$default"
# Hermes renders an empty chat_id as the whole event, which Telegram can't find,
# so a route for the home channel must leave deliver_extra out.
python3 -c 'import json,sys; r=json.load(sys.stdin)["platforms.webhook"]["extra"]["routes"]["rivendell"]; assert "deliver_extra" not in r, r' <<<"$default" \
  && pass "an empty telegramChatId sends rivendell events to the home channel" || fail "an empty telegramChatId sends rivendell events to the home channel" "$default"
home_hurin=$(cz --override-data "$(sed 's/"telegramChatId":"1"/"telegramChatId":""/' <<<"$ON")" execute-template <"$REPO/home/dot_local/share/dotfiles/hermes/config.json.tmpl")
python3 -c 'import json,sys; r=json.load(sys.stdin)["platforms.webhook"]["extra"]["routes"]["hurin"]; assert "deliver_extra" not in r, r' <<<"$home_hurin" \
  && pass "an empty telegramChatId sends hurin events to the home channel" || fail "an empty telegramChatId sends hurin events to the home channel" "$home_hurin"
riv=$(cz --override-data "$RIV" execute-template <"$REPO/home/dot_local/share/dotfiles/hermes/config.json.tmpl")
python3 -c '
import json,sys
d=json.load(sys.stdin)
w=d["platforms.webhook"]
assert w["enabled"] is True and w["extra"]["host"]=="100.64.0.1" and w["extra"]["port"]==8644, w
assert list(w["extra"]["routes"])==["rivendell","rivendell-state"], w
r=w["extra"]["routes"]["rivendell"]
assert r=={"secret":"${RIVENDELL_WEBHOOK_SECRET}","skills":["rivendell-events"],"prompt":"{__raw__}","deliver":"telegram","deliver_extra":{"chat_id":"7"},"mirror_to_session":True}, r
assert d["command_allowlist"]==[] and not any("hurin" in k for k in d), d
' <<<"$riv" && pass "config has only the rivendell routes, signed with its own secret, to Carlos's chat" || fail "config has only the rivendell routes, signed with its own secret, to Carlos's chat" "$riv"
# The state route runs only its script, which answers [SILENT]: no skill, no
# prompt and no delivery, so a snapshot never starts an agent run or a message.
python3 -c 'import json,sys; r=json.load(sys.stdin)["platforms.webhook"]["extra"]["routes"]["rivendell-state"]; assert r=={"secret":"${RIVENDELL_WEBHOOK_SECRET}","script":"rivendell-state.py"}, r' <<<"$riv" \
  && pass "the rivendell-state route runs only its script, with the same secret" || fail "the rivendell-state route runs only its script, with the same secret" "$riv"
riv_script=$(cz --override-data "$RIV" execute-template <"$REPO/home/.chezmoiscripts/run_after_61-hermes.sh.tmpl")
grep -q '^RIVENDELL_WEBHOOK_SECRET=op://Hermes/Rivendell/webhook-secret$' <<<"$riv_script" && pass "renders the Rivendell secret" || fail "renders the Rivendell secret"
grep -q 'op://Hermes/Hurin' <<<"$riv_script" && fail "still renders no Hurin secrets" || pass "still renders no Hurin secrets"
grep -q 'skills/rivendell/events/SKILL.md' <<<"$riv_script" && pass "installs the rivendell skill" || fail "installs the rivendell skill"
grep -q 'scripts/rivendell-state.py' <<<"$riv_script" && pass "installs the rivendell state script" || fail "installs the rivendell state script"
bash -n <<<"$riv_script" && pass "its apply script parses" || fail "its apply script parses"
both=$(cz --override-data "$BOTH" execute-template <"$REPO/home/dot_local/share/dotfiles/hermes/config.json.tmpl")
python3 -c 'import json,sys; d=json.load(sys.stdin); assert sorted(d["platforms.webhook"]["extra"]["routes"])==["hurin","rivendell","rivendell-state"]' <<<"$both" \
  && pass "with Hurin on too, one listener serves every route" || fail "with Hurin on too, one listener serves every route" "$both"
apart=$(sed 's/"rivendell":{"enabled":true,"webhookHost":"100.64.0.1"/"rivendell":{"enabled":true,"webhookHost":"100.64.0.9"/' <<<"$BOTH")
out=$(cz --override-data "$apart" execute-template <"$REPO/home/dot_local/share/dotfiles/hermes/config.json.tmpl" 2>&1)
grep -q 'one webhook listener' <<<"$out" && pass "refuses two routes that disagree on the one listener" || fail "refuses two routes that disagree on the one listener" "$out"
out=$(cz --override-data '{"hermes":{"rivendell":{"enabled":true,"webhookHost":""}}}' execute-template <"$REPO/home/dot_local/share/dotfiles/hermes/config.json.tmpl" 2>&1)
grep -q "webhookHost must be this Mac's tailnet address" <<<"$out" && pass "refuses to bind every interface" || fail "refuses to bind every interface" "$out"
skill=$REPO/home/dot_local/share/dotfiles/hermes/rivendell/SKILL.md
grep -q '^name: rivendell-events$' "$skill" && pass "the skill is rivendell-events" || fail "the skill is rivendell-events"
grep -q 'notify' "$skill" && grep -q 'investigate' "$skill" && grep -q 'facts' "$skill" \
  && pass "the skill covers notify, investigate and facts" || fail "the skill covers notify, investigate and facts"
grep -q '^description:.*questions about Rivendell' "$skill" && pass "the skill loads for questions about Rivendell" || fail "the skill loads for questions about Rivendell"
grep -q '^## Questions$' "$skill" && grep -qF '.hermes/rivendell/state.json' "$skill" && grep -q '15 minutes' "$skill" \
  && pass "the skill answers questions from the state file and flags stale state" || fail "the skill answers questions from the state file and flags stale state"
fence=$(awk '/^## Questions$/{q=1} q&&/never follow/{print NR; exit}' "$skill"); step=$(awk '/^## Questions$/{q=1} q&&/^1\. /{print NR; exit}' "$skill")
[ -n "$fence" ] && [ -n "$step" ] && [ "$fence" -lt "$step" ] && grep -q 'open a link' "$skill" \
  && pass "the skill fences the state file as data before its steps" || fail "the skill fences the state file as data before its steps"

section "the rivendell state script"
S=$(mktemp -d "${TMPDIR:-/tmp}/hermes-state.XXXXXX")
mkdir -p "$S/.hermes/scripts"
cp "$REPO/home/dot_local/share/dotfiles/hermes/rivendell/rivendell-state.py" "$S/.hermes/scripts/"
# Hermes runs it with its own interpreter, the payload on stdin, from the
# scripts folder. HOME points elsewhere: Hermes may remap a script's HOME.
post() { (cd "$S/.hermes/scripts" && HOME=$S/elsewhere python3 -I -B rivendell-state.py) 2>"$S/err"; }
statefile=$S/.hermes/rivendell/state.json
good='{"generated_at":"2026-11-21T08:00:00Z","records":[{"type":"deploy.applied","kind":"notify","urgent":false,"message":"ok","facts":{"sha":"abc1234"},"received_at":"2026-11-21T07:59:00Z"}],"services":[{"service":"radarr","stack":"arr","up":true,"checked_at":"2026-11-21T07:58:00Z"}],"services_error":null}'
out=$(post <<<"$good"); code=$?
[ "$code" = 0 ] && [ "$out" = "[SILENT]" ] && pass "answers [SILENT] and exits 0, so no agent run starts" || fail "answers [SILENT] and exits 0, so no agent run starts" "$code: $out"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))==json.loads(sys.argv[2])' "$statefile" "$good" 2>/dev/null \
  && pass "stores the snapshot as it came" || fail "stores the snapshot as it came" "$(cat "$statefile" 2>&1)"
perm=$(stat -c %a "$statefile" 2>/dev/null || stat -f %Lp "$statefile")
dperm=$(stat -c %a "$S/.hermes/rivendell" 2>/dev/null || stat -f %Lp "$S/.hermes/rivendell")
[ "$perm" = 600 ] && [ "$dperm" = 700 ] && pass "keeps it private: file 600, folder 700" || fail "keeps it private: file 600, folder 700" "$perm $dperm"
[ ! -e "$S/elsewhere" ] && pass "writes beside its scripts folder, whatever HOME is" || fail "writes beside its scripts folder, whatever HOME is"
newer=$(sed 's/08:00:00Z/08:05:00Z/' <<<"$good")
post <<<"$newer" >/dev/null
grep -q '08:05:00Z' "$statefile" && pass "the latest snapshot replaces the last" || fail "the latest snapshot replaces the last"
before=$(cksum <"$statefile")
for bad in 'not json' '[1,2]' '{"records":[]}' '{"generated_at":"x","records":{}}' '{"generated_at":5,"records":[]}'; do
  out=$(post <<<"$bad"); code=$?
  [ "$code" = 0 ] && [ "$out" = "[SILENT]" ] && [ "$before" = "$(cksum <"$statefile")" ] && [ -s "$S/err" ] \
    && pass "drops $bad, keeps the last snapshot and logs why" || fail "drops $bad, keeps the last snapshot and logs why" "$code: $out: $(cat "$S/err")"
done
older=$(sed 's/08:00:00Z/07:00:00Z/' <<<"$good")
out=$(post <<<"$older")
[ "$out" = "[SILENT]" ] && grep -q '08:05:00Z' "$statefile" && pass "an older snapshot never replaces a newer one" || fail "an older snapshot never replaces a newer one" "$(cat "$statefile")"
big=$(python3 -c 'import json; print(json.dumps({"generated_at":"2026-11-21T09:00:00Z","records":[{"message":"x"*300000}]}))')
out=$(post <<<"$big"); code=$?
[ "$code" = 0 ] && [ "$out" = "[SILENT]" ] && grep -q '08:05:00Z' "$statefile" && pass "drops a snapshot over 256 KiB" || fail "drops a snapshot over 256 KiB" "$code: $out"
deep=$(python3 -c 'print("[" * 100000)')
out=$(post <<<"$deep"); code=$?
[ "$code" = 0 ] && [ "$out" = "[SILENT]" ] && pass "drops JSON nested too deep, still [SILENT]" || fail "drops JSON nested too deep, still [SILENT]" "$code: $out"
[ "$(ls -A "$S/.hermes/rivendell")" = state.json ] && pass "leaves no temp file" || fail "leaves no temp file" "$(ls -A "$S/.hermes/rivendell")"
rm -rf "$S"

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
python3 -c 'import json,sys; assert json.load(sys.stdin)["tools.connectors.enabled"] is False' <<<"$on" && pass "config turns off hosted connectors" || fail "config turns off hosted connectors" "$on"
for t in "$script" "$REPO/home/dot_local/bin/executable_hermes-health.tmpl" "$REPO/home/.chezmoiscripts/run_after_59-launch-agents.sh.tmpl"; do
  for data in '{}' "$ON" "$RIV" "$BOTH"; do
    cz --override-data "$data" execute-template <"$t" | bash -n && pass "$(basename "$t") parses" || fail "$(basename "$t") parses"
  done
done
plist=$(cz --override-data "$ON" execute-template <"$REPO/home/private_Library/LaunchAgents/com.carlosetejada.hurin-bridge.plist.tmpl")
plutil -lint - <<<"$plist" >/dev/null && pass "the bridge plist is valid" || fail "the bridge plist is valid"

section "hermes-health counts gateways"
H=$(mktemp -d "${TMPDIR:-/tmp}/hermes-health.XXXXXX")
mkdir -p "$H/.local/bin"
cz execute-template <"$REPO/home/dot_local/bin/executable_hermes-health.tmpl" >"$H/health"
printf '#!/bin/bash\necho "Hermes Agent v0.22.5"\n' >"$H/.local/bin/hermes"
printf '#!/bin/bash\ncut -d" " -f1 "%s/procs"\n' "$H" >"$H/.local/bin/pgrep"
printf '#!/bin/bash\nawk -v p="$4" '"'"'$1==p {print $2}'"'"' "%s/procs"\n' "$H" >"$H/.local/bin/ps"
chmod +x "$H/.local/bin/"*
# launchd starts a wrapper, which starts Hermes's launcher, which starts the gateway.
printf '10 1\n11 10\n12 11\n' >"$H/procs"
out=$(HOME=$H bash "$H/health" 2>&1)
grep -q 'ok    one gateway service' <<<"$out" && pass "a wrapper chain is one gateway" || fail "a wrapper chain is one gateway" "$out"
printf '10 1\n11 10\n12 11\n20 1\n21 20\n' >"$H/procs"
out=$(HOME=$H bash "$H/health" 2>&1)
grep -q 'FAIL  2 gateway services' <<<"$out" && pass "two chains are two gateways" || fail "two chains are two gateways" "$out"
printf '#!/bin/bash\nexit 44\n' >"$H/.local/bin/security"
printf '#!/bin/bash\necho called >>"%s/op-called"\n' "$H" >"$H/.local/bin/op"
chmod +x "$H/.local/bin/"*
out=$(HOME=$H bash "$H/health" 2>&1)
grep -q "FAIL  1Password's token is in the login keychain" <<<"$out" && pass "names a missing keychain token" || fail "names a missing keychain token" "$out"
[ -e "$H/op-called" ] && fail "and never runs op without it, which would ask to add an account" || pass "and never runs op without it, which would ask to add an account"
rm -rf "$H"

section "the apply script"
F=$(mktemp -d "${TMPDIR:-/tmp}/hermes-apply.XXXXXX")
mkdir -p "$F/home/.hermes/skills/x" "$F/home/.local/bin" "$F/home/.local/share/dotfiles/hermes" "$F/stub" "$F/cfg"
printf 'model: x\n' >"$F/home/.hermes/config.yaml"
printf 'OWN=mine\n' >"$F/home/.hermes/.env"
cp "$sync" "$F/home/.local/bin/hermes-config-sync"; chmod +x "$F/home/.local/bin/hermes-config-sync"
cp "$REPO/home/dot_local/share/dotfiles/hermes/SKILL.md" "$REPO/home/dot_local/share/dotfiles/hermes/storage-watch.sh" "$F/home/.local/share/dotfiles/hermes/"
mkdir -p "$F/home/.local/share/dotfiles/hermes/storage-watch"
cp "$REPO/home/dot_local/share/dotfiles/hermes/storage-watch/SKILL.md" "$F/home/.local/share/dotfiles/hermes/storage-watch/"
printf '{"approvals.mode":"smart"}\n' >"$F/home/.local/share/dotfiles/hermes/config.json"
cat >"$F/home/.local/bin/hermes" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "--version "*) echo "Hermes Agent v\$(cat "$F/version") (x)" ;;
  "config get") if [ -f "$F/cfg/\$3" ]; then cat "$F/cfg/\$3"; else echo "Config key not set: \$3"; exit 1; fi ;;
  "config set") echo "\$4" >"$F/cfg/\$3" ;;
  "gateway restart") echo restart >>"$F/restarts" ;;
esac
EOF
chmod +x "$F/home/.local/bin/hermes"
# Like the real op: a template on stdin must come through a pipe, and a
# heredoc in macOS's bash 3.2 is a file.
printf '#!/bin/sh\n[ -p /dev/stdin ] || { echo "expected data on stdin but none found" >&2; exit 1; }\nprintf "TOKEN=s3cret\\n" >"$4"\n' >"$F/stub/op"
printf '#!/bin/sh\necho token\n' >"$F/stub/security"
printf '#!/bin/sh\nexit 0\n' >"$F/stub/launchctl"
printf '#!/bin/sh\nprintf " sleep 0 (sleep prevented by sharingd, powerd)\\n disksleep 0\\n womp 1\\n autorestart 1\\n powernap 1\\n"\n' >"$F/stub/pmset"
printf '#!/bin/sh\n[ "$1" = -n ] && shift\n[ "$1" = true ] && exit 0\necho "$*" >>"%s/root"\n' "$F" >"$F/stub/sudo"
chmod +x "$F"/stub/*
rendered=$F/apply.sh
cz --override-data '{"hermes":{"secrets":{"enabled":true},"rivendell":{"enabled":false}}}' execute-template <"$script" >"$rendered"
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
cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/storage-watch.sh" "$F/home/.hermes/scripts/storage-watch.sh" \
  && pass "installs the storage script where Hermes's cron runs scripts" || fail "installs the storage script where Hermes's cron runs scripts"
cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/storage-watch/SKILL.md" "$F/home/.hermes/skills/mini/storage-watch/SKILL.md" \
  && pass "and its skill" || fail "and its skill"
grep -q 'updated the storage script' <<<"$out" && grep -q 'updated the storage skill' <<<"$out" \
  && pass "and says so" || fail "and says so" "$out"

before=$(cd "$F/home/.hermes" && cat .env config.yaml | cksum)
backups=$(ls -d "$state"/backup-* | wc -l)
apply >/dev/null
[ "$(grep -c restart "$F/restarts")" = 1 ] && pass "a second run doesn't restart the gateway" || fail "a second run doesn't restart the gateway"
[ "$before" = "$(cd "$F/home/.hermes" && cat .env config.yaml | cksum)" ] && pass "a second run changes nothing" || fail "a second run changes nothing"
[ "$backups" = "$(ls -d "$state"/backup-* | wc -l)" ] && pass "backs up only once" || fail "backs up only once"
ls "$state"/render.* >/dev/null 2>&1 && fail "leaves no rendered temp file" || pass "leaves no rendered temp file"
# A cron script is read on every run, so only a new skill needs the gateway.
echo edited >>"$F/home/.hermes/scripts/storage-watch.sh"
apply >/dev/null
cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/storage-watch.sh" "$F/home/.hermes/scripts/storage-watch.sh" \
  && [ "$(grep -c restart "$F/restarts")" = 1 ] \
  && pass "a changed storage script is put back without a restart" || fail "a changed storage script is put back without a restart"
echo edited >>"$F/home/.hermes/skills/mini/storage-watch/SKILL.md"
apply >/dev/null
cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/storage-watch/SKILL.md" "$F/home/.hermes/skills/mini/storage-watch/SKILL.md" \
  && [ "$(grep -c restart "$F/restarts")" = 2 ] \
  && pass "a changed storage skill is put back with a restart" || fail "a changed storage skill is put back with a restart"
# bash reads a script as it runs, so a run of the old one must keep the old
# file: a hard link stands in for that run's open file.
for pair in scripts/storage-watch.sh=storage-watch.sh skills/mini/storage-watch/SKILL.md=storage-watch/SKILL.md; do
  f=$F/home/.hermes/${pair%%=*}
  echo edited >>"$f"
  ln -f "$f" "$F/running"
  apply >/dev/null
  cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/${pair#*=}" "$f" && [ "$(tail -n 1 "$F/running")" = edited ] \
    && pass "a new ${pair#*=} replaces the old file, which a running job keeps" \
    || fail "a new ${pair#*=} replaces the old file, which a running job keeps"
done
rm -f "$F/running"
restarts=$(grep -c restart "$F/restarts")
dir=$F/home/.hermes/skills/mini/storage-watch
echo edited >>"$dir/SKILL.md"
chmod 500 "$dir"
out=$(apply)
chmod 700 "$dir"
grep -q "couldn't update the storage skill" <<<"$out" && ! grep -q 'updated the storage skill' <<<"$out" \
  && [ "$(tail -n 1 "$dir/SKILL.md")" = edited ] && [ "$(grep -c restart "$F/restarts")" = "$restarts" ] \
  && pass "a copy that fails warns, leaves the old file and doesn't restart" || fail "a copy that fails warns, leaves the old file and doesn't restart" "$out"
[ "$(ls -A "$dir")" = SKILL.md ] && [ "$(ls -A "$F/home/.hermes/scripts")" = storage-watch.sh ] \
  && pass "and leaves no temp file" || fail "and leaves no temp file" "$(ls -A "$dir" "$F/home/.hermes/scripts")"
apply >/dev/null
cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/storage-watch/SKILL.md" "$dir/SKILL.md" \
  && pass "and the next apply puts it back" || fail "and the next apply puts it back"
mv "$F/stub/op" "$F/stub/op.ok"
printf '#!/bin/sh\necho "op says no" >&2; exit 1\n' >"$F/stub/op"; chmod +x "$F/stub/op"
before=$(cksum <"$F/home/.hermes/.env")
out=$(apply)
grep -q "couldn't render.*op says no" <<<"$out" && pass "shows op's error when it can't render" || fail "shows op's error when it can't render" "$out"
[ "$before" = "$(cksum <"$F/home/.hermes/.env")" ] && pass "leaves .env alone when op fails" || fail "leaves .env alone when op fails"
mv "$F/stub/op.ok" "$F/stub/op"
mkdir -p "$F/home/.local/share/dotfiles/hermes/rivendell"
cp "$REPO/home/dot_local/share/dotfiles/hermes/rivendell/SKILL.md" "$REPO/home/dot_local/share/dotfiles/hermes/rivendell/rivendell-state.py" "$F/home/.local/share/dotfiles/hermes/rivendell/"
cz --override-data "$RIV" execute-template <"$script" >"$rendered"
restarts=$(grep -c restart "$F/restarts")
apply >/dev/null
cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/rivendell/SKILL.md" "$F/home/.hermes/skills/rivendell/events/SKILL.md" \
  && pass "rivendell on installs its skill" || fail "rivendell on installs its skill"
cmp -s "$REPO/home/dot_local/share/dotfiles/hermes/rivendell/rivendell-state.py" "$F/home/.hermes/scripts/rivendell-state.py" \
  && pass "and its state script, where Hermes allows route scripts" || fail "and its state script, where Hermes allows route scripts"
[ "$(grep -c restart "$F/restarts")" = $((restarts + 1)) ] && pass "and restarts the gateway for it" || fail "and restarts the gateway for it"
apply >/dev/null
[ "$(grep -c restart "$F/restarts")" = $((restarts + 1)) ] && pass "and not again on a second run" || fail "and not again on a second run"
rm -rf "$F"
cleanup_sandbox
summary
