#!/usr/bin/env bash
# Runs every test. Nothing here touches the machine running it: chezmoi works
# in throwaway homes, and no test reads 1Password, a key or a server.
#
#   bash tests/run.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

status=0
run() {
  printf '\n=== %s\n' "$1"
  bash "$1" || status=1
}

printf '\n=== tests/check-secrets.sh\n'
if sh tests/check-secrets.sh; then echo "  ok    no key material, fonts or 1Password templates"; else status=1; fi

run tests/lint.sh
run tests/check-roles.sh
run tests/guard-git.sh
run tests/guard-vault.sh
run tests/warn-risky.sh
run tests/agent-gate.sh
run tests/worktree.sh
run tests/worktree-ttl.sh
run tests/repo-snapshots.sh
run tests/ansible.sh
run tests/apply-twice.sh
run tests/zsh-baseline.sh

if [ "$status" -eq 0 ]; then printf '\nall passed\n'; else printf '\nSOME FAILED\n'; fi
exit "$status"
