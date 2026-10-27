# fzf's key bindings (Ctrl-R history, Ctrl-T files, Alt-C directories) and
# completion. Loaded last, so its Ctrl-R wins in every keymap. Only with a
# terminal, which is when zsh sets TTY: an interactive shell without one, as
# agents start, still reports zle on but can't set it, so fzf putting the
# shell's options back would print "can't change option: zle".
[[ -n $TTY ]] || return 0
if [[ -f /usr/share/fzf/key-bindings.zsh ]]; then
  source /usr/share/fzf/key-bindings.zsh
  source /usr/share/fzf/completion.zsh
elif [[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]]; then
  source /usr/share/doc/fzf/examples/key-bindings.zsh
  source /usr/share/doc/fzf/examples/completion.zsh
elif [[ -f /opt/homebrew/opt/fzf/shell/key-bindings.zsh ]]; then
  source /opt/homebrew/opt/fzf/shell/key-bindings.zsh
  source /opt/homebrew/opt/fzf/shell/completion.zsh
elif [[ -f ~/.fzf/shell/key-bindings.zsh ]]; then
  source ~/.fzf/shell/key-bindings.zsh
  source ~/.fzf/shell/completion.zsh
fi
