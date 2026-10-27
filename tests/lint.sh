#!/usr/bin/env bash
# Lints what actually runs: every setup script rendered for every role this OS
# can take, plus the repo's own shell files. A script that renders to nothing
# for a role is skipped for that role, as chezmoi skips it.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "lint: shellcheck is not installed" >&2
  exit 1
fi

roles=(ci laptop agent-mini)
[ "$(uname)" = Linux ] && roles=(ci server)

section "setup scripts and hook templates, rendered per role"
for role in "${roles[@]}"; do
  sandbox "$role" >/dev/null 2>&1 || { fail "init as $role"; continue; }
  for script in "$REPO"/home/.chezmoiscripts/*.tmpl "$REPO"/home/dot_claude/hooks/*.sh.tmpl; do
    name="$(basename "$script" .tmpl) as $role"
    rendered="$SANDBOX/rendered.sh"
    if ! cz execute-template < "$script" > "$rendered" 2>"$SANDBOX/err"; then
      fail "$name renders" "$(cat "$SANDBOX/err")"
      continue
    fi
    [ -n "$(tr -d '[:space:]' < "$rendered")" ] || continue
    if ! bash -n "$rendered" 2>"$SANDBOX/err"; then
      fail "$name parses" "$(cat "$SANDBOX/err")"
    elif out=$(shellcheck -S warning -s bash "$rendered" 2>&1); then
      pass "$name"
    else
      fail "$name is shellcheck-clean" "$out"
    fi
  done
  cleanup_sandbox
done

section "repo scripts"
for file in "$REPO"/tests/*.sh "$REPO"/.githooks/pre-commit \
            "$REPO"/home/dot_claude/hooks/*.sh "$REPO"/home/executable_dot_tmux-window-name.sh \
            "$REPO"/home/dot_local/bin/executable_worktree-ttl \
            "$REPO"/home/dot_local/share/dotfiles/git/read-only-hooks/executable_*; do
  name="${file#"$REPO"/}"
  if out=$(shellcheck -S warning -x "$file" 2>&1); then pass "$name"; else fail "$name" "$out"; fi
done

section "zsh files parse"
for file in "$REPO"/home/dot_zsh/*.zsh; do
  name="${file#"$REPO"/}"
  if out=$(zsh -n "$file" 2>&1); then pass "$name"; else fail "$name" "$out"; fi
done

# The mini's one rules file. Codex reads it as plain text and Claude Code
# imports it, so: no em dashes (Carlos's rule), no HTML comments (Codex would
# read them as text), and no @ outside backticks (Claude would read an import).
section "the shared rules file"
rules="$REPO/home/dot_codex/AGENTS.md"
if [ -f "$rules" ]; then
  pass "exists"
  grep -n $'\xe2\x80\x94' "$rules" >/dev/null && fail "has no em dashes" "$(grep -n $'\xe2\x80\x94' "$rules")" || pass "has no em dashes"
  grep -n '<!--' "$rules" >/dev/null && fail "has no HTML comments" || pass "has no HTML comments"
  odd=$(LC_ALL=C grep -n '[^ -~]' "$rules" || true)
  [ -z "$odd" ] && pass "is plain ASCII: no en dashes or invisible characters" || fail "is plain ASCII: no en dashes or invisible characters" "$odd"
  head -n 8 "$rules" | grep -q 'never co-authored by an AI agent' \
    && pass "opens with the no-AI-attribution rule" || fail "opens with the no-AI-attribution rule"
  stray=$(sed 's/`[^`]*`//g' "$rules" | grep -n '@' || true)
  [ -z "$stray" ] && pass "has no @ outside backticks" || fail "has no @ outside backticks" "$stray"
  lines=$(wc -l < "$rules" | tr -d ' ')
  [ "$lines" -le 200 ] && pass "stays under 200 lines ($lines)" || fail "stays under 200 lines" "$lines lines"
else
  fail "exists" "$rules"
fi

# Parsed, not compiled: py_compile would leave a bytecode cache in the source.
section "Python hooks parse with macOS's own python3"
for file in "$REPO"/home/dot_claude/hooks/*.py; do
  name="${file#"$REPO"/}"
  if out=$(/usr/bin/python3 -B -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$file" 2>&1); then
    pass "$name"
  else
    fail "$name" "$out"
  fi
done

summary
