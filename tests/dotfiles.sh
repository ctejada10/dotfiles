#!/usr/bin/env bash
# The dotfiles command, rendered per role and run against stand-ins: a
# throwaway copy of the repo on a local "GitHub", and ssh, scp, uv, gh,
# chezmoi, brew and pbpaste that only record what they were asked. Answers
# go in on a terminal through expect, as a person would type them; nothing
# here reaches a server, the mini, GitHub or 1Password. macOS only, like the
# command.
#
#   bash tests/dotfiles.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ "$(uname)" != Darwin ]; then
  echo "dotfiles: macOS only, skipped"
  exit 0
fi

template="$REPO/home/dot_local/bin/executable_dotfiles.tmpl"
work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

# Git with a config of its own: no signing through 1Password, no hooks.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$work/gitconfig"
git config --file "$work/gitconfig" user.name "Test"
git config --file "$work/gitconfig" user.email test@example.com
git config --file "$work/gitconfig" init.defaultBranch main

python="$REPO/ansible/.venv/bin/python"
[ -x "$python" ] || (cd "$REPO/ansible" && uv sync --locked --quiet)
servers=$("$python" -I -c 'import sys, yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["hosts"]))' "$REPO/home/.chezmoidata/hosts.yaml")
read -ra server_list <<< "$servers"

section "rendered per role"
for role in laptop agent-mini ci; do
  sandbox "$role" >/dev/null 2>&1 || { fail "init as $role"; continue; }
  cz execute-template < "$template" > "$work/dotfiles-$role" 2>"$work/err" || fail "renders as $role" "$(cat "$work/err")"
  cleanup_sandbox
done
[ ! -s "$work/dotfiles-ci" ] && pass "ci gets no dotfiles command" || fail "ci gets no dotfiles command"
laptop="$work/dotfiles-laptop"
mini="$work/dotfiles-agent-mini"
help_laptop=$(bash "$laptop" help)
help_mini=$(bash "$mini" help)
grep -q 'dotfiles device set' <<< "$help_laptop" && ! grep -q adopt <<< "$help_laptop" \
  && pass "the laptop has device, not adopt" || fail "the laptop has device, not adopt" "$help_laptop"
grep -q 'dotfiles adopt' <<< "$help_mini" && ! grep -q 'device' <<< "$help_mini" \
  && pass "the mini has adopt, not device" || fail "the mini has adopt, not device" "$help_mini"
bash "$laptop" frobnicate >/dev/null 2>&1; [ $? = 2 ] && pass "an unknown command exits 2" || fail "an unknown command exits 2"

# Stand-ins that record their arguments, and their input where it matters.
stubs="$work/stubs"; log="$work/log"
mkdir -p "$stubs" "$log"
cat > "$stubs/ssh" <<'EOF'
#!/bin/bash
n=$(ls "$LOG"/ssh-*.args 2>/dev/null | wc -l | tr -d ' ')
printf '%s\n' "$@" > "$LOG/ssh-$n.args"
case "$*" in *override-data-file*) cat > "$LOG/ssh-$n.stdin" ;; esac
exit "${SSH_RC:-0}"
EOF
cat > "$stubs/scp" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$LOG/scp.args"
cp "${@: -2:1}" "$LOG/sent.patch"
EOF
# One file of arguments per playbook run. UV_INT stands in for a Ctrl-C at
# the sudo password prompt: the whole foreground group gets SIGINT.
cat > "$stubs/uv" <<'EOF'
#!/bin/bash
n=$(ls "$LOG"/uv-*.args 2>/dev/null | wc -l | tr -d ' ')
printf '%s\n' "$@" > "$LOG/uv-$n.args"
prev=
for a in "$@"; do
  [ "$prev" = -e ] && case "$a" in @*) cp "${a#@}" "$LOG/extra.json" ;; esac
  prev=$a
done
[ -n "${UV_INT:-}" ] && kill -INT 0
exit "${UV_RC:-0}"
EOF
cat > "$stubs/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "pr list"*) printf '%s' "${GH_OPEN:-}" ;;
  "pr create"*) printf '%s\n' "$@" > "$LOG/gh.args"; pwd > "$LOG/gh.pwd"; echo https://github.com/example/dotfiles/pull/1 ;;
esac
EOF
printf '#!/bin/sh\nprintf "%%s" "$CLIP"\n' > "$stubs/pbpaste"
chmod +x "$stubs"/*

# The "GitHub" copy: this repo's keys.yaml with known device keys, its
# hosts.yaml, and the laptop's checkout of them.
for k in phone tablet newphone other; do ssh-keygen -q -t ed25519 -N '' -C "test-$k" -f "$work/$k"; done
ssh-keygen -q -t rsa -b 2048 -N '' -C weak -f "$work/weak"
ssh-keygen -q -t ed25519 -N '' -f "$work/ca"
ssh-keygen -q -s "$work/ca" -I test -n test "$work/other.pub" 2>/dev/null
origin="$work/origin.git"
git init -q --bare "$origin"
git clone -q "$origin" "$work/laptop-repo" 2>/dev/null
mkdir -p "$work/laptop-repo/home/.chezmoidata" "$work/laptop-repo/ansible/collections/ansible_collections/devsec"
cp "$REPO/home/.chezmoidata/hosts.yaml" "$work/laptop-repo/home/.chezmoidata/hosts.yaml"
python3 -I - "$REPO/home/.chezmoidata/keys.yaml" "$work/laptop-repo/home/.chezmoidata/keys.yaml" "$(cat "$work/phone.pub")" "$(cat "$work/tablet.pub")" <<'PY'
import re, sys
src, dst, phone, tablet = sys.argv[1:5]
text = open(src).read()
text = re.sub(r'(?m)^    iphone: ".*"$', f'    iphone: "{phone}"', text)
text = re.sub(r'(?m)^    ipad: ".*"$', f'    ipad: "{tablet}"', text)
text = re.sub(r'(?m)^  retiredLogin: .*$', '  retiredLogin: []', text)
open(dst, "w").write(text)
PY
git -C "$work/laptop-repo" add -A && git -C "$work/laptop-repo" commit -q -m base && git -C "$work/laptop-repo" push -q origin main 2>/dev/null
git -C "$work/laptop-repo" remote set-head origin main >/dev/null 2>&1

run_env() {
  env PATH="$stubs:$PATH" LOG="$log" HOME="$work/home" TMPDIR="$work" DOTFILES_REPO="$work/laptop-repo" \
    DOTFILES_PYTHON="$python" "$@"
}
# answer <reply> <command...>: runs it on a terminal and types reply at each
# [y/N] question; prints its output and returns its exit status.
cat > "$work/answer.exp" <<'EXP'
set timeout 60
set reply [lindex $argv 0]
eval spawn -noecho [lrange $argv 1 end]
expect {
  -re {\[y/N\] $} { send "$reply\r"; exp_continue }
  eof
}
catch wait result
exit [lindex $result 3]
EXP
answer() {
  local reply=$1; shift
  run_env expect -f "$work/answer.exp" "$reply" "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}
# no_terminal <command...>: in a session of its own, with no terminal at all.
no_terminal() { run_env /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$@" </dev/null 2>&1; }
clean_log() { rm -f "$log"/*; }
mkdir -p "$work/home"
keys_now() { "$python" -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["ssh"][sys.argv[2]])' "$1" "$2"; }
body() { awk '{print $2}' "$1"; }
uv_runs() { ls "$log"/uv-*.args 2>/dev/null | wc -l | tr -d ' '; }
pushed_nothing() { [ "$(uv_runs)" = 0 ] && ! ls "$log"/ssh-* >/dev/null 2>&1; }
# The mini's authorized_keys as the override it was sent would render it.
mini_render() {
  local call rc
  call=$(grep -l 'override-data-file' "$log"/ssh-*.args 2>/dev/null | head -1)
  [ -n "$call" ] || { echo "no override was sent"; return 1; }
  # chezmoi reads the file's format from its name, as devices.json on the mini.
  cp "${call%.args}.stdin" "$work/devices.json"
  sandbox agent-mini >/dev/null 2>&1 || return 1
  cz cat --override-data-file "$work/devices.json" "$SANDBOX/home/.ssh/authorized_keys" 2>&1
  rc=$?
  cleanup_sandbox
  return "$rc"
}
# Lands a patch the laptop sent on the local "GitHub", as a merged PR would.
merge_sent() {
  local wt="$work/merge-$RANDOM"
  git -C "$work/laptop-repo" worktree add -q --detach "$wt" origin/main 2>/dev/null \
    && git -C "$wt" am -q "$log/sent.patch" && git -C "$wt" push -q origin HEAD:main 2>/dev/null
  local rc=$?
  git -C "$work/laptop-repo" worktree remove --force "$wt" 2>/dev/null
  git -C "$work/laptop-repo" fetch -q origin
  return "$rc"
}

section "dotfiles device set: a new key for a device that has one"
clean_log
out=$(answer y bash "$laptop" device set iphone "$(cat "$work/newphone.pub")")
rc=$?
[ "$rc" = 0 ] && pass "exits 0" || fail "exits 0" "$out"
grep -q 'Its old key' <<< "$out" && pass "says the old key is retired" || fail "says the old key is retired" "$out"
grep -q '((' <<< "$out" && fail "shows each fingerprint plainly" "$out" || pass "shows each fingerprint plainly"
if [ -f "$log/sent.patch" ]; then
  git -C "$work/laptop-repo" show origin/main:home/.chezmoidata/keys.yaml > "$work/before.yaml"
  wt="$work/applied"
  git -C "$work/laptop-repo" worktree add -q --detach "$wt" origin/main 2>/dev/null
  if git -C "$wt" am -q "$log/sent.patch"; then
    pass "the patch applies to GitHub's copy"
    k="$wt/home/.chezmoidata/keys.yaml"
    [ "$(keys_now "$k" devices | grep -c "$(body "$work/newphone.pub")")" = 1 ] \
      && pass "the iphone line has the new key" || fail "the iphone line has the new key" "$(cat "$k")"
    grep -qF "$(body "$work/phone.pub")" <<< "$(keys_now "$k" retiredLogin)" \
      && pass "the old key is under retiredLogin" || fail "the old key is under retiredLogin" "$(cat "$k")"
    grep -qF "$(body "$work/tablet.pub")" "$k" && pass "the ipad keeps its key" || fail "the ipad keeps its key"
    [ "$(grep -c '^ *#' "$k")" = "$(grep -c '^ *#' "$work/before.yaml")" ] \
      && pass "every comment stays" || fail "every comment stays" "$(diff "$work/before.yaml" "$k")"
    subject=$(git -C "$wt" log -1 --format=%s)
    [ "$subject" = "Give the iphone a new key" ] && pass "the commit says what changed" || fail "the commit says what changed" "$subject"
  else
    fail "the patch applies to GitHub's copy" "$(cat "$log/sent.patch")"
  fi
  git -C "$work/laptop-repo" worktree remove --force "$wt" 2>/dev/null
else
  fail "the change is sent to the mini" "$out"
fi
[ "$(uv_runs)" = "${#server_list[@]}" ] && pass "one playbook run per server" || fail "one playbook run per server" "$(cat "$log"/uv-*.args 2>/dev/null)"
for s in "${server_list[@]}"; do
  f=$(grep -lx -- "target=$s" "$log"/uv-*.args 2>/dev/null | head -1)
  if [ -n "$f" ] && grep -qx -- --tags "$f" && grep -qx users "$f" && grep -qx -- -K "$f" && ! grep -qx 'target=all' "$f"; then
    pass "$s: the users role only, with its own sudo password"
  else
    fail "$s: the users role only, with its own sudo password" "$(cat "$log"/uv-*.args 2>/dev/null)"
  fi
done
"$python" -I - "$log/extra.json" "$(body "$work/newphone.pub")" "$(body "$work/phone.pub")" <<'PY' \
  && pass "the servers get the new key and lose the old one" || fail "the servers get the new key and lose the old one" "$(cat "$log/extra.json" 2>/dev/null)"
import json, sys
d = json.load(open(sys.argv[1]))
assert sys.argv[2] in d["device_keys"]["iphone"]
assert any(sys.argv[3] in k for k in d["retired_login_keys"])
assert "ipad" in d["device_keys"]
PY
minicall=$(grep -l 'override-data-file' "$log"/ssh-*.args 2>/dev/null | head -1)
if [ -n "$minicall" ]; then
  grep -q 'chezmoi apply --force --override-data-file' "$minicall" && grep -q 'authorized_keys' "$minicall" \
    && pass "the mini rewrites only its authorized_keys" || fail "the mini rewrites only its authorized_keys" "$(cat "$minicall")"
  rendered=$(mini_render) && grep -qF "$(body "$work/newphone.pub")" <<< "$rendered" && ! grep -qF "$(body "$work/phone.pub")" <<< "$rendered" \
    && pass "the mini's authorized_keys has the new key and not the old" || fail "the mini's authorized_keys has the new key and not the old" "$rendered"
else
  fail "the mini is told" "$(cat "$log"/ssh-*.args 2>/dev/null)"
fi
grep -l -- '-t' "$log"/ssh-*.args 2>/dev/null | xargs grep -h 'dotfiles adopt' 2>/dev/null | grep -q '^\.local/bin/dotfiles adopt agent-drafts/dotfiles/device-iphone-' \
  && pass "the mini adopts the patch as a draft PR" || fail "the mini adopts the patch as a draft PR" "$(cat "$log"/ssh-*.args 2>/dev/null)"
cp "$log/sent.patch" "$work/first.patch"

section "while that change's PR is open"
clean_log
out=$(GH_OPEN=https://github.com/example/dotfiles/pull/1 answer y bash "$laptop" device set ipad "$(cat "$work/other.pub")")
pushed_nothing && grep -q "hasn't merged yet" <<< "$out" \
  && pass "another device change refuses" || fail "another device change refuses" "$out"
clean_log
out=$(GH_OPEN=https://github.com/example/dotfiles/pull/1 answer y bash "$laptop" device push)
pushed_nothing && grep -q "hasn't merged yet" <<< "$out" \
  && pass "device push refuses" || fail "device push refuses" "$out"

section "dotfiles device set: a new device, its key unquoted after the name"
clean_log
# shellcheck disable=SC2046 # split into words on purpose, as an unquoted paste is
out=$(answer y bash "$laptop" device set watch $(cat "$work/other.pub"))
grep -q '^+    watch: "ssh-ed25519 ' "$log/sent.patch" 2>/dev/null && pass "adds a line for it" || fail "adds a line for it" "$out"
grep -q '^+    - ' "$log/sent.patch" 2>/dev/null && fail "retires nothing" "$(cat "$log/sent.patch")" || pass "retires nothing"
clean_log
out=$(CLIP="$(cat "$work/other.pub")" answer y bash "$laptop" device set watch)
grep -q '^+    watch: ' "$log/sent.patch" 2>/dev/null && pass "or from the clipboard" || fail "or from the clipboard" "$out"

section "dotfiles device remove"
clean_log
out=$(answer y bash "$laptop" device remove ipad)
if grep -q '^-    ipad: ' "$log/sent.patch" 2>/dev/null && grep -qF "+    - \"$(cat "$work/tablet.pub")\"" "$log/sent.patch"; then
  pass "takes the line out and retires its key"
else
  fail "takes the line out and retires its key" "$out$(cat "$log/sent.patch" 2>/dev/null)"
fi
"$python" -I -c 'import json, sys; sys.exit("ipad" in json.load(open(sys.argv[1]))["device_keys"])' "$log/extra.json" \
  && pass "the servers no longer list it" || fail "the servers no longer list it" "$(cat "$log/extra.json")"
# The mini's own checkout, in the sandbox, still lists the real iPad; the
# override must keep it out all the same.
ipad=$(sed -n 's/^    ipad: "\(.*\)"$/\1/p' "$REPO/home/.chezmoidata/keys.yaml" | awk '{print $2}')
rendered=$(mini_render) && grep -qF "$(body "$work/phone.pub")" <<< "$rendered" \
  && ! grep -qF "$(body "$work/tablet.pub")" <<< "$rendered" && { [ -z "$ipad" ] || ! grep -qF "$ipad" <<< "$rendered"; } \
  && pass "the mini's authorized_keys loses it, whatever the mini's checkout lists" \
  || fail "the mini's authorized_keys loses it, whatever the mini's checkout lists" "$rendered"

section "refusals, each before anything is asked or pushed"
refuse() {
  local label=$1; shift
  clean_log
  out=$(answer y bash "$laptop" device "$@" 2>&1)
  local rc=$?
  if [ "$rc" != 0 ] && pushed_nothing && ! grep -q 'Go ahead' <<< "$out"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}
refuse "a key cut short" set iphone "$(cut -c1-60 "$work/newphone.pub")"
refuse "a certificate" set iphone "$(cat "$work/other-cert.pub")"
refuse "an RSA key under 3072 bits" set iphone "$(cat "$work/weak.pub")"
refuse "another device's key" set iphone "$(cat "$work/tablet.pub")"
refuse "two keys at once" set iphone "$(cat "$work/newphone.pub" "$work/other.pub")"
refuse "a name with capitals" set iPhone "$(cat "$work/newphone.pub")"
refuse "a name that starts with a digit" set 2phone "$(cat "$work/newphone.pub")"
refuse "a name YAML reads as a boolean" set on "$(cat "$work/newphone.pub")"
refuse "removing a device that isn't listed" remove watch
login=$(sed -n '/^  login:/,/^  signing:/s/^    public: "\(.*\)"$/\1/p' "$work/laptop-repo/home/.chezmoidata/keys.yaml")
[ -n "$login" ] && refuse "the login key" set iphone "$login"

section "nothing changes without a yes"
clean_log
out=$(answer n bash "$laptop" device set iphone "$(cat "$work/newphone.pub")")
pushed_nothing && grep -q 'nothing changed' <<< "$out" && pass "no answers no" || fail "no answers no" "$out"
clean_log
out=$(no_terminal bash "$laptop" device set iphone "$(cat "$work/newphone.pub")")
pushed_nothing && grep -q "no terminal" <<< "$out" \
  && pass "with no terminal, nothing is asked or pushed" || fail "with no terminal, nothing is asked or pushed" "$out"
clean_log
out=$(answer y bash "$laptop" device set iphone "$(cat "$work/phone.pub")")
grep -q 'already has that key' <<< "$out" && pushed_nothing \
  && pass "the same key again does nothing" || fail "the same key again does nothing" "$out"
clean_log
out=$(UV_INT=1 answer y bash "$laptop" device set iphone "$(cat "$work/newphone.pub")")
rc=$?
[ "$rc" = 130 ] && [ "$(uv_runs)" = 1 ] && ! ls "$log"/ssh-* >/dev/null 2>&1 && [ ! -e "$log/sent.patch" ] \
  && pass "Ctrl-C at the first server stops it there" || fail "Ctrl-C at the first server stops it there" "rc=$rc runs=$(uv_runs) $out"

section "dotfiles device push"
clean_log
out=$(answer y bash "$laptop" device push)
"$python" -I -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(not d["device_keys"].get("iphone"))' "$log/extra.json" 2>/dev/null \
  && [ "$(uv_runs)" = "${#server_list[@]}" ] && grep -q 'override-data-file' "$log"/ssh-*.args \
  && pass "pushes GitHub's device keys to every server and the mini" || fail "pushes GitHub's device keys to every server and the mini" "$out"
[ ! -e "$log/sent.patch" ] && pass "records nothing new" || fail "records nothing new"
clean_log
out=$(answer y bash "$laptop" device push "${server_list[1]}")
[ "$(uv_runs)" = 1 ] && grep -qx -- "target=${server_list[1]}" "$log"/uv-0.args && ! ls "$log"/ssh-* >/dev/null 2>&1 \
  && pass "or only to the server named" || fail "or only to the server named" "$out"
clean_log
out=$(answer y bash "$laptop" device push nowhere)
pushed_nothing && pass "refuses a name it doesn't know" || fail "refuses a name it doesn't know" "$out"
clean_log
out=$(UV_RC=2 answer y bash "$laptop" device push)
rc=$?
[ "$rc" != 0 ] && grep -q "didn't take the keys:" <<< "$out" && grep -q "dotfiles device push ${server_list[0]}" <<< "$out" \
  && pass "names the servers that didn't take them" || fail "names the servers that didn't take them" "$out"

section "the last device, and one after it"
# GitHub's copy goes to one device, then none, as two merged PRs would.
clean_log
git -C "$work/laptop-repo" fetch -q origin
answer y bash "$laptop" device remove ipad >/dev/null && merge_sent && pass "one device left" || fail "one device left"
clean_log
out=$(answer y bash "$laptop" device remove iphone)
if merge_sent; then
  k=$(git -C "$work/laptop-repo" show origin/main:home/.chezmoidata/keys.yaml)
  grep -qx '  devices: {}' <<< "$k" && pass "no devices reads as an empty map, not null" || fail "no devices reads as an empty map, not null" "$k"
else
  fail "the last device goes" "$out"
fi
clean_log
out=$(answer y bash "$laptop" device set watch "$(cat "$work/other.pub")")
if merge_sent; then
  k=$(git -C "$work/laptop-repo" show origin/main:home/.chezmoidata/keys.yaml)
  grep -qx '  devices:' <<< "$k" && grep -q '^    watch: "ssh-ed25519 ' <<< "$k" \
    && pass "and a new one after it goes back in a block" || fail "and a new one after it goes back in a block" "$k"
else
  fail "a device after the last" "$out"
fi

section "dotfiles adopt, on the mini"
# The mini's checkout of the same "GitHub", and the patch the first case sent.
git clone -q "$origin" "$work/mini-repo" 2>/dev/null
git -C "$work/mini-repo" remote set-head origin main >/dev/null 2>&1
clean_log
mkdir -p "$work/home/agent-drafts/dotfiles"
patch="$work/home/agent-drafts/dotfiles/device-watch-test.patch"
answer y bash "$laptop" device set watch "$(cat "$work/newphone.pub")" >/dev/null
cp "$log/sent.patch" "$patch"
out=$(DOTFILES_REPO="$work/mini-repo" answer n bash "$mini" adopt "$patch")
[ ! -e "$work/home/worktrees" ] && pass "no makes no branch" || fail "no makes no branch" "$out"
out=$(DOTFILES_REPO="$work/mini-repo" answer y bash "$mini" adopt "$patch")
wt="$work/home/worktrees/dotfiles/device-watch-test"
[ "$(git -C "$wt" log -1 --format=%s 2>/dev/null)" = "Give the watch a new key" ] \
  && pass "commits the change in a worktree outside Dropbox" || fail "commits the change in a worktree outside Dropbox" "$out"
git -C "$origin" rev-parse -q --verify refs/heads/device-watch-test >/dev/null \
  && pass "pushes its branch" || fail "pushes its branch" "$out"
grep -qx -- --draft "$log/gh.args" 2>/dev/null && [ "$(cat "$log/gh.pwd")" = "$wt" ] \
  && pass "opens a draft PR from it" || fail "opens a draft PR from it" "$(cat "$log/gh.args" 2>/dev/null)"
[ ! -e "$patch" ] && pass "drops the patch once the PR is open" || fail "drops the patch once the PR is open"
grep -q 'pull/1' <<< "$out" && pass "prints the PR" || fail "prints the PR" "$out"

section "dotfiles update"
cat > "$stubs/chezmoi" <<'EOF'
#!/bin/bash
echo "$* umask=$(umask)" >> "$LOG/chezmoi.calls"
case "$1" in
  diff) printf '%s' "${DIFF:-}" ;;
  verify) exit 0 ;;
  execute-template)
    [ -n "${RENDER_FAIL:-}" ] && { echo "template: map has no entry for key" >&2; exit 1; }
    printf '#!/bin/bash\necho "macos-settings: dry run: %s would change, 50 already right%s"\n' "${WOULD:-0}" "${TROUBLE:-}" ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >> "$LOG/brew.calls"\n[ "${BREW_RC:-0}" = 0 ] || echo "Formula example needs to be installed."\nexit "${BREW_RC:-0}"\n' > "$stubs/brew"
chmod +x "$stubs/chezmoi" "$stubs/brew"
# Only its path matters: the stand-in chezmoi renders a script of its own.
mkdir -p "$work/laptop-repo/home/.chezmoiscripts"
: > "$work/laptop-repo/home/.chezmoiscripts/run_after_30-macos-settings.sh.tmpl"
git -C "$work/laptop-repo" reset -q --hard origin/main
# A newer commit on "GitHub", for the pull to bring.
git clone -q "$origin" "$work/other-clone" 2>/dev/null
echo upstream > "$work/other-clone/upstream.txt"
git -C "$work/other-clone" add -A && git -C "$work/other-clone" commit -q -m upstream && git -C "$work/other-clone" push -q origin HEAD:main 2>/dev/null
clean_log
out=$(no_terminal bash "$laptop" update)
[ ! -e "$work/laptop-repo/upstream.txt" ] && [ ! -e "$log/chezmoi.calls" ] && grep -q 'needs a terminal' <<< "$out" \
  && pass "with no terminal, nothing is pulled" || fail "with no terminal, nothing is pulled" "$out"
clean_log
out=$(answer n bash "$laptop" update)
[ -e "$work/laptop-repo/upstream.txt" ] && pass "pulls the repo" || fail "pulls the repo" "$out"
grep -q 'already match' <<< "$out" && pass "says when everything matches" || fail "says when everything matches" "$out"
grep -q '^apply' "$log/chezmoi.calls" && fail "no applies nothing" || pass "no applies nothing"
[ "$(grep -c "umask=$(umask)" "$log/chezmoi.calls")" = "$(wc -l < "$log/chezmoi.calls" | tr -d ' ')" ] \
  && pass "chezmoi runs with the caller's umask" || fail "chezmoi runs with the caller's umask" "$(cat "$log/chezmoi.calls")"
clean_log
out=$(DIFF='+changed line' WOULD=3 BREW_RC=1 answer y bash "$laptop" update)
grep -q 'changed line' <<< "$out" && grep -q 'Settings:' <<< "$out" && grep -q 'Packages:' <<< "$out" \
  && pass "shows files, settings and packages" || fail "shows files, settings and packages" "$out"
grep -q '^apply' "$log/chezmoi.calls" && pass "yes applies" || fail "yes applies" "$(cat "$log/chezmoi.calls")"
clean_log
out=$(TROUBLE=", 0 skipped, 1 failed" answer n bash "$laptop" update)
grep -q 'already match' <<< "$out" && fail "a failed setting doesn't count as matching" "$out" || pass "a failed setting doesn't count as matching"
clean_log
out=$(RENDER_FAIL=1 answer n bash "$laptop" update)
grep -q "didn't finish" <<< "$out" && ! grep -q 'already match' <<< "$out" \
  && pass "a dry run that didn't render says so" || fail "a dry run that didn't render says so" "$out"
clean_log
echo local > "$work/laptop-repo/upstream.txt"
git -C "$work/other-clone" commit -q --allow-empty -m again && echo again >> "$work/other-clone/upstream.txt" \
  && git -C "$work/other-clone" commit -q -am again2 && git -C "$work/other-clone" push -q origin HEAD:main 2>/dev/null
out=$(answer y bash "$laptop" update)
[ "$(cat "$work/laptop-repo/upstream.txt")" = local ] && [ ! -e "$log/chezmoi.calls" ] && grep -q "didn't fast-forward" <<< "$out" \
  && pass "a checkout with its own changes is left as it is" || fail "a checkout with its own changes is left as it is" "$out"
git -C "$work/laptop-repo" checkout -q -- . 2>/dev/null

section "dotfiles doctor"
# git ls-remote and Tailscale go nowhere; everything else is a stand-in.
cat > "$stubs/git" <<'EOF'
#!/bin/bash
case "$*" in *ls-remote*) echo "ls-remote GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-unset}" >> "$LOG/git.calls"; exit 0 ;; esac
exec /usr/bin/git "$@"
EOF
chmod +x "$stubs/git"
clean_log
out=$(run_env bash "$laptop" doctor 2>&1)
grep -q '  ok    GitHub answers for the dotfiles repo' <<< "$out" && grep -q 'GIT_TERMINAL_PROMPT=0' "$log/git.calls" \
  && pass "asks GitHub with git, never at a prompt" || fail "asks GitHub with git, never at a prompt" "$out"
grep -q '  ok    chezmoi verify' <<< "$out" && grep -q '  ok    every macOS setting matches' <<< "$out" \
  && pass "verify and the settings pass on a Mac that matches" || fail "verify and the settings pass on a Mac that matches" "$out"
grep -q "verify umask=$(umask)" "$log/chezmoi.calls" && pass "verify runs with the caller's umask" || fail "verify runs with the caller's umask" "$(cat "$log/chezmoi.calls")"
grep -qE '^[0-9]+ ok, [0-9]+ failed, [0-9]+ skipped$' <<< "$out" && pass "ends with a count" || fail "ends with a count" "$out"
rm -f "$stubs/git"

summary
