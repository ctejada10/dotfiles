# Turn on colors. TERM is left alone: Ghostty sets xterm-ghostty and tmux sets
# tmux-256color, and forcing a value broke both.
export CLICOLOR=1
export LSCOLORS=Gxfxcxdxbxegedabagacad

# Defaults
export LESS='--ignore-case --raw-control-chars'
export PAGER='less'
export EDITOR='vim'

# C-style sorting, for ctags and ls. LC_ALL stays unset: forcing it to C put
# every shell in the C locale, and tmux drew underscores for Unicode.
export LC_COLLATE=C
