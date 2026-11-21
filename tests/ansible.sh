#!/usr/bin/env bash
# The server playbook, without a server: it parses, cloud-init's user-data
# renders, and every server in hosts.yaml has its settings. Needs the pinned
# Ansible and collections (see the README); it fails rather than skips
# without them, so a green run is never hollow.
#
#   bash tests/ansible.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

dir="$REPO/ansible"
ap() { (cd "$dir" && uv run --quiet ansible-playbook "$@"); }

section "the pinned tools are there"
if [ -d "$dir/collections/ansible_collections/devsec/hardening" ]; then
  pass "devsec.hardening is installed"
else
  fail "devsec.hardening is installed" "run: cd ansible && uv run ansible-galaxy collection install -r requirements.yml"
  summary
  exit 1
fi

section "playbooks parse"
for book in site.yml cloud-init.yml; do
  if out=$(ap --syntax-check "$book" -e target=all 2>&1); then pass "$book"; else fail "$book" "$out"; fi
done

# ansible/.ansible-lint sets the profile, the two skipped rules and strict, so
# a warning fails here too.
section "ansible-lint at the production profile"
if out=$(cd "$dir" && uv run --quiet ansible-lint --nocolor 2>&1); then
  pass "no findings"
else
  fail "no findings" "$out"
fi

section "cloud-init's user-data"
work="$(mktemp -d "${TMPDIR:-/tmp}/ansible-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyNotARealOneAtAll000000000000 test"
if out=$(ap cloud-init.yml -e "out=$work/user-data" -e "{\"login_key\": \"$key\"}" 2>&1); then
  pass "renders"
  head -n 1 "$work/user-data" | grep -qx '#cloud-config' && pass "starts with #cloud-config" || fail "starts with #cloud-config"
  grep -qF "$key" "$work/user-data" && pass "carries the login key" || fail "carries the login key"
  grep -qx 'ssh_pwauth: false' "$work/user-data" && pass "turns password login off" || fail "turns password login off"
  (cd "$dir" && uv run --quiet python -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$work/user-data") \
    && pass "is valid YAML" || fail "is valid YAML"
  # cloud-init itself is on Ubuntu only, so CI checks this and a Mac skips it.
  if command -v cloud-init >/dev/null 2>&1; then
    out=$(cloud-init schema -c "$work/user-data" 2>&1) && pass "passes cloud-init's own schema" || fail "passes cloud-init's own schema" "$out"
  else
    printf '  skip  %s\n' "cloud-init's schema check (cloud-init isn't installed here)"
  fi
else
  fail "renders" "$out"
fi
if ap cloud-init.yml -e "out=$work/empty" -e '{"login_key": ""}' >/dev/null 2>&1; then
  fail "refuses to render without the login key"
else
  pass "refuses to render without the login key"
fi
[ ! -e "$work/empty" ] && pass "writes nothing when it refuses" || fail "writes nothing when it refuses"

section "every server has its settings"
for name in $(sed -n '/^hosts:/,/^[a-z]/s/^  \([a-z0-9-]*\):$/\1/p' "$REPO/home/.chezmoidata/hosts.yaml"); do
  [ -f "$dir/hosts/$name.yml" ] && pass "$name has ansible/hosts/$name.yml" || fail "$name has ansible/hosts/$name.yml"
  grep -q "^  $name:" "$dir/packages.yml" && pass "$name has a package list" || fail "$name has a package list"
  # A server that deploys needs the repo its checkout comes from.
  deploys=$(awk -v n="  $name:" '$0 == n { s = 1; next } s && /^  [a-z0-9-]+:$/ { s = 0 } s && $1 == "deploy:" { print $2 }' "$REPO/home/.chezmoidata/hosts.yaml")
  if [ "$deploys" = true ]; then
    grep -qE '^deploy_github_repo: [a-z0-9-]+/[A-Za-z0-9._-]+$' "$dir/hosts/$name.yml" \
      && pass "$name names the repo deploy fetches" || fail "$name names the repo deploy fetches"
  fi
  # Deploy keys live in 1Password; a host file names them, never holds one.
  found=$(grep -nE 'ssh-[a-z0-9-]+ AAAA' "$dir/hosts/$name.yml")
  [ -z "$found" ] && pass "$name holds no SSH key" || fail "$name holds no SSH key" "$found"
  # Keys, aliases and markers are named by a repo's last segment, so a retired
  # repo sharing it with a fetched one would delete that one's key and alias.
  list() { sed -n "s/^$1: *//p" "$dir/hosts/$name.yml" | tr -d '[]' | tr ',' '\n' | tr -d ' ' | grep . | sed 's#.*/##' | sort -u; }
  both=$(comm -12 <({ list deploy_github_repo; list deploy_submodule_repos; } | sort -u) <(list deploy_retired_repos))
  [ -z "$both" ] && pass "$name retires no repo name it still fetches" || fail "$name retires no repo name it still fetches" "$both"
done

# The site deploys from arwen's image since rivendell#106, so Rivendell keeps
# no read key or alias for the old arwen submodule.
section "Rivendell has no submodule deploy keys"
grep -qx 'deploy_submodule_repos: \[\]' "$dir/hosts/rivendell.yml" \
  && pass "Rivendell fetches no submodule" || fail "Rivendell fetches no submodule" "$(grep '^deploy_submodule_repos' "$dir/hosts/rivendell.yml")"
grep -qE '^deploy_retired_repos: \[(.*, *)?ctejada10/arwen(,.*)?\]$' "$dir/hosts/rivendell.yml" \
  && pass "Rivendell retires arwen's read key and alias" || fail "Rivendell retires arwen's read key and alias"
for task in "Stop rewriting retired repos' URLs to their alias" "Take out retired repos' Host aliases" "Delete retired repos' read keys"; do
  grep -qF -- "- name: $task" "$dir/roles/deploy/tasks/main.yml" \
    && pass "the deploy role has: $task" || fail "the deploy role has: $task"
done

section "GitHub's pinned host keys"
keys=$(sed -n '/^  github_ssh_host_keys:/,/^  [a-z]/s/^    - //p' "$dir/pins.yml")
[ "$(wc -l <<< "$keys" | tr -d ' ')" = 3 ] && pass "three are pinned" || fail "three are pinned" "$keys"
while read -r key; do
  [ -n "$key" ] || continue
  printf 'github.com %s\n' "$key" | ssh-keygen -lf - >/dev/null 2>&1 \
    && pass "the ${key%% *} key parses" || fail "the ${key%% *} key parses" "$key"
done <<< "$keys"

summary
