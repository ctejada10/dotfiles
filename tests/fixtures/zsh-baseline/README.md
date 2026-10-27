Recorded from the old oh-my-zsh shell on arnor on 22 Oct 2026, with
`zsh -i -c` inside `script` (a pseudo-terminal), TERM=xterm-256color and
EDITOR=vim in the environment. tests/zsh-baseline.sh compares the new shell
with these under the same conditions.

hooks.txt, vars.txt and prompt.txt hold what the new shell should show,
written by hand from the recording: the hooks without oh-my-zsh's async git
prompt, and the variables with LC_ALL no longer forced to C.
