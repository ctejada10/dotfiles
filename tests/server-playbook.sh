#!/usr/bin/env bash
# The server playbook for real, on the machine this runs on, as ci-runner:
# CI's Ubuntu runner, or a throwaway VM set up like it (Ubuntu 24.04, a user
# with sudo that asks no password, this repo checked out, the playbook's
# collections installed). Never anywhere else: it makes SSH key-only, turns
# UFW on, renames the machine and applies devsec's OS hardening.
#
#   DOTFILES_HARDEN_THIS_MACHINE=yes bash tests/server-playbook.sh
#
# In order: a run that must stop at the device-key guard before it changes
# anything, ones that must stop at a device key or a retired login key cut
# short, a --check, a first run that must take a retired key out, a second
# that must change nothing, then what sshd, UFW, /tmp and authorized_keys say,
# and a login with a device key.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${DOTFILES_HARDEN_THIS_MACHINE:-}" != yes ]; then
  echo "server-playbook: this hardens the machine it runs on. Run it in CI, or on a throwaway VM with DOTFILES_HARDEN_THIS_MACHINE=yes." >&2
  exit 1
fi
if [ "$(uname)" != Linux ] || ! sudo -n true 2>/dev/null; then
  echo "server-playbook: needs Linux and sudo that asks no password, as CI's runner has" >&2
  exit 1
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/server-playbook.XXXXXX")"
# The guard's drop-in, once written, goes when the script ends, whatever ends it.
dropin=
trap 'rm -rf "$work"; [ -z "$dropin" ] || sudo rm -f "$dropin"' EXIT
# Ctrl-C reaches ansible-playbook too, which stops and exits 99 as a failed
# play would, and bash then goes on: a --check cut short would lead straight
# to a first run. Stop instead, once the interrupted play has ended, and let
# the EXIT trap take the drop-in away. SIGTERM needs no trap of its own: bash
# runs the EXIT trap on it and ends.
trap 'exit 130' INT
me="$(id -un)"

# sshd -T as root needs /run/sshd, which a socket-activated sshd makes only at
# the first login over SSH, and nobody has logged in to CI's runner. This
# read lends it the folder and takes it away again, so the playbook's own
# read meets the machine as it was.
sshd_T() {
  sudo bash -c 'made=; [ -d /run/sshd ] || { install -d -m 0755 /run/sshd && made=1; }
    rc=0; sshd -T || rc=$?; [ -z "$made" ] || rmdir /run/sshd; exit "$rc"'
}
# The playbook's tmpfs on /tmp waits for the next boot; mounted during a run,
# it hides the files running processes have there.
tmp_mount() { findmnt -n -o FSTYPE,OPTIONS --mountpoint /tmp 2>/dev/null || echo "not a mount"; }
tmp_before="$(tmp_mount)"

# Every real server has sshd, and the playbook reads sshd -T before it
# changes anything. A runner may not have it.
if [ ! -x /usr/sbin/sshd ]; then
  sudo apt-get update -q >/dev/null && sudo apt-get install -yq --no-install-recommends openssh-server >/dev/null
fi

# The tree under test as a repo of its own on a branch, for chezmoi to clone:
# CI's checkout is shallow, and on a pull request it isn't on a branch, which
# chezmoi update can't pull. Kept outside $work, one commit per run: the home
# folder's checkout pulls from it, so a later run here (after a reboot, say)
# still finds it.
src="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-server-playbook/src"
mkdir -p "$src"
[ -d "$src/.git" ] || git -C "$src" init -q -b main
git -C "$src" rm -rq --ignore-unmatch .
git -C "$REPO" archive HEAD | tar -x -C "$src"
git -C "$src" add -A
git -C "$src" -c user.name=ci -c user.email=ci@localhost -c commit.gpgsign=false \
  commit -q --allow-empty -m "The tree under test"

cat > "$work/hosts.yaml" <<EOF
hosts:
  ci-runner:
    display: CI runner
    address: 127.0.0.1
    port: 22
    user: $me
    deploy: false
EOF

# Stand-ins for the phone's and the tablet's keys, the type Blink makes, and
# for an old login key that ssh.retiredLogin names, as cutover step 12 has
# it, next to an entry of blanks, which the run drops.
ssh-keygen -q -t ecdsa -b 256 -N '' -C ci-phone -f "$work/phone"
ssh-keygen -q -t ecdsa -b 256 -N '' -C ci-tablet -f "$work/tablet"
ssh-keygen -q -t ed25519 -N '' -C ci-old -f "$work/old"
printf '{"device_keys": {"phone": "%s", "tablet": "%s"}, "retired_login_keys": ["%s", "   "]}\n' \
  "$(cat "$work/phone.pub")" "$(cat "$work/tablet.pub")" "$(cat "$work/old.pub")" > "$work/keys.json"
printf '{"device_keys": {"phone": "", "tablet": "%s"}}\n' "$(cat "$work/tablet.pub")" > "$work/keys-missing.json"
# The phone's key cut short, as a copy that missed its end would leave it,
# and then the old key.
printf '{"device_keys": {"phone": "%s", "tablet": "%s"}}\n' "$(cut -c1-90 "$work/phone.pub")" "$(cat "$work/tablet.pub")" > "$work/keys-cut.json"
printf '{"device_keys": {"phone": "%s", "tablet": "%s"}, "retired_login_keys": ["%s"]}\n' \
  "$(cat "$work/phone.pub")" "$(cat "$work/tablet.pub")" "$(cut -c1-60 "$work/old.pub")" > "$work/keys-retired-cut.json"

# JSON results keep each message on one line for grep; YAML would fold them.
play() {
  (cd "$REPO/ansible" && ANSIBLE_CALLBACK_RESULT_FORMAT=json ANSIBLE_NOCOLOR=1 \
    uv run --quiet ansible-playbook site.yml -e target=ci-runner \
    -e "hosts_file=$work/hosts.yaml" -e ansible_connection=local \
    -e "dotfiles_repo=file://$src" --skip-tags scan,sudo_password "$@")
}
recap() { grep -E '^ci-runner +: ' "$1" | tail -1; }
# The task or handler above each change, so a second run that changes
# something says what.
changed_tasks() { awk '/^(TASK|RUNNING HANDLER) \[/ { t = $0 } /^changed: / { print t }' "$1" | sort -u; }

# The guard acts only where sshd takes passwords, and a cloud image's own
# drop-in says no, so this machine gets one that says yes: it sorts first, and
# sshd keeps the first value it reads. It stays through the first run, so that
# run meets what a server that still takes passwords gives it: the guard lets
# it through once every device has a key, and it turns passwords off. The
# run's sshd_config, which says devsec's SSH role wrote it, has no Include
# line, so an earlier run here that got that far leaves the guard nothing to
# stop; anywhere else, Ubuntu's sshd_config has one. sshd -T is read whole:
# piped into grep -q, grep stops at the line, sshd dies of SIGPIPE on the
# rest, and pipefail makes that a miss.
section "the device-key guard"
[ -d /run/sshd ] || printf '  note  %s\n' "no /run/sshd yet, as on a machine nobody has logged in to over SSH"
if ! sudo grep -qiE '^[[:space:]]*include([[:space:]]|=)' /etc/ssh/sshd_config; then
  if sudo grep -q '^# Generated by Ansible role .*ssh_hardening$' /etc/ssh/sshd_config; then
    printf '  skip  %s\n' "the guard: an earlier run here made sshd key-only, and its config reads no drop-ins now"
  else
    fail "sshd_config reads its drop-ins, as Ubuntu's does" \
      "$(sudo grep -in include /etc/ssh/sshd_config || echo "no Include line in /etc/ssh/sshd_config")"
  fi
else
  dropin=/etc/ssh/sshd_config.d/00-server-playbook.conf
  printf 'PasswordAuthentication yes\n' | sudo tee "$dropin" >/dev/null
  if ! grep -qx 'passwordauthentication yes' <<< "$(sshd_T 2>/dev/null)"; then
    fail "sshd takes passwords before the first run" "$(sshd_T 2>&1 | grep -E '^(passwordauthentication|include) |rror')"
  elif play -e "@$work/keys-missing.json" > "$work/guard.log" 2>&1; then
    fail "refuses while a device has no key" "$(tail -40 "$work/guard.log")"
  else
    grep -q "no key yet for phone" "$work/guard.log" \
      && pass "refuses while a device has no key, naming it" \
      || fail "refuses while a device has no key, naming it" "$(tail -40 "$work/guard.log")"
    recap "$work/guard.log" | grep -q ' changed=0 ' \
      && pass "changes nothing first" || fail "changes nothing first" "$(recap "$work/guard.log")"
  fi
fi

section "a device key cut short"
if play -e "@$work/keys-cut.json" > "$work/cut.log" 2>&1; then
  fail "refuses a device key that isn't whole" "$(tail -40 "$work/cut.log")"
else
  grep -q "key for phone isn't a whole public key" "$work/cut.log" \
    && pass "refuses a device key that isn't whole, naming it" \
    || fail "refuses a device key that isn't whole, naming it" "$(tail -40 "$work/cut.log")"
  recap "$work/cut.log" | grep -q ' changed=0 ' \
    && pass "changes nothing first" || fail "changes nothing first" "$(recap "$work/cut.log")"
fi

section "a retired login key cut short"
if play -e "@$work/keys-retired-cut.json" > "$work/retired-cut.log" 2>&1; then
  fail "refuses a retired login key that isn't whole" "$(tail -40 "$work/retired-cut.log")"
else
  grep -q "ssh.retiredLogin has an entry that isn't a whole public key" "$work/retired-cut.log" \
    && pass "refuses a retired login key that isn't whole" \
    || fail "refuses a retired login key that isn't whole" "$(tail -40 "$work/retired-cut.log")"
  recap "$work/retired-cut.log" | grep -q ' changed=0 ' \
    && pass "changes nothing first" || fail "changes nothing first" "$(recap "$work/retired-cut.log")"
fi

# The old key, where a server still has it, for the first run to take out. A
# server always has ~/.ssh; a runner may not.
[ -d "$HOME/.ssh" ] || mkdir -m 700 "$HOME/.ssh"
# A file whose last line has no newline would take the key onto that line.
[ -n "$(tail -c1 "$HOME/.ssh/authorized_keys" 2>/dev/null)" ] && echo >> "$HOME/.ssh/authorized_keys"
cat "$work/old.pub" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

section "a dry run before the first"
if play --check -e "@$work/keys.json" > "$work/check.log" 2>&1; then
  pass "--check passes"
else
  fail "--check passes" "$(tail -60 "$work/check.log")"
fi

section "a first run"
if play -e "@$work/keys.json" > "$work/run1.log" 2>&1; then
  pass "passes"
else
  fail "passes" "$(tail -80 "$work/run1.log")"
  summary
  exit 1
fi
# The guard's task, and what it said, in the first run.
guard_task='TASK [Refuse to turn password login off while a device has no key]'
guard_said() { awk -v t="$guard_task" 'index($0, t) == 1 { f = 1; next } f && /^[a-z]+: \[/ { sub(/:.*/, ""); print; exit }' "$1"; }
if [ -n "$dropin" ]; then
  [ "$(guard_said "$work/run1.log")" = ok ] \
    && pass "the guard lets it through once every device has a key" \
    || fail "the guard lets it through once every device has a key" "$(grep -F -A2 "$guard_task" "$work/run1.log")"
  grep -qx 'passwordauthentication no' <<< "$(sshd_T 2>/dev/null)" \
    && pass "turns password login off, with the drop-in that turned it on still there" \
    || fail "turns password login off, with the drop-in that turned it on still there" \
      "$(sshd_T 2>&1 | grep -E '^(passwordauthentication|include) |rror')"
  sudo rm -f "$dropin"
  dropin=
fi

section "a second run"
if play -e "@$work/keys.json" > "$work/run2.log" 2>&1; then
  pass "passes"
  recap "$work/run2.log" | grep -qE ' changed=0 +unreachable=0 +failed=0 ' \
    && pass "changes nothing" \
    || fail "changes nothing" "$(recap "$work/run2.log")"$'\n'"$(changed_tasks "$work/run2.log")"
else
  fail "passes" "$(tail -80 "$work/run2.log")"
fi

section "what the machine ends up with"
effective="$(sudo sshd -T 2>/dev/null)"
for want in "port 22" "passwordauthentication no" "kbdinteractiveauthentication no" \
            "permitrootlogin no" "allowagentforwarding no" "authenticationmethods publickey" \
            "allowusers $me"; do
  grep -qx "$want" <<< "$effective" \
    && pass "sshd -T: $want" || fail "sshd -T: $want" "$(grep "^${want%% *} " <<< "$effective")"
done
sudo ufw status | grep -qx 'Status: active' && pass "UFW is on" || fail "UFW is on" "$(sudo ufw status)"
sudo ufw status | grep -qE '^22/tcp +ALLOW' && pass "UFW lets SSH in" || fail "UFW lets SSH in" "$(sudo ufw status)"
[ "$(systemctl is-enabled tmp.mount 2>&1)" = enabled ] \
  && pass "/tmp is a tmpfs from the next boot" || fail "/tmp is a tmpfs from the next boot" "$(systemctl is-enabled tmp.mount 2>&1)"
[ "$(tmp_mount)" = "$tmp_before" ] \
  && pass "/tmp stays as it was until then" || fail "/tmp stays as it was until then" "before: $tmp_before"$'\n'"now: $(tmp_mount)"
# A service with PrivateTmp pulls tmp.mount in whenever it starts, as
# logrotate's does every night, and a run may have started none. One here
# must leave /tmp as it is.
if [ "$tmp_before" = "not a mount" ]; then
  if out=$(sudo systemd-run --quiet --wait -p PrivateTmp=yes true 2>&1); then
    [ "$(tmp_mount)" = "not a mount" ] \
      && pass "/tmp stays as it was when a service with PrivateTmp starts" \
      || fail "/tmp stays as it was when a service with PrivateTmp starts" "now: $(tmp_mount)"
  else
    fail "starts a service with PrivateTmp" "$out"
  fi
fi

keys="$HOME/.ssh/authorized_keys"
login_pub=$(sed -n '/^  login:/,/^  signing:/s/^    public: "\(.*\)"$/\1/p' "$REPO/home/.chezmoidata/keys.yaml")
# By type and base64 body, as sshd and the authorized_key module compare keys.
# keys.yaml's login key has no comment, and the module writes such a key with a
# space at the end of its line, so the whole line never matches it.
read -r login_type login_body _ <<< "$login_pub"
[ -n "${login_body:-}" ] \
  && awk -v t="$login_type" -v b="$login_body" '$1 == t && $2 == b { f = 1 } END { exit !f }' "$keys" \
  && pass "authorizes the laptop's login key" || fail "authorizes the laptop's login key" "$(cat "$keys")"
for device in phone tablet; do
  grep -qF "$(cut -d' ' -f2 "$work/$device.pub")" "$keys" \
    && pass "authorizes the $device's key" || fail "authorizes the $device's key"
done
! grep -qF "$(cut -d' ' -f2 "$work/old.pub")" "$keys" \
  && pass "takes out the retired login key" || fail "takes out the retired login key" "$(cat "$keys")"

# A real login over the hardened sshd, with nothing from an agent, and a
# password-only try that sshd turns down. sshd ignores authorized_keys in a
# home folder others can write to, as a runner's might be; a server's isn't,
# so this one's is made the same.
if [ -n "$(find "$HOME" -maxdepth 0 \( -perm -g+w -o -perm -o+w \))" ]; then
  printf '  note  %s\n' "$HOME was $(stat -c %A "$HOME"), which sshd won't take keys from; made it go-w"
  chmod go-w "$HOME"
fi
ssh_here() {
  env -u SSH_AUTH_SOCK ssh -F /dev/null -o BatchMode=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work/known_hosts" \
    -o ConnectTimeout=10 -p 22 "$@" "$me@127.0.0.1" true
}
if out=$(ssh_here -i "$work/phone" -o IdentitiesOnly=yes 2>&1); then
  pass "a device's key logs in"
else
  fail "a device's key logs in" "$out"
fi
if out=$(ssh_here -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive 2>&1); then
  fail "a login without a key is turned down" "$out"
else
  grep -q 'Permission denied (publickey)' <<< "$out" \
    && pass "a login without a key is turned down" || fail "a login without a key is turned down" "$out"
fi

summary
