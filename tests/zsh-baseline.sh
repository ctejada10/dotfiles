#!/usr/bin/env bash
# The new shell must behave like the old oh-my-zsh one. The fixtures in
# tests/fixtures/zsh-baseline were recorded from the old shell on arnor on
# 22 Oct 2026, through a real terminal, with TERM=xterm-256color. This applies
# the laptop role to a throwaway home, starts zsh there the same way, and
# compares. The only differences allowed are the deliberate ones listed below.
# macOS only: the recording is of the Mac shell.

set -uo pipefail
. "$(dirname "$0")/lib.sh"
FIXTURES="$REPO/tests/fixtures/zsh-baseline"

if [ "$(uname)" != Darwin ]; then
  echo "zsh-baseline: macOS only, skipped"
  exit 0
fi

sandbox laptop arnor arnor >/dev/null 2>&1 || { echo "init failed"; exit 1; }
cz apply --exclude=scripts,externals >/dev/null 2>&1 || { echo "apply failed"; cleanup_sandbox; exit 1; }
HOMEDIR="$SANDBOX/home"
OUT="$SANDBOX/out"
mkdir -p "$OUT"

# A clean environment through a pseudo-terminal, so the line editor is live.
# EDITOR=vim matches the recording: zsh starts in vi mode when EDITOR names
# vi, and compinit binds its ^X widgets into whichever keymap is current.
# zsh's stderr goes to a file: script would pass it on to its own stdout, and
# the check below would never see what startup printed.
env -i HOME="$HOMEDIR" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh \
  TERM=xterm-256color EDITOR=vim PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  script -q /dev/null /bin/sh -c 'exec 2>"$1"; shift; exec "$@"' sh "$OUT/stderr.txt" /bin/zsh -i -c "
    bindkey -lL main > '$OUT/keymap-main.txt'
    bindkey -M viins -L > '$OUT/keys-viins.txt'
    bindkey -M vicmd -L > '$OUT/keys-vicmd.txt'
    bindkey -M emacs -L > '$OUT/keys-emacs.txt'
    bindkey -M menuselect -L > '$OUT/keys-menuselect.txt'
    setopt > '$OUT/setopt.txt'
    alias -L > '$OUT/aliases.txt'
    zstyle -L > '$OUT/zstyle.txt'
    print -rl -- \${(k)functions} | grep -v '^_' | sort > '$OUT/functions.txt'
    print -rl -- precmd: \$precmd_functions preexec: \$preexec_functions > '$OUT/hooks.txt'
    for v in HISTSIZE SAVEHIST KEYTIMEOUT WORDCHARS LSCOLORS LS_COLORS CLICOLOR PAGER LESS EDITOR LANG LC_ALL LC_COLLATE; do
      print -r -- \"\$v=\${(P)v}\"
    done > '$OUT/vars.txt'
    print -r -- \"PROMPT=\$PROMPT\" > '$OUT/prompt.txt'
    print -r -- \"RPROMPT=\$RPROMPT\" >> '$OUT/prompt.txt'
    exit
  " </dev/null >/dev/null 2>>"$OUT/stderr.txt"

# The fixtures were recorded as ctejada; CI runs as another user.
normalize() { sed -e "s|$HOMEDIR|~|g" -e "s|$HOME|~|g" -e "s|ps -u [^ ]* -o|ps -u USER -o|" "$1"; }

compare() {
  local name="$1" want="$2" got="$3" delta
  delta=$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"))
  if [ -z "$delta" ]; then pass "$name"; else fail "$name" "$delta"; fi
}

section "startup"
if [ -s "$OUT/stderr.txt" ]; then fail "a new shell prints no errors" "$(cat "$OUT/stderr.txt")"; else pass "a new shell prints no errors"; fi
# An interactive shell with no terminal, as an agent's tool starts one. zsh
# opens /dev/tty when stdin and stdout aren't terminals, so the shell starts in
# a session of its own, which has no terminal at all.
env -i HOME="$HOMEDIR" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh \
  TERM=xterm-256color PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' \
  /bin/zsh -i -c true </dev/null >/dev/null 2>"$OUT/stderr-no-tty.txt"
if [ -s "$OUT/stderr-no-tty.txt" ]; then
  fail "a shell with no terminal prints no errors" "$(cat "$OUT/stderr-no-tty.txt")"
else
  pass "a shell with no terminal prints no errors"
fi

section "key bindings"
for f in keymap-main keys-viins keys-vicmd keys-emacs keys-menuselect; do
  compare "$f" "$(normalize "$FIXTURES/$f.txt")" "$(normalize "$OUT/$f.txt")"
done
grep -qx 'bindkey -M viins "^R" fzf-history-widget' "$OUT/keys-viins.txt" \
  && pass "Ctrl-R is fzf's history search" || fail "Ctrl-R is fzf's history search"

section "options"
compare "setopt" "$(cat "$FIXTURES/setopt.txt")" "$(cat "$OUT/setopt.txt")"

section "aliases"
# Deliberate: the apt update alias is Linux-only now.
compare "alias -L" "$(grep -v "^alias update=" "$FIXTURES/aliases.txt")" "$(cat "$OUT/aliases.txt")"

section "completion styles"
# Deliberate: the cache moved out of ~/.oh-my-zsh, and the updater is gone.
want=$(normalize "$FIXTURES/zstyle.txt" | grep -v ':omz:update' | sed 's|~/.oh-my-zsh/cache|~/.cache/zsh|')
compare "zstyle -L" "$want" "$(normalize "$OUT/zstyle.txt")"

section "functions"
# Deliberate: virtualenvwrapper and conda are gone, and so is oh-my-zsh's
# framework, with the git and prompt helpers only its themes used.
dropped='^(virtualenvwrapper.*|.*virtualenv|workon|wipeenv|cdproject|cdsitepackages|lssitepackages|mkproject|mktmpenv|setvirtualenvproject|add2virtualenv|allvirtualenv|cpvirtualenv|lsvirtualenv|mkvirtualenv|rmvirtualenv|showvirtualenv|conda|omz|omz_diagnostic_dump|uninstall_oh_my_zsh|upgrade_oh_my_zsh|is_plugin|is_theme|handle_completion_insecurities|.*_prompt_info|git_.*|parse_git_dirty|spectrum_ls|spectrum_bls|VCS_INFO_formats|regexp-replace)$'
compare "functions" "$(grep -Ev "$dropped" "$FIXTURES/functions.txt")" "$(cat "$OUT/functions.txt")"

section "hooks"
# Deliberate: oh-my-zsh's async git prompt hooks are gone; the minimal prompt
# never used them.
compare "precmd and preexec" "$(cat "$FIXTURES/hooks.txt")" "$(cat "$OUT/hooks.txt")"

section "variables"
compare "settings" "$(cat "$FIXTURES/vars.txt")" "$(cat "$OUT/vars.txt")"
compare "prompt" "$(cat "$FIXTURES/prompt.txt")" "$(cat "$OUT/prompt.txt")"

cleanup_sandbox
summary
