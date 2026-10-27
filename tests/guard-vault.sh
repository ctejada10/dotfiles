#!/usr/bin/env bash
# The laptop's vault guard: shell commands that would read the vault's
# .obsidian folder are blocked; ordinary searches that leave it out are not.
# HOME is a throwaway folder with a stand-in vault, since the guard expands
# globs and follows cd against the real folders.
#
#   bash tests/guard-vault.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_guard-vault.py"
home="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$home"' EXIT
vault="$home/Documents/armenelos"
# The vault and hurin are Git repos, as the real ones are.
mkdir -p "$vault/.obsidian/plugins/x" "$vault/10 Projects" "$vault/.git" "$home/src/hurin/.git"
echo '{"token":"SECRET"}' > "$vault/.obsidian/plugins/x/data.json"
echo '# note' > "$vault/10 Projects/note.md"

# expect <blocked|allowed> <command> [cwd] [label]
# Only exit 2 blocks. Claude Code runs the command after any other failure,
# so a crash counts as neither.
expect() {
  local want="$1" cmd="$2" cwd="${3:-$home}" label="${4:-$2}" got rc
  jq -n --arg c "$cmd" --arg d "$cwd" '{tool_input: {command: $c}, cwd: $d}' \
    | HOME="$home" /usr/bin/python3 -B "$hook" 2>/dev/null
  rc=$?
  case "$rc" in 0) got=allowed ;; 2) got=blocked ;; *) got="a crash (exit $rc)" ;; esac
  if [ "$got" = "$want" ]; then pass "$want: $label${3:+ (from ${cwd/#$home/~})}"; else fail "$want: $label${3:+ (from ${cwd/#$home/~})}" "got $got"; fi
}

section "a command it can't check"
# Input the hook can't handle, here a cwd that isn't a path, makes it fail. It
# blocks then, since any exit but 2 would let the command run.
printf '%s' '{"tool_input": {"command": "cat notes.md"}, "cwd": 5}' \
  | HOME="$home" /usr/bin/python3 -B "$hook" 2>/dev/null
rc=$?
[ "$rc" = 2 ] && pass "blocked: a command it can't check" || fail "blocked: a command it can't check" "got exit $rc"

section "reads into .obsidian"
expect blocked "cat $vault/.obsidian/plugins/x/data.json"
expect blocked "grep -r token $vault"
expect blocked "grep -Rn token ." "$vault"
expect blocked "rg --hidden token $vault"
expect blocked "rg -uu token ." "$vault"
expect blocked "find $vault -name '*.json' -exec cat {} +"
expect blocked "find . -type f | xargs grep token" "$vault"

expect blocked "grep -rn token ~/Documents"
expect blocked "grep -rn token Documents" "$home"
expect blocked "grep -rn token ." "$home/Documents"
expect blocked "rg --hidden -n token ~/Documents"

section "a search with no path searches where it runs"
expect blocked "rg --hidden SECRET" "$vault"
expect blocked "grep -r SECRET" "$vault"
expect blocked "rg --hidden SECRET" "$home"
expect blocked "rg --hidden -j 4 SECRET" "$vault"
expect blocked "grep -r -eSECRET ~/Documents" "$home/src/hurin"
expect blocked "grep -r --regexp=SECRET ~/Documents" "$home/src/hurin"
expect blocked "rg --hidden -eSECRET ~/Documents" "$home/src/hurin"
expect allowed "grep -rn Documents ~/src/hurin" "$home"

section "after a cd, from where it went"
expect blocked "cd ~/Documents/armenelos && grep -rn SECRET ." "$home/src/hurin"
expect blocked "cd ~/Documents/armenelos && cat .obsidian/plugins/x/data.json" "$home/src/hurin"
expect blocked "cd ~/Documents; grep -r SECRET armenelos" "$home/src/hurin"
expect blocked "pushd ~/Documents/armenelos && rg --hidden SECRET" "$home/src/hurin"
expect blocked "(cd ~/Documents/armenelos && grep -r SECRET .)" "$home/src/hurin"
expect blocked "if true; then cd ~/Documents/armenelos; fi; grep -r SECRET ." "$home/src/hurin"
expect allowed "cd ~/src/hurin && grep -rn SECRET ." "$vault"
expect allowed "(cd ~/Documents/armenelos && ls); grep -r SECRET ." "$home/src/hurin"
expect allowed "pushd ~/Documents/armenelos && popd && grep -r SECRET ." "$home/src/hurin"

section "\$HOME, globs, negated finds and a capitalised .obsidian"
# shellcheck disable=SC2016
expect blocked 'cat "$HOME/Documents/armenelos/.obsidian/plugins/x/data.json"'
# shellcheck disable=SC2016
expect blocked 'grep -rn SECRET $HOME/Documents'
expect blocked "grep -r SECRET ~/Documents/*"
expect blocked "cat ~/Documents/armenelos/.o*/plugins/x/data.json"
expect blocked "cat .Obsidian/plugins/x/data.json" "$vault"
expect blocked "find . -type f ! -name '*.md' -exec cat {} +" "$vault"
expect blocked "find . -type f -not -name '*.md' -exec cat {} +" "$vault"
expect blocked "find . -name '*.md' -o -type f -exec cat {} +" "$vault"

section "searches that leave it out"
expect allowed "grep -rn 'status: active' \"$vault/10 Projects\""
expect allowed "find $vault -name '*.md' -mtime -7 -exec grep -l 'type: hub' {} +"
expect allowed "grep -rn token ~/Documents --exclude-dir=.obsidian"
expect allowed "grep -r --exclude-dir=.obsidian token $vault"
expect allowed "rg token $vault"
expect allowed "rg --hidden -g '!.obsidian' token $vault"
expect allowed "find $vault -name '*.md'"
expect allowed "find $vault -not -path '*/.obsidian/*' -name '*.md' -exec head -1 {} +"
expect allowed "grep -r token ~/src/hurin"
expect allowed "find . -name '*.json' -not -path './.obsidian/*' -exec cat {} +" "$vault"
expect allowed "find . -path ./.obsidian -prune -o -name '*.json' -exec cat {} +" "$vault"
expect allowed "grep -rn --exclude-dir={.git,.obsidian} SECRET ~/Documents"
expect allowed "rg -u SECRET ~/Documents/armenelos"
expect allowed "rg --no-ignore TODO ~/Documents/armenelos"

section "exclusions that don't hold"
expect blocked "find . -name '*.json' -not -path './.obsidian/*' -exec cat {} +" "$home/Documents"
expect blocked "find . -name '*.json' -not -path '.obsidian/*' -exec cat {} +" "$vault"
expect blocked "find . -path ./.obsidian -prune -o -name '*.json' -exec cat {} +" "$home/Documents"
expect blocked "find . ~/Documents -not -path './.obsidian/*' -exec cat {} +" "$vault"
expect blocked "grep -rn '--exclude-dir={.git,.obsidian}' SECRET ~/Documents"
expect blocked "rg -u -u SECRET ." "$vault"
expect blocked "rg --unrestricted --unrestricted SECRET ." "$vault"

section "separators inside quotes stay in the pattern"
expect allowed 'grep -rn "foo|bar" "10 Projects"' "$vault"
expect allowed 'grep -rn "foo\|bar" "10 Projects"' "$vault"
expect allowed "grep -rln 'a;b' '10 Projects'" "$vault"
expect allowed 'grep -rn "a && b" "10 Projects"' "$vault"
expect allowed 'grep -rn foo\|bar "10 Projects"' "$vault"
expect allowed 'grep -rn "a|b" ~/src/hurin'
expect blocked 'grep -rn "foo|bar" .' "$vault"
expect blocked 'echo "a;b"; grep -r SECRET .' "$vault"
expect blocked $'cat > n.md <<\'EOF\'\nit\'s here\nEOF\ngrep -r SECRET ~/Documents/armenelos'
expect blocked 'sh -c "cat ~/Documents/armenelos/.obsidian/plugins/x/data.json; echo done"'
expect blocked "bash -lc 'cd ~/Documents/armenelos && grep -r SECRET .'" "$home/src/hurin"
expect blocked 'eval "cd ~/Documents/armenelos; rg --hidden SECRET"' "$home/src/hurin"
expect allowed "bash -c 'cd ~/src/hurin && grep -r SECRET .'"

section "a quote in a comment or a here-document pairs with nothing"
# Bash ignores quotes there, so two apostrophes on different lines must not
# hide the commands between them.
expect blocked $'# Look at what\'s in the vault\ngrep -rn token ~/Documents/armenelos\n# and that\'s it'
expect blocked $'# Look at what\'s in the vault\ncat ~/Documents/armenelos/.obsidian/plugins/x/data.json\n# and that\'s it'
expect blocked $'ls ~ # what\'s here\ngrep -rn token ~/Documents/armenelos # that\'s it'
expect blocked $'# say "hi\ngrep -rn token ~/Documents/armenelos\n# bye"'
expect blocked $'cat > a.md <<\'EOF\'\nToday\'s\nEOF\ngrep -rn token ~/Documents/armenelos\ncat > b.md <<\'EOF\'\nTomorrow\'s\nEOF'
expect blocked $'cat > a.md <<\'EOF\'\nit\'s\nEOF\ngrep -rn token ~/Documents/armenelos # don\'t print'
expect allowed 'grep -rn "foo|bar" "10 Projects" # it'\''s quoted' "$vault"
# In $'...' a backslash escapes the quote, so its \' neither closes it nor
# opens one that a later apostrophe closes.
expect blocked $'echo $\'it\\\'s\'\ngrep -rn token ~/Documents/armenelos\n# that\'s it'
expect blocked $'echo $\'it\\\'s # x\'; grep -r SECRET .' "$vault"
expect blocked $'echo $\'it\\\'s\'; grep -r SECRET .; echo it\\\'s' "$vault"
# A body is checked on its own, from where its command runs: a shell reading
# it runs it as a script, and in any other its quotes are only text.
expect blocked $'cat <<EOF\nit\'s\n`cat ~/Documents/armenelos/.obsidian/plugins/x/data.json`\nthat\'s\nEOF'
expect blocked $'cat <<EOF\n$(cat ~/Documents/armenelos/.obsidian/plugins/x/data.json)\nEOF'
expect blocked $'python3 <<\'EOF\'\nprint(open(os.path.expanduser(\'~/Documents/armenelos/.obsidian/plugins/x/data.json\')).read())\nEOF'
expect blocked $'cat > /tmp/n.md <<\'EOF\'\ncd ~/src/hurin\nEOF\ngrep -r SECRET .' "$vault"
expect blocked $'grep -r SECRET <<\'EOF\'\nx\nEOF' "$vault"
expect blocked $'bash <<\'EOF\'\ncd ~/Documents/armenelos; grep -r SECRET .\nEOF'
expect blocked $'cat <<\'EOF\' | bash\ngrep -rn "it\'s" ~/Documents/armenelos\nEOF'
expect blocked $'cd ~/Documents/armenelos && bash <<\\EOF\ngrep -r SECRET .\nEOF' "$home/src/hurin"
expect allowed $'bash <<\'EOF\'\ngrep -rn "foo|bar" "10 Projects"\nEOF' "$vault"
expect allowed $'cat > "10 Projects/n.md" <<\'EOF\'\nIt\'s "done"\nEOF' "$vault"
expect allowed $'git commit -m "$(cat <<\'EOF\'\nFix it\'s thing\n\nSay "hi" to it\nEOF\n)"' "$vault"
# The shell builds one word from quoted and unquoted parts, as it would from
# a script the body writes, so those quotes must not split the path in two.
expect blocked $'cat <<EOF\n$(cat "$HOME"/Documents/armenelos/.obsidian/plugins/x/data.json)\nEOF' "$home/src/hurin"
expect blocked $'cat <<EOF\n$(cat ~/Documents/armenelos/\'.obsidian\'/plugins/x/data.json)\nEOF' "$home/src/hurin"
expect blocked $'cat <<\'EOF\' | tee /dev/null | bash\ncat "$HOME"/Documents/armenelos/.obsidian/plugins/x/data.json\nEOF' "$home/src/hurin"
expect blocked $'cat > /tmp/s.sh <<\'EOF\'\nV=~/Documents/armenelos\ncat "$V"/.obsidian/plugins/x/data.json\nEOF\nbash /tmp/s.sh' "$home/src/hurin"
# In a body no shell reads, a # is only text: a comment line there is no
# command, while a path or $(...) after the # still counts.
expect allowed $'cat > notes.sh <<\'EOF\'\n# grep -r foo .\nEOF'
expect allowed $'cat > notes.sh <<\'EOF\'\n#!/bin/bash\n# rg --hidden foo\nEOF' "$vault"
expect blocked $'cat <<EOF\n# $(cat ~/Documents/armenelos/.obsidian/plugins/x/data.json)\nEOF' "$home/src/hurin"
expect blocked $'cat > s.sh <<\'EOF\'\n# see ~/Documents/armenelos/.obsidian/plugins/x/data.json\nEOF' "$home/src/hurin"
# A body is also checked as a shell would read it, quotes and all, since a
# script written out may run later: a quoted |, ; or && in it is no separator.
expect blocked $'cat > s.sh <<\'EOF\'\ngrep -rnE \'SECRET|TODO\' ~/Documents/armenelos\nEOF\nbash s.sh' "$home/src/hurin"
expect blocked $'cat <<\'EOF\' | tee /dev/null | bash\ngrep -rnE \'SECRET|TODO\' ~/Documents/armenelos\nEOF' "$home/src/hurin"
expect blocked $'cat > s.sh <<\'EOF\'\ngrep -rn \'a;b\\|SECRET\' ~/Documents/armenelos\nEOF' "$home/src/hurin"
expect blocked $'cat > s.sh <<\'EOF\'\ngrep -rn "a && SECRET" ~/Documents/armenelos\nEOF' "$home/src/hurin"
expect blocked $'cat > s.sh <<\'EOF\'\n# see \\\ngrep -r SECRET ~/Documents/armenelos\nEOF\nbash s.sh' "$home/src/hurin"
expect allowed $'cat > s.sh <<\'EOF\'\ngrep -rnE \'SECRET|TODO\' ~/src/hurin\nEOF\nbash s.sh' "$home/src/hurin"

section "a \$(...) or backquote inside double quotes has quotes of its own"
# An apostrophe inside it pairs with nothing outside, so it must not pair
# with a later one and hide the commands between them.
expect blocked $'echo "$(echo "it\'s")"\ngrep -rn token ~/Documents/armenelos\necho "$(echo "that\'s")"' "$home/src/hurin"
expect blocked $'echo "$(echo "it\'s")"\ncat ~/Documents/armenelos/.obsidian/plugins/x/data.json\necho "$(echo "that\'s")"' "$home/src/hurin"
expect blocked $'v="$(printf "%s" "that\'s")"\ncd ~/Documents/armenelos; grep -rn SECRET .\ngit log --oneline -1 # what\'s new' "$home/src/hurin"
expect blocked $'echo "`echo "it\'s"`"\ngrep -rn token ~/Documents/armenelos\necho "`echo "that\'s"`"' "$home/src/hurin"
# shellcheck disable=SC2016
expect allowed 'cd "$(dirname "$HOME/x")" && echo "it'\''s"' "$home/src/hurin"
# shellcheck disable=SC2016
expect allowed 'echo "$(echo "a|b")" && grep -rn "x|y" "10 Projects"' "$vault"
# One nested too deep to follow runs to the end, rather than crashing the hook.
# shellcheck disable=SC2016
deep="echo $(printf '"$(echo %.0s' $(seq 1200))x$(printf ')"%.0s' $(seq 1200))"
expect blocked "$deep"$'\ngrep -r SECRET ~/Documents/armenelos' "$home/src/hurin" \
  'echo "$(echo "$(echo ... 1200 levels deep, then a recursive grep of the vault'

section "brace lists"
expect blocked "grep -rn SECRET ~/Documents/{armenelos,notes}" "$home/src/hurin"
expect blocked "grep -rn SECRET {armenelos,notes}" "$home/Documents"
expect blocked "cat ~/Documents/armenelos/{.obsidian,x}/plugins/x/data.json"
expect blocked "cat ~/Documents/armenelos/.obs{i,}dian/plugins/x/data.json"
expect blocked "cat ~/Documents/{notes,{x,armenelos}/.obsidian}/plugins/x/data.json"
expect blocked "find ~/Documents/{armenelos,notes} -type f -exec cat {} +" "$home/src/hurin"
expect allowed "grep -rn SECRET ~/src/hurin/{a,b}.txt"
expect allowed "awk '{print \$1, \$2}' ~/src/hurin/x.txt"
expect allowed "echo {a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}"

section "a shell reading a here-string or a pipe runs it as a script"
expect blocked "bash <<< 'grep -r SECRET ~/Documents/armenelos'" "$home/src/hurin"
expect blocked "zsh <<<'cd ~/Documents/armenelos && grep -r SECRET .'" "$home/src/hurin"
expect blocked "cat <<< 'grep -r SECRET ~/Documents/armenelos' | sh" "$home/src/hurin"
expect blocked "echo 'grep -r SECRET ~/Documents/armenelos' | bash" "$home/src/hurin"
expect blocked "echo -n 'rg --hidden SECRET' | bash" "$vault"
expect blocked "echo 'grep -rn SECRET ~/Documents/armenelos' | tee /dev/null | bash" "$home/src/hurin"
expect blocked "printf '%s\\n' 'cd ~/Documents/armenelos' 'grep -r SECRET .' | sh" "$home/src/hurin"
expect blocked "printf 'cd ~/Documents/armenelos\\ngrep -r SECRET .\\n' | zsh" "$home/src/hurin"
expect allowed "echo 'grep -r SECRET ~/src/hurin' | bash"
expect allowed "bash <<< 'grep -r SECRET .'" "$home/src/hurin"
expect allowed "echo 'grep -r SECRET .' | grep -c SECRET" "$vault"

section "nesting too deep to check is blocked"
expect blocked "eval eval eval eval grep -r SECRET ~/Documents/armenelos" "$home/src/hurin"
expect blocked "bash -c \"bash -c 'eval eval grep -r SECRET ~/Documents/armenelos'\"" "$home/src/hurin"
expect blocked "eval eval eval eval true"
expect allowed "eval eval eval true"
msg="$(jq -n '{tool_input: {command: "eval eval eval eval true"}, cwd: "/"}' \
  | HOME="$home" /usr/bin/python3 -B "$hook" 2>&1 >/dev/null)"
case "$msg" in
  *"too many levels deep"*"Run the innermost command on its own."*) pass "the block says what to do instead" ;;
  *) fail "the block says what to do instead" "$msg" ;;
esac

section "paths held in variables or worked out when the command runs"
# shellcheck disable=SC2016
{
expect blocked 'V=~/Documents/armenelos; grep -rn SECRET "$V"' "$home/src/hurin"
expect blocked 'VAULT="$HOME/Documents/armenelos" && grep -rn SECRET "$VAULT"' "$home/src/hurin"
expect blocked 'export VAULT="$HOME/Documents/armenelos"; cat "$VAULT/.obsidian/plugins/x/data.json"' "$home/src/hurin"
expect blocked 'V=~/Documents/armenelos; cd "$V" && rg --hidden SECRET' "$home/src/hurin"
expect blocked 'cd "$(git rev-parse --show-toplevel)" && grep -rn SECRET .' "$vault/10 Projects"
expect blocked 'cd $(git rev-parse --show-toplevel) && cat .obsidian/plugins/x/data.json' "$vault/10 Projects"
expect blocked 'cd "$(dirname "$0")" && grep -rn SECRET .' "$home/Documents"
expect allowed 'V=~/src/hurin; grep -rn SECRET "$V"'
expect allowed 'V="$HOME/Documents/armenelos/10 Projects"; grep -rn SECRET "$V"'
expect allowed 'cd "$(git rev-parse --show-toplevel)" && grep -rn SECRET .' "$home/src/hurin"
expect allowed 'cd "$(dirname "$0")" && grep -rn SECRET .' "$home/src/hurin"
expect allowed 'cd "$(mktemp -d)" && grep -rn SECRET .'
}


section "words Python's glob can't read, comments in substitutions, and long words"
# fnmatch raises on a range such as [:-1]; the hook must not crash, which
# Claude Code treats as allow.
expect allowed "jq '.[:-1]' f.json" "$home/src/hurin"
expect allowed $'python3 - <<\'EOF\'\nprint("abc"[:-1])\nEOF' "$home/src/hurin"
expect blocked "jq '.[:-1]' f.json; grep -r SECRET ~/Documents/armenelos" "$home/src/hurin"
# A comment's apostrophe inside a "$(...)" opens no quote.
expect allowed $'out="$(\n  # it\'s the slow part\n  grep -rnE \'TODO|FIXME\' src\n)"; echo "$out"' "$home"
# Escaped backquotes in a long PR body, and a long one-line JSON payload,
# stay quick.
body=$(for _ in $(seq 400); do printf 'See \\`make test\\` and \\`uv run pytest\\` here. '; done)
payload="[$(for n in $(seq 2000); do printf '{"id":%s,"tags":{"a":1,"b":2}},' "$n"; done){}]"
start=$SECONDS
expect allowed "gh pr create --draft --title x --body \"$body\"" "$home/src/hurin" "a 16 KB PR body full of escaped backquotes"
expect allowed "curl -s -d '$payload' https://example.com/api" "$home/src/hurin" "an 80 KB one-line JSON payload"
[ $((SECONDS - start)) -le 4 ] && pass "both are checked in a few seconds" || fail "both are checked in a few seconds" "$((SECONDS - start)) s"

summary
