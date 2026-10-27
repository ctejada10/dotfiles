# shellcheck shell=bash
# Shared by the tests. Every chezmoi call goes to a throwaway home with its own
# config, cache and state, so nothing here touches the machine running it.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Sourced from zsh, BASH_SOURCE is empty and REPO lands on the folder above
# the one the shell is in; chezmoi would then git init that folder as its
# source. Refuse anything that isn't this repo.
if [ ! -f "$REPO/.chezmoiroot" ] || [ ! -f "$REPO/tests/lib.sh" ]; then
  echo "tests/lib.sh: source it from bash inside the dotfiles repo; $REPO is not it" >&2
  return 1 2>/dev/null || exit 1
fi
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
section() { printf '\n%s\n' "$1"; }

# sandbox <role> [hostname] [displayName]: sets SANDBOX and defines cz.
sandbox() {
  local role="$1" host="${2:-test-$1}" display="${3:-Test ${1}}"
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")"
  mkdir -p "$SANDBOX/home"
  # A stand-in for Dropbox's config-files, as on a Mac Dropbox has synced.
  # SANDBOX_DROPBOX=none leaves it out, as on a wiped Mac.
  [ "${SANDBOX_DROPBOX:-synced}" = none ] || mkdir -p "$SANDBOX/home/Library/CloudStorage/Dropbox/config-files"
  # A stand-in op that records every call: no template may run it.
  mkdir -p "$SANDBOX/stub"
  printf '#!/bin/sh\necho "op $*" >> "%s/op-called"\nexit 1\n' "$SANDBOX" > "$SANDBOX/stub/op"
  chmod +x "$SANDBOX/stub/op"
  cz init --promptChoice "role=$role" --promptString "hostname=$host,displayName=$display" >/dev/null
}

cz() {
  PATH="$SANDBOX/stub:$PATH" chezmoi --source "$REPO" --destination "$SANDBOX/home" \
    --config "$SANDBOX/chezmoi.toml" --cache "$SANDBOX/cache" \
    --persistent-state "$SANDBOX/state.boltdb" --no-tty "$@"
}

cleanup_sandbox() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; SANDBOX=""; }

summary() {
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
