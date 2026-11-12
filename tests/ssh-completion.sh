#!/usr/bin/env bash
# `ssh <first letters><Tab>` completes every box to its name, never to its
# address. zsh gathers hosts from each Host and HostName line and from
# known_hosts, where the playbook pins servers as [address]:port, so without
# the style in lib.zsh rivendell and dor-lomin completed to their addresses
# while amonsul and esgaroth completed to their names. macOS only.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ "$(uname)" = Darwin ] || { echo "ssh-completion: macOS only, skipped"; exit 0; }

sandbox laptop >/dev/null 2>&1
cz apply --exclude=scripts,externals >/dev/null 2>&1
HOMEDIR="$SANDBOX/home"
# known_hosts as the playbook and the tunnel apply leave it.
printf '%s\n' '[dor-lomin.middlearth.io]:6969 ssh-ed25519 AAAA' '[rivendell.middlearth.io]:69 ssh-ed25519 AAAA' \
  'amonsul ssh-ed25519 AAAA' > "$HOMEDIR/.ssh/known_hosts"

# complete <typed>: what the line holds after one Tab, in an interactive zsh
# with the laptop's own lib.zsh.
complete() {
  local lib="$HOMEDIR/.zsh/lib.zsh"
  HOMEDIR="$HOMEDIR" LIB="$lib" WORD="$1" perl -e 'alarm 30; exec @ARGV' zsh -f -c '
    zmodload zsh/zpty
    zpty z "HOME=$HOMEDIR zsh -f -i"
    zpty -w z "PS1=\"P> \"; ZSH_CACHE_DIR=$HOMEDIR/.cache; autoload -U compinit; compinit -u -D; source $LIB 2>/dev/null; echo RE\"\"ADY"
    zpty -r z out "*READY*"
    zpty -w -n z "ssh $WORD"$'"'"'\t'"'"'
    sleep 2
    zpty -w z $'"'"'\x01print -r -- RE\x27\x27S:\x05:END'"'"'
    zpty -r z out "*RES:*:END*"
    zpty -d z
    print -r -- "$out" | tr -d "\r" | grep -ao "RES:.*:END" | tail -1 | sed "s/^RES://; s/:END\$//"'
}

section "ssh completes each box to its name"
for name in $(cz execute-template '{{ range $n, $h := .hosts }}{{ $n }} {{ end }}{{ range $n, $m := .macs }}{{ with $m.tunnel }}{{ .alias }} {{ end }}{{ end }}'); do
  got=$(complete "${name:0:3}")
  [ "$got" = "ssh $name" ] && pass "${name:0:3} -> $name" || fail "${name:0:3} -> $name" "got: $got"
done

cleanup_sandbox
summary
