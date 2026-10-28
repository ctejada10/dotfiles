#!/usr/bin/env bash
# The mini's git guard: feeds it the commands t3-pstack's playbooks and
# ordinary agent work produce, in a throwaway repo, and checks which it blocks.
# Runs Python with -B so no bytecode cache lands in the source tree.
#
#   bash tests/guard-git.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_guard-git.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/guard-git.XXXXXX")"
trap 'rm -rf "$work"' EXIT

git init -q -b main "$work/repo"
git -C "$work/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$work/repo" branch feature

# A repo whose default branch on origin is dev, neither main nor master.
git init -q --bare -b dev "$work/dev-origin.git"
git clone -q "$work/dev-origin.git" "$work/devrepo" 2>/dev/null
git -C "$work/devrepo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$work/devrepo" push -q origin dev
git -C "$work/devrepo" remote set-head origin dev
git -C "$work/devrepo" branch feature

# A commit message and PR body that credit an AI.
printf 'Add the parser\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$work/msg.txt"

# outcome <exit status>: what Claude Code makes of the hook's exit. Only 2
# blocks; any other failure, such as a crash, lets the command through.
outcome() {
  case "$1" in
    0) echo allowed ;;
    2) echo blocked ;;
    *) echo "a crash (exit $1), which lets the command through" ;;
  esac
}

# expect <blocked|allowed> <branch> <command> [repo folder] [previous branch]
expect() {
  local want="$1" on="$2" cmd="$3" repo="${4:-$work/repo}" previous="${5:-}" payload got label
  [ -n "$previous" ] && git -C "$repo" switch -q "$previous"
  git -C "$repo" switch -q "$on"
  payload=$(jq -n --arg c "$cmd" --arg d "$repo" '{tool_input: {command: $c}, cwd: $d}')
  printf '%s' "$payload" | /usr/bin/python3 -B "$hook" 2>/dev/null
  got=$(outcome $?)
  label="$want on $on: ${cmd//$'\n'/ <newline> }"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "got $got"; fi
}

section "allowed on an agent's own branch"
expect allowed feature 'git commit -m "Add the parser"'
expect allowed feature 'git push -u origin feature'
expect allowed feature 'git push'
expect allowed feature 'gh pr create --draft --title "Add the parser" --body x'
expect allowed feature 'gh pr view 12'
expect allowed feature 'git status && git log --oneline -3'
expect allowed main 'git pull --ff-only'
expect allowed main 'git merge --ff-only origin/main'
expect allowed main 'git merge --abort'
expect allowed main 'git switch -c feature-2'
expect allowed main 'git switch feature && git commit -m x'
expect allowed main 'git switch -c feature-3 && git commit -m x'

section "force-pushes"
expect blocked feature 'git push --force'
expect blocked feature 'git push -f origin feature'
expect blocked feature 'git push -uf origin feature'
expect blocked feature 'git push --force-with-lease origin feature'
expect blocked feature 'git push origin feature --force-with-lease=feature'
expect blocked feature 'git push --force-if-includes origin feature'
expect blocked feature 'git push origin +feature'
expect blocked feature 'git push --mirror'

section "pushes to main"
expect blocked feature 'git push origin main'
expect blocked feature 'git push origin HEAD:main'
expect blocked feature 'git push origin feature:refs/heads/master'
expect blocked main 'git push'
expect blocked main 'git push origin HEAD'

section "work on main"
expect blocked main 'git commit -m "Fix it"'
expect blocked main 'git merge feature'
expect blocked main 'git pull'
expect blocked main 'git cherry-pick abc123'
expect blocked feature "cd $work/repo && git switch -q main && git commit -m x"

section "merging or readying PRs"
expect blocked feature 'gh pr merge 12 --squash'
expect blocked feature 'gh -R ctejada10/hurin pr merge 12'
expect blocked feature 'gh pr ready 12'
expect blocked feature 'gh pr create --title "Add the parser" --body x'
expect blocked feature 'gh api -X PUT repos/ctejada10/hurin/pulls/12/merge'

section "hidden in another command"
expect blocked feature 'git status; git push --force'
expect blocked feature $'git status\ngit push --force'
expect blocked feature 'bash -c "git push --force"'
expect blocked feature 'GIT_TRACE=1 git push -f'
expect blocked feature 'git -C . push origin main'

section "a default branch other than main"
expect blocked dev 'git commit -m "Fix it"' "$work/devrepo"
expect blocked feature 'git push origin dev' "$work/devrepo"
expect blocked dev 'git push' "$work/devrepo"
expect allowed feature 'git push -u origin feature' "$work/devrepo"
expect allowed feature 'git commit -m "Add the parser"' "$work/devrepo"

section "commands with here-documents or broken quoting"
expect blocked main $'git commit -F - <<\'EOF\'\nIt\'s "unbalanced\nEOF'
expect allowed feature $'git commit -F - <<\'EOF\'\nIt\'s "unbalanced\nEOF'
expect blocked main 'git commit -m "unbalanced'
expect blocked feature 'gh pr create --title "unbalanced'
expect allowed feature 'gh pr create --draft --title "unbalanced'
expect blocked feature 'git push --force origin "feature'

section "login shells and checkouts"
expect blocked feature 'bash -lc "git push --force"'
expect blocked feature 'zsh -lc "gh pr merge 12"'
expect allowed feature 'git checkout main -- README.md && git commit -m x'
expect allowed feature 'git checkout main README.md && git commit -m x'
expect blocked feature 'git checkout - && git commit -m x' "$work/repo" main
expect allowed main 'git checkout - && git rebase main' "$work/repo" feature
expect blocked main 'git checkout package-lock.json && git commit -am x'

section "names worked out when the command runs"
expect blocked main 'git push -u origin "$(git branch --show-current)"'
expect blocked main 'git push -u origin $(git rev-parse --abbrev-ref HEAD)'
expect blocked main 'git push origin `git branch --show-current`'
expect allowed feature 'git push -u origin "$(git branch --show-current)"'

section "scripts fed to a shell, and comments"
expect blocked feature $'bash <<\'EOF\'\nset -e\ngit push --force origin feature\nEOF'
expect blocked main $'sh <<EOF\ngit push origin main\nEOF'
expect allowed feature $'cat > notes.md <<\'EOF\'\nlater: git push --force\nEOF'
expect blocked feature $'# it\'s reviewed\ngit push origin HEAD:main'
expect blocked feature $'git push origin feature:main # it\'s reviewed'
expect allowed main $'# Make sure we\'re current\ngit pull --ff-only'

section "keywords and wrappers"
expect blocked main 'if git diff --cached --quiet; then echo none; else git commit -m U; fi'
expect blocked main '! git commit -m x'
expect blocked main 'timeout 60 git commit -m x'
expect blocked feature 'timeout 120 git push --force'
expect blocked main 'nice -n 5 git commit -m x'
expect allowed feature 'timeout 60 git push -u origin feature'
expect blocked feature 'gh pr new --fill'
expect allowed feature 'gh pr new --draft --fill'

section "no AI credit in commits"
expect blocked feature $'git commit -m "Add the parser" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"'
expect blocked feature 'git commit -m "Add the parser" --trailer "Co-authored-by: Codex <codex@openai.com>"'
expect blocked feature $'git commit -F - <<\'EOF\'\nAdd the parser\n\nGenerated with Claude Code\nEOF'
expect allowed feature 'git commit -m "Add the parser" -m "Co-authored-by: Ana Lima <ana@example.com>"'
# git commit --trailer takes = as the separator too, and writes it as a colon.
expect blocked feature 'git commit -m Add --trailer "Co-authored-by=Claude <noreply@anthropic.com>"'
expect blocked feature 'git commit -m Add --trailer "Co-authored-by = Claude <noreply@anthropic.com>"'
expect blocked feature 'git commit -m Add "--trailer=Co-authored-by=Codex <codex@openai.com>"'
expect allowed feature 'git commit -m Add --trailer "Co-authored-by=Ana Lima <ana@example.com>"'

section "no AI credit in commits: other ways to give the message"
expect blocked feature 'git commit -am "Co-Authored-By: Claude <noreply@anthropic.com>"'
expect blocked feature "git commit --file=$work/msg.txt"
expect blocked feature "git commit -F$work/msg.txt"
expect blocked feature "git commit -aF $work/msg.txt"
expect blocked feature $'git commit -m "Add the parser\n\nCo-authored-by: Claude <noreply@anthropic.com>"'
expect blocked feature $'git commit -m "$(cat <<\'EOF\'\nAdd the parser\n\nCo-authored-by: Claude <noreply@anthropic.com>\nEOF\n)"'
expect allowed feature $'git commit -m "$(cat <<\'EOF\'\nAdd the parser\n\nIt\'s done.\nEOF\n)"'
expect blocked feature 'git commit -m "Add the parser" -m "Claude-Session: https://claude.ai/code/session_01ABC"'
expect blocked feature 'git commit -m "Add the parser" -m "Generated by GitHub Copilot"'
expect blocked feature 'git commit -m "Add the parser" -m "Generated using Claude"'
expect allowed feature 'git commit -m "Regenerate the client generated by openapi-generator for cursor pagination"'
expect allowed feature 'git commit -m "Update snapshots generated by the AI scoring module"'

section "no AI credit in PRs"
expect blocked feature $'gh pr create --draft --title "Add the parser" --body-file - <<\'EOF\'\n## Decisions for Carlos\nNone.\n\nGenerated with Claude Code\nEOF'
expect blocked feature $'gh pr create --draft --title "Add the parser" -F - <<\'EOF\'\nGenerated with Claude Code\nEOF'
expect blocked feature "gh pr create --draft --title x --body-file=$work/msg.txt"
expect blocked feature 'gh pr create --draft --title x --body "Changes. https://claude.ai/code/session_01ABC"'
expect blocked feature 'gh pr edit 3 --body "Generated with OpenAI Codex"'
expect allowed feature 'gh pr create --draft --title "Fix pagination" --body "The fixtures are generated by pytest and the cursor tests cover it."'

section "no AI credit in a message written earlier in the same command"
expect blocked feature $'cat > '"$work"$'/new-msg.txt <<\'EOF\'\nAdd the parser\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\ngit commit -F '"$work"'/new-msg.txt'
expect blocked feature $'cat <<\'EOF\' > body.md\nChanges.\n\nGenerated with Claude Code\nEOF\ngh pr create --draft --title x --body-file body.md'
expect blocked feature $'body=$(cat <<\'EOF\'\nChanges.\n\nGenerated with Claude Code\nEOF\n)\ngh pr create --draft --title x --body "$body"'
expect blocked feature $'body="$(cat <<\'EOF\'\nChanges.\n\nGenerated with Claude Code\nEOF\n)"; gh pr edit 3 --body "$body"'
expect blocked feature $'msg="Add the parser\n\nCo-authored-by: Codex <codex@openai.com>"; git commit -m "$msg"'
expect allowed feature $'cat > msg.txt <<\'EOF\'\nAdd the parser\nEOF\ngit commit -F msg.txt'
expect allowed feature $'cat > notes.md <<\'EOF\'\nGenerated with Claude Code\nEOF'
expect allowed feature $'cat > '"$work"$'/script.sh <<\'EOF\'\ngit commit -m "Generated with Claude Code"\nEOF'

section "continued lines"
expect blocked feature $'git push \\\n  origin main'
expect blocked feature $'git push origin \\\n  HEAD:main'
expect blocked feature $'git push \\\n  --force origin feature'
expect blocked feature $'git commit \\\n  -m "Add the parser" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
expect allowed feature $'gh pr create \\\n  --draft \\\n  --title "Add the parser" \\\n  --body "x"'
expect blocked feature $'echo a\\\\\ngit push origin main'
expect allowed feature $'echo \'a\\\ngit push origin main\''

section "a # inside a multi-line message"
expect allowed feature $'git commit -m "Retry the push\n\nThe push to main failed, see #12."'
expect blocked feature $'git commit -m "Fix the crash\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nFixes #12."'
expect blocked feature $'git status # <<EOF\ngit push --force\nEOF'

section "fast-forwards only from origin"
expect blocked main 'git merge --ff-only feature'
expect blocked main 'git pull --ff-only . feature'
expect allowed main 'git pull --ff-only origin main'
expect allowed main 'git merge --ff-only'

section "branch names in variables"
expect allowed main 'b=feature; git push -u origin "$b"'
expect allowed main 'b=feature && git push -u origin "${b}"'
expect blocked main 'b=feature; b=$(git branch --show-current); git push -u origin "$b"'
expect blocked main 'for b in main; do git push origin "$b"; done'
expect blocked main 'b=feature git push origin "$b"'

section "redirections are not arguments"
expect allowed main 'git pull --ff-only 2>&1 | tail -3'
expect allowed main 'git merge --ff-only origin/main >/dev/null 2>&1'
expect blocked feature '2>/dev/null git push --force origin feature'
expect blocked feature '>/dev/null git push origin HEAD:main'
expect blocked feature '2>&1 git push origin HEAD:main'
expect blocked main '2>/dev/null git commit -m x'
expect blocked feature $'bash 2>&1 <<\'EOF\'\ngit push --force origin feature\nEOF'
expect blocked feature 'git commit --allow-empty -m "<b>Generated with Claude Code</b>"'
expect blocked feature 'gh pr create --draft --title x --body "<p>Generated with Claude Code</p>"'

section "wrappers whose options take a value"
expect blocked feature 'caffeinate -t 60 git push --force'
expect blocked feature 'env -u GIT_TRACE git push --force'
expect blocked feature 'env -S "git push --force"'
expect blocked main 'stdbuf -o L git commit -m x'

section "no AI credit in a message printf or echo builds"
expect blocked feature "printf 'Add\\n\\nCo-authored-by: Claude <noreply@anthropic.com>\\n' > m.txt && git commit -F m.txt"
expect blocked feature "echo 'Co-authored-by: Claude <noreply@anthropic.com>' >> m.txt && git commit -F m.txt"
expect blocked feature "git commit -m \"\$(printf 'Add\\n\\nCo-authored-by: Claude <noreply@anthropic.com>')\""
expect blocked feature "printf 'Add\\n\\nCo-authored-by: Claude <noreply@anthropic.com>\\n' | git commit -F -"
expect blocked feature "git commit -F <(printf 'Add\\n\\nCo-authored-by: Claude <noreply@anthropic.com>')"
expect blocked feature "git commit -m Add -m \"\$(echo 'Co-authored-by: Claude <noreply@anthropic.com>')\""
expect blocked feature "git commit -m \$'Add\\n\\nCo-authored-by: Claude <noreply@anthropic.com>'"
expect blocked feature "printf 'Generated with Claude Code' > b.md && gh pr create --draft --title x --body-file b.md"
expect blocked feature "printf 'Generated with Claude Code' | gh pr create --draft --title x --body-file -"
expect allowed feature "printf 'Add the parser\\n' > m.txt && git commit -F m.txt"
expect allowed feature "git commit -m 'Strip the Co-authored-by: Claude lines an old hook left'"
expect allowed feature "git commit -m \$'Fix the parser\\n\\nIt\\'s strict now.'"

# A home laid out like the mini's: the agents' repos cloned into a real ~/src,
# Dropbox's repositories folder with repos still in it, the dotfiles source,
# and clones and worktrees in ~/worktrees. No FirstMate project link points at
# ~/src: where a repo is decides whose it is.
home="$work/home"
box="$home/Library/CloudStorage/Dropbox/repositories"
mkdir -p "$box" "$home/src" "$home/worktrees"
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# with_origin <folder>: a checkout of a new bare origin whose default is main.
with_origin() {
  g init -q --bare -b main "$work/origins/$(basename "$1").git"
  g clone -q "$work/origins/$(basename "$1").git" "$1" 2>/dev/null
  g -C "$1" commit -q --allow-empty -m init
  g -C "$1" push -q origin main
  g -C "$1" remote set-head origin main
  mkdir -p "$1/pkg"
}
with_origin "$home/src/agentrepo"
g -C "$home/src/agentrepo" worktree add -q --no-track -b worktree-oak "$home/worktrees/agentrepo/oak" origin/main
# Worktrees of it where T3 and FirstMate's crews make theirs.
g -C "$home/src/agentrepo" worktree add -q --no-track -b t3-thread "$home/.t3/worktrees/agentrepo/t3-thread" origin/main
g -C "$home/src/agentrepo" worktree add -q --no-track -b crew "$home/.treehouse/agentrepo/crew" origin/main
# A repo still in Dropbox's repositories folder, the repos' old home, and a
# worktree of it outside Dropbox.
with_origin "$box/oldrepo"
g -C "$box/oldrepo" switch -q -c feature
g -C "$box/oldrepo" worktree add -q -b old "$home/worktrees/oldrepo/old" 2>/dev/null
# The way to change it: a clone of it, with its own .git, in ~/worktrees.
g clone -q "$work/origins/oldrepo.git" "$home/worktrees/oldrepo/fix" 2>/dev/null
g -C "$home/worktrees/oldrepo/fix" switch -q -c fix
# agentrepo's old copy in Dropbox, which FirstMate's projects linked before the
# move, and ~/Repositories, a link from then into the repositories folder.
g clone -q "$work/origins/agentrepo.git" "$box/agentrepo" 2>/dev/null
mkdir -p "$home/.local/share/firstmate/projects"
ln -s "$box/agentrepo" "$home/.local/share/firstmate/projects/agentrepo"
ln -s "$box" "$home/Repositories"
# A repo elsewhere in Dropbox, outside the repositories folder.
K="$home/Library/CloudStorage/Dropbox/archive/keep"
g init -q -b main "$K"
g -C "$K" commit -q --allow-empty -m init
with_origin "$home/.local/share/chezmoi"
g -C "$home/.local/share/chezmoi" worktree add -q --no-track -b fix "$home/worktrees/dotfiles/fix" origin/main
# An agent repo with a submodule, as rivendell has arwen.
with_origin "$work/subseed"
g -C "$work/subseed" commit -q --allow-empty -m two
g -C "$work/subseed" push -q origin main
g init -q -b main "$home/src/superrepo"
g -C "$home/src/superrepo" -c protocol.file.allow=always submodule add -q "$work/origins/subseed.git" sub 2>/dev/null
g -C "$home/src/superrepo" commit -q -m "Add sub"
older=$(git -C "$home/src/superrepo/sub" rev-parse HEAD~1)
# A worktree of it in ~/worktrees, with the submodule on main, as after
# git submodule update --init and a switch.
S="$home/worktrees/superrepo/bump"
g -C "$home/src/superrepo" worktree add -q -b bump "$S" main
g -C "$S" -c protocol.file.allow=always submodule update -q --init 2>/dev/null
g -C "$S/sub" switch -q main
# A fresh clone of an agent repo, still on main, with a branch on origin to
# continue, as when an agent picks up a handed-over PR.
g -C "$home/src/agentrepo" push -q origin main:review
T="$home/worktrees/agentrepo/fresh"
g clone -q "$work/origins/agentrepo.git" "$T" 2>/dev/null

# at <blocked|allowed> <folder> <attended 0|1> <command> [label]
at() {
  local want="$1" dir="$2" attended="$3" cmd="$4" got label
  jq -n --arg c "$cmd" --arg d "$dir" '{tool_input: {command: $c}, cwd: $d}' \
    | HOME="$home" AGENT_ATTENDED="$attended" /usr/bin/python3 -B "$hook" 2>/dev/null
  got=$(outcome $?)
  label="$want in ~${dir#"$home"} (attended=$attended): ${5:-${cmd//$'\n'/ <newline> }}"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "got $got"; fi
}
L="$box/oldrepo"
D="$home/.local/share/chezmoi"
A="$home/src/agentrepo"
W="$home/worktrees/agentrepo/oak"

section "a repo in Dropbox's repositories folder is never used, not even to read, attended or not"
for attended in 0 1; do
  at blocked "$L" "$attended" 'git status'
  at blocked "$L" "$attended" 'git log --oneline -3'
  at blocked "$L" "$attended" 'gh pr view 3'
  at blocked "$L" "$attended" 'git commit -m "Add the parser"'
  at blocked "$L" "$attended" 'git add README.md'
  at blocked "$L" "$attended" 'git fetch origin'
  at blocked "$L" "$attended" 'git pull --ff-only'
  at blocked "$L" "$attended" 'git remote set-head origin --auto'
  at blocked "$L" "$attended" 'git config user.email x@y'
  at blocked "$L" "$attended" 'git branch newname'
  at blocked "$L" "$attended" 'git tag v1'
  at blocked "$L" "$attended" 'git worktree add --no-track -b fix-2 ~/worktrees/oldrepo/fix-2 origin/HEAD'
  at blocked "$L" "$attended" 'gh pr create --draft --fill'
done
at blocked "$L" 0 'git push -u origin feature'
at blocked "$L" 0 'git switch -c other'
at blocked "$L" 0 'git restore README.md'
at blocked "$L" 0 'git apply ../fix.patch'
at blocked "$L" 0 'git bisect start'
at blocked "$L" 0 'git update-ref refs/heads/feature HEAD~1'
at blocked "$L" 0 'git symbolic-ref HEAD refs/heads/other'
at blocked "$L" 0 'git config --unset core.hooksPath'
at blocked "$L" 0 'git config --remove-section core'
at blocked "$L" 0 'git config set user.name x'
at blocked "$L" 0 'git submodule update --init'
at blocked "$L" 0 'git init'
at blocked "$L" 0 'gh pr edit 3 --body x'
at blocked "$L" 0 'gh issue comment 3 --body x'
at blocked "$L" 0 'gh -R ctejada10/x pr edit 3 --body x'
at blocked "$L" 0 'gh pr checkout 3'
at blocked "$L" 0 $'git commit -m "Fix the crash\n\nFixes #12."'
# What used to be fine there as a read, gh's included: gh reads the repo it
# runs in to know which repo it works on.
for cmd in 'git status' 'git log --oneline -3' 'git diff HEAD' 'git show HEAD' 'git branch --show-current' \
           'git branch -a' 'git branch' 'git tag --list' 'git tag' "git tag -l 'v*'" 'git worktree list' \
           'git stash list' 'git config --get user.name' 'git config user.name' 'git config --list' \
           'git remote -v' 'git remote get-url origin' 'gh pr view 3' 'gh pr list' 'gh issue view 3' \
           'git branch -av' 'git branch -ra' 'git branch -avv' 'git tag -ln' 'git tag -ln3' 'git tag -n3' \
           'git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null' 'git branch --show-current 2>/dev/null' \
           'git branch -a 2>/dev/null' 'git tag 2>/dev/null | tail -5' 'git config user.email 2>/dev/null' \
           'git remote -v 2>&1' 'git describe --tags --always' 'git status --porcelain' 'git rev-parse HEAD' \
           'gh -R ctejada10/oldrepo pr view 3' 'gh run list' 'gh repo view' 'gh api repos/{owner}/{repo}'; do
  at blocked "$L" 0 "$cmd"
done
# Read it on GitHub from anywhere else, or clone it from there.
at allowed "$W" 0 'gh -R ctejada10/oldrepo pr view 3'
at allowed "$home" 0 'gh repo view ctejada10/oldrepo'
for cmd in 'git branch -dr old' 'git tag -am msg v1' 'git branch newname 2>/dev/null' \
           'git config user.email x 2> /dev/null' 'git worktree lock ~/worktrees/oldrepo/old' \
           'git describe --dirty' 'git describe --tags --dirty --always' 'git describe --broken'; do
  at blocked "$L" 0 "$cmd"
done
at blocked "$W" 0 'git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo describe --dirty'

section "a repo in Dropbox however it is named, and whatever links to it"
at blocked "$home/Repositories/oldrepo" 0 'git commit -m x'
at blocked "$home/worktrees/oldrepo/old" 0 'git commit -m x'
at blocked "$W" 0 'git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo commit -m x'
at blocked "$W" 0 'git -C "$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo" commit -m x'
at blocked "$W" 0 'cd $HOME/Library/CloudStorage/Dropbox/repositories/oldrepo && git commit -m x'
at blocked "$W" 0 'pushd ~/Repositories/oldrepo && git commit -m x'
at blocked "$W" 0 'git --git-dir ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git commit -m x'
at blocked "$L/pkg" 0 'cd "$(git rev-parse --show-toplevel)" && git commit -m x'
at blocked "$W" 0 'git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo branch -a'
# Reads too, however the command names it.
for cmd in 'git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo log -1' \
           'git -C "$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo" status' \
           'git -C ~/Repositories/oldrepo status' 'cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo && git status' \
           'pushd ~/Repositories/oldrepo && git log -1' \
           'env -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo git status' \
           'git --git-dir ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git log -1' \
           'git --git-dir=$HOME/Repositories/oldrepo/.git log -1' \
           'git --work-tree ~/Library/CloudStorage/Dropbox/repositories/oldrepo status' \
           'git -c core.worktree=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo status' \
           'git -C ~/worktrees/oldrepo/old status' 'git -C ~/.local/share/firstmate/projects/agentrepo log -1' \
           'chezmoi --source ~/Library/CloudStorage/Dropbox/repositories/oldrepo git -- status' \
           'cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo && gh pr list'; do
  at blocked "$W" 0 "$cmd"
done
at blocked "$home/Repositories/oldrepo" 0 'git status'
at blocked "$home/worktrees/oldrepo/old" 0 'git log -1'
# agentrepo's old copy is no agent repo, though FirstMate's projects link it.
for cmd in 'git commit -m x' 'git fetch origin' 'git switch -c fix' \
           'git worktree add --no-track -b fix ~/worktrees/agentrepo/fix origin/HEAD' 'git log --oneline -3'; do
  at blocked "$box/agentrepo" 0 "$cmd"
done
at blocked "$W" 0 'git -C ~/.local/share/firstmate/projects/agentrepo commit -m x'

section "a repo in Dropbox is changed in a clone in ~/worktrees"
at allowed "$L" 0 'git clone https://github.com/ctejada10/oldrepo ~/worktrees/oldrepo/fix-2'
at allowed "$L" 0 'gh repo clone ctejada10/oldrepo ~/worktrees/oldrepo/fix-3'
at blocked "$L" 0 'git clone https://github.com/ctejada10/oldrepo'
at blocked "$home" 0 'git clone https://github.com/ctejada10/newrepo ~/Library/CloudStorage/Dropbox/repositories/newrepo'
C="$home/worktrees/oldrepo/fix"
at allowed "$C" 0 'git commit -m "Add the parser"'
at allowed "$C" 0 'git push -u origin fix'
at allowed "$C" 0 'gh pr create --draft --title x --body y'
at blocked "$C" 0 'git push --force origin fix'
at blocked "$C" 0 'git push origin HEAD:main'
at blocked "$C" 0 'gh pr create --title x --body y'
at blocked "$C" 0 'git commit -m x -m "Co-Authored-By: Claude <noreply@anthropic.com>"'

section "nor is a repo in Dropbox read as another repo's source or target"
for cmd in 'git clone ~/Library/CloudStorage/Dropbox/repositories/oldrepo ~/worktrees/oldrepo/fix-9' \
           'git clone ~/Repositories/oldrepo ~/worktrees/oldrepo/fix-9' \
           'git clone file://$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo ~/worktrees/oldrepo/fix-9' \
           'git clone --reference ~/Library/CloudStorage/Dropbox/repositories/oldrepo https://github.com/ctejada10/oldrepo ~/worktrees/oldrepo/fix-9' \
           'git clone --reference-if-able=$HOME/Repositories/oldrepo https://github.com/ctejada10/oldrepo ~/worktrees/oldrepo/fix-9' \
           'git clone ~/worktrees/oldrepo/old ~/worktrees/oldrepo/fix-9' \
           'git ls-remote ~/Library/CloudStorage/Dropbox/repositories/oldrepo' \
           'git -C ~/worktrees/agentrepo/oak fetch ~/Library/CloudStorage/Dropbox/repositories/agentrepo main' \
           'git -C ~/worktrees/agentrepo/oak pull --no-rebase ~/Repositories/agentrepo main' \
           'git -C ~/worktrees/agentrepo/oak push ~/Library/CloudStorage/Dropbox/repositories/agentrepo HEAD:fix' \
           'git -C ~/worktrees/agentrepo/oak remote add old ~/Library/CloudStorage/Dropbox/repositories/agentrepo' \
           'git -C ~/worktrees/agentrepo/oak remote set-url origin ~/Repositories/agentrepo' \
           'git -C ~/worktrees/agentrepo/oak submodule add ~/Library/CloudStorage/Dropbox/repositories/oldrepo vendor/oldrepo' \
           'ls ~/Repositories | xargs -I{} git clone ~/Repositories/{} ~/worktrees/{}/copy' \
           'echo ~/Repositories/agentrepo | xargs git -C ~/worktrees/agentrepo/oak fetch'; do
  at blocked "$home" 0 "$cmd"
done
for cmd in 'git clone https://github.com/ctejada10/oldrepo ~/worktrees/oldrepo/fix-9' \
           'git clone git@github.com:ctejada10/oldrepo.git ~/worktrees/oldrepo/fix-9' \
           'git clone ~/src/agentrepo ~/worktrees/agentrepo/copy' 'git ls-remote https://github.com/ctejada10/oldrepo' \
           'git -C ~/worktrees/agentrepo/oak fetch origin main' 'git -C ~/worktrees/agentrepo/oak fetch ~/src/agentrepo main' \
           'git -C ~/worktrees/agentrepo/oak pull --no-rebase origin main' 'git -C ~/worktrees/agentrepo/oak push -u origin HEAD' \
           'git -C ~/worktrees/agentrepo/oak push origin HEAD:refs/heads/fix-9' \
           'git -C ~/worktrees/agentrepo/oak remote add upstream https://github.com/ctejada10/agentrepo' \
           'git -C ~/worktrees/agentrepo/oak submodule add https://github.com/ctejada10/lib vendor/lib'; do
  at allowed "$home" 0 "$cmd"
done

section "the dotfiles checkout is only read, attended or not"
for attended in 0 1; do
  at blocked "$D" "$attended" 'git pull --ff-only'
  at blocked "$D" "$attended" 'git add README.md'
  at blocked "$D" "$attended" 'git switch -c fix-2'
done
at blocked "$D" 0 'git branch fix-2'
at blocked "$D" 0 'git config core.hooksPath x'
at blocked "$D" 0 'git push -u origin fix'
at blocked "$D" 0 'git checkout -- README.md'
at blocked "$D" 0 'git merge --ff-only origin/main'
at blocked "$D" 0 'git worktree add .claude/worktrees/x'
at blocked "$D" 0 'git fetch --update-head-ok origin main:main'
at blocked "$D" 0 'gh pr create --draft --title x --body y'
at blocked "$home/worktrees/dotfiles/fix" 0 'git -C ~/.local/share/chezmoi add README.md'
for cmd in 'git status' 'git log -3' 'git config --get core.hooksPath' 'git worktree list' 'git fetch origin' \
           'git remote set-head origin --auto' \
           'git worktree add --no-track -b fix-2 ~/worktrees/dotfiles/fix-2 origin/HEAD' \
           'git branch -av' 'git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null' 'git describe --dirty' \
           'git worktree lock --reason "keep: review" ~/worktrees/dotfiles/fix' 'git worktree unlock ~/worktrees/dotfiles/fix'; do
  at allowed "$D" 0 "$cmd"
done
at allowed "$home/worktrees/dotfiles/fix" 0 'git -C ~/.local/share/chezmoi worktree lock --reason=keep ~/worktrees/dotfiles/fix'

section "a worktree of the dotfiles is an ordinary repo"
F="$home/worktrees/dotfiles/fix"
at allowed "$F" 0 'git commit -m "Add the parser"'
at allowed "$F" 0 'git push -u origin fix'
at allowed "$F" 0 'gh pr create --draft --title x --body y'
at blocked "$F" 0 'git push --force origin fix'
at blocked "$F" 0 'git push origin HEAD:main'
at blocked "$F" 0 'gh pr create --title x --body y'
at blocked "$F" 0 'git commit -m x -m "Co-Authored-By: Claude <noreply@anthropic.com>"'

section "agent repos"
at allowed "$W" 0 'git commit -m "Add the parser"'
at allowed "$W" 0 'git pull --no-rebase origin main'
at allowed "$A" 0 'git fetch origin'
at allowed "$A" 0 'git remote set-head origin --auto'
at allowed "$A" 0 'git worktree add --no-track -b fix ~/worktrees/agentrepo/fix origin/HEAD'
at allowed "$A" 0 'git push -u origin worktree-oak'
at blocked "$A" 0 'git commit -m x'
at blocked "$A/pkg" 0 'cd "$(git rev-parse --show-toplevel)" && git commit -m x'
at blocked "$A/pkg" 0 'cd "$(git rev-parse --show-toplevel)" && git push origin HEAD'
at blocked "$A/pkg" 0 'cd "$(git rev-parse --show-toplevel)" && git push'
at blocked "$W" 0 'git -C "$HOME/src/agentrepo" push origin HEAD'

section "an agent repo's main checkout in ~/src keeps its branch, index and files"
for cmd in 'git switch -c add-parser' 'git checkout -b add-parser && git commit -am "Add the parser" && git push -u origin HEAD' \
           'git reset --hard origin/main' 'git add -A' 'git restore .' 'git checkout worktree-oak' 'git checkout -- README.md' \
           'git checkout origin/main' 'git checkout -' 'git switch -f main' 'git merge feature' 'git pull' 'git rebase origin/main' \
           'git cherry-pick abc123' 'git clean -fd' 'git rm README.md' 'git apply ../fix.patch' 'git submodule update --init' \
           'git fetch --update-head-ok origin main:main' 'git worktree add .claude/worktrees/x' \
           'git worktree add ~/src/agentrepo-wt' 'git commit -m "unbalanced' 'git switch -c "unbalanced'; do
  at blocked "$A" 0 "$cmd"
done
at blocked "$A/pkg" 0 'git switch -c add-parser'
at blocked "$W" 0 'git -C ~/src/agentrepo switch -c add-parser'
at blocked "$W" 0 'cd ~/src/agentrepo && git reset --hard'
for cmd in 'git switch main' 'git checkout -q main' 'git fetch --prune origin' 'git branch -d old' \
           'git merge --ff-only origin/main' 'git pull --ff-only' 'git status' 'git diff' 'git log --oneline -3' \
           'git apply --check ../fix.patch' 'git submodule status' 'git worktree list' \
           'git worktree lock --reason "keep: review" ~/worktrees/agentrepo/oak' 'git branch other' \
           'git fetch origin && git worktree add --no-track -b fix-2 ~/worktrees/agentrepo/fix-2 origin/HEAD' \
           'git switch main 2>/dev/null' 'git checkout -q main >/dev/null 2>&1' 'git pull --ff-only 2>&1 | tail -3' \
           'git merge --ff-only origin/main 2>&1'; do
  at allowed "$A" 0 "$cmd"
done
for cmd in 'git switch other 2>/dev/null' 'git pull 2>&1' '2>/dev/null git reset --hard origin/main' 'gh pr checkout 12'; do
  at blocked "$A" 0 "$cmd"
done

section "a worktree of an agent repo is an ordinary repo, wherever it is"
for dir in "$W" "$home/.t3/worktrees/agentrepo/t3-thread" "$home/.treehouse/agentrepo/crew"; do
  at allowed "$dir" 0 'git switch -c add-parser && git commit -am "Add the parser" && git push -u origin HEAD'
  at allowed "$dir" 0 'git reset --hard origin/main && git rebase origin/main'
  at blocked "$dir" 0 'git push --force origin HEAD'
  at blocked "$dir" 0 'git push origin HEAD:main'
done
# Its folder in .git/worktrees goes with it, and the main checkout's .git
# with the main checkout.
at allowed "$A/.git/worktrees/oak" 0 'git commit -m x'
at blocked "$A/.git" 0 'git reset --soft HEAD~1'

section "a submodule of an agent repo"
at blocked "$home/src/superrepo/sub" 0 "git checkout $older"
at blocked "$home/src/superrepo/sub" 0 'git switch -c bump-theme'
at blocked "$home/src/superrepo" 0 "git -C sub checkout $older && git add sub && git switch -c bump-2"
at allowed "$S/sub" 0 "git checkout $older"
at allowed "$S/sub" 0 'git switch -c bump-theme'
at blocked "$S/sub" 0 'git commit -m "Fix the theme"'
at allowed "$S" 0 "git -C sub checkout $older && git add sub && git commit -m 'Bump sub'"

section "nothing new goes in ~/src, which holds only the clones chezmoi makes"
for cmd in 'git clone https://github.com/ctejada10/newrepo ~/src/newrepo' 'gh repo clone ctejada10/newrepo ~/src/newrepo' \
           'gh repo clone ctejada10/hurin ~/src/hurin' 'git init ~/src/newrepo' 'git -C ~/src init newrepo' 'git init ~/src' \
           'cd ~/src && git clone https://github.com/ctejada10/newrepo' 'cd ~/src && gh repo clone ctejada10/newrepo' \
           'git clone --separate-git-dir ~/src/newrepo.git https://github.com/ctejada10/newrepo ~/worktrees/newrepo/main' \
           'git clone https://github.com/ctejada10/newrepo ~/src/"new-$(date +%s)"' \
           'git clone https://github.com/ctejada10/lib ~/src/agentrepo/vendor/lib' \
           'git -C ~/src/agentrepo worktree add --no-track -b fix ~/src/agentrepo-fix origin/HEAD' \
           'git -C ~/worktrees/agentrepo/oak worktree add -b fix-2 ~/src/fix-2'; do
  at blocked "$home" 0 "$cmd"
done
at blocked "$A" 0 'git init vendor/lib'
at blocked "$A/pkg" 0 'git clone https://github.com/ctejada10/lib lib'
at blocked "$W" 0 'git worktree add --no-track -b fix-3 ~/src/agentrepo-fix-3 origin/HEAD'
at blocked "$T" 0 'git worktree add -b fix-4 ../../../src/fix-4'
at blocked "$D" 0 'git worktree add --no-track -b fix-5 ~/src/dotfiles-fix-5 origin/HEAD'
at blocked "$C" 0 'git worktree add -b fix-6 ~/src/oldrepo-fix-6'
# Nor in Dropbox's repositories folder or the dotfiles checkout, from any repo.
for cmd in 'git init ~/Library/CloudStorage/Dropbox/repositories/newrepo' \
           'git -C ~/src/agentrepo worktree add -b x ~/Library/CloudStorage/Dropbox/repositories/agentrepo-x' \
           'git -C ~/worktrees/agentrepo/oak worktree add -b y ~/Library/CloudStorage/Dropbox/repositories/agentrepo-y' \
           'git clone https://github.com/ctejada10/lib ~/.local/share/chezmoi/vendor/lib' \
           'git -C ~/worktrees/agentrepo/oak worktree add -b z ~/.local/share/chezmoi/wt'; do
  at blocked "$home" 0 "$cmd"
done
for cmd in 'git clone https://github.com/ctejada10/newrepo ~/worktrees/newrepo/fix' \
           'gh repo clone ctejada10/newrepo ~/worktrees/newrepo/fix' \
           'cd ~/worktrees && git clone https://github.com/ctejada10/newrepo newrepo/fix' \
           'git -C ~/src/agentrepo worktree add --no-track -b fix-7 ~/worktrees/agentrepo/fix-7 origin/HEAD' \
           'git -C ~/src/agentrepo worktree add --no-track -b fix-8 ~/.t3/worktrees/agentrepo/fix-8 origin/HEAD' \
           'git init ~/worktrees/scratch/x'; do
  at allowed "$home" 0 "$cmd"
done
at allowed "$W" 0 'git clone https://github.com/ctejada10/lib vendor/lib'

section "gc, repack, prune and maintenance run anywhere but under Dropbox"
for cmd in 'git gc' 'git gc --aggressive --prune=now' 'git repack -ad' 'git prune' 'git maintenance run --task=gc' \
           'git maintenance start' 'git worktree prune'; do
  at allowed "$A" 0 "$cmd"
  at allowed "$W" 0 "$cmd"
  at allowed "$T" 0 "$cmd"
  at blocked "$L" 0 "$cmd"
  at blocked "$home/worktrees/oldrepo/old" 0 "$cmd"
  at blocked "$K" 0 "$cmd"
done
at allowed "$home" 0 'git -C ~/src/agentrepo gc'
at allowed "$home" 0 'git -C ~/src/agentrepo worktree prune'
for cmd in 'git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo gc' \
           'git --git-dir ~/Library/CloudStorage/Dropbox/archive/keep/.git gc' \
           'GIT_DIR=$HOME/Library/CloudStorage/Dropbox/archive/keep/.git git repack -ad' \
           'cd ~/Library/CloudStorage/Dropbox/archive/keep && git gc' 'GIT_DIR="$(cat gitdir.txt)" git gc'; do
  at blocked "$W" 0 "$cmd"
done
at blocked "$K" 0 'git gc && echo "unbalanced'
at allowed "$A" 0 'git gc && echo "unbalanced'

section "folders held in variables"
at allowed "$A" 0 'WT="$HOME/worktrees/agentrepo/oak"; cd "$WT" && git add -A && git commit -m x'
at allowed "$A" 0 'export WT=~/worktrees/agentrepo/oak; cd "$WT" && git commit -m x'
at allowed "$A" 0 'declare -x WT="$HOME/worktrees/agentrepo/oak"; git -C "$WT" commit -m x'
at allowed "$A" 0 'cd "$(mktemp -d)" && git init -q && git commit --allow-empty -m x'
at allowed "$D" 0 'T=$(mktemp -d); git init -q "$T/repo" && git -C "$T/repo" commit --allow-empty -m x'
at allowed "$D" 0 'T=`mktemp -d`; git -C "$T" init -q'
at allowed "$L" 0 'WT="$HOME/worktrees/oldrepo/fix-4"; git clone https://github.com/ctejada10/oldrepo "$WT" && cd "$WT" && git switch -c fix-4 && git commit -am x'
at blocked "$F" 0 'SRC="$HOME/.local/share/chezmoi"; git -C "$SRC" add -A && git -C "$SRC" commit -m x'
at blocked "$W" 0 'L="$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo"; git -C "$L" commit -am x'
at blocked "$W" 0 'export L=~/Library/CloudStorage/Dropbox/repositories/oldrepo; cd "$L" && git commit -am x'
at blocked "$A/pkg" 0 'WT="$(git rev-parse --show-toplevel)"; cd "$WT" && git commit -m x'

section "folders held in variables built from other variables"
at allowed "$A" 0 'b=fix-parser; wt="$HOME/worktrees/agentrepo/$b"; git fetch origin && git worktree add --no-track -b "$b" "$wt" origin/HEAD && cd "$wt"'
at allowed "$L" 0 'b=fix-x; wt=~/worktrees/oldrepo/$b; git clone https://github.com/ctejada10/oldrepo "$wt" && cd "$wt" && git switch -c "$b"'
at allowed "$D" 0 'b=fix; wt=~/worktrees/dotfiles/$b; chezmoi --source "$wt" add ~/.zshrc'
at blocked "$W" 0 'r=oldrepo; m=~/Library/CloudStorage/Dropbox/repositories/$r; git -C "$m" commit -am x'
at blocked "$W" 0 'r=agentrepo; m=~/src/$r; cd "$m" && git switch -c foo'
at blocked "$L" 0 'd=~/worktrees/oldrepo/x; d=$(pwd); t=$d; git -C "$t" commit -am x'
at blocked "$A" 0 $'b=oak\nwhile true; do\nwt=~/worktrees/agentrepo/$b\ngit -C "$wt" commit -am x\nb=../../src/agentrepo\ndone'

section "checkouts named by GIT_DIR, GIT_WORK_TREE and the like"
for cmd in 'GIT_DIR=$HOME/src/agentrepo/.git GIT_WORK_TREE=$HOME/src/agentrepo git reset --hard origin/main' \
           'env GIT_DIR=$HOME/src/agentrepo/.git GIT_WORK_TREE=$HOME/src/agentrepo git reset --hard' \
           'export GIT_DIR=$HOME/src/agentrepo/.git GIT_WORK_TREE=$HOME/src/agentrepo; git reset --hard HEAD~1' \
           'GIT_DIR=$HOME/src/agentrepo/.git git switch -c foo' \
           'GIT_DIR=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git GIT_WORK_TREE=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo git add -A' \
           'GIT_DIR=~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git git commit -m x' \
           'GIT_DIR=$HOME/.local/share/chezmoi/.git GIT_WORK_TREE=$HOME/.local/share/chezmoi git checkout -- .' \
           'B="$HOME/src/agentrepo"; GIT_DIR="$B/.git" GIT_WORK_TREE="$B" git restore .' \
           'git --work-tree=$HOME/src/agentrepo checkout HEAD~1 -- .' \
           'git --work-tree ~/Library/CloudStorage/Dropbox/repositories/oldrepo checkout -- .' \
           'GIT_WORK_TREE=~/src/agentrepo git checkout -- .' \
           'git -c core.worktree=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo checkout -- .' \
           'GIT_COMMON_DIR=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git git commit -m x' \
           'GIT_INDEX_FILE=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git/index git add README.md' \
           'export GIT_DIR=~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; cd /tmp && git commit -m x' \
           'declare -x GIT_WORK_TREE=~/.local/share/chezmoi; git checkout -- .' \
           'env -C ~/src/agentrepo git reset --hard' \
           'env -u FOO git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo commit -m x' \
           'GIT_DIR=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git chezmoi --source ~/worktrees/dotfiles/fix git -- commit -m x' \
           'GIT_DIR="$(git rev-parse --git-dir)" git commit -m x' 'git --work-tree="$WT_FROM_ELSEWHERE" checkout -- .' \
           'read GIT_DIR <<< ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; export GIT_DIR; git commit -m x' \
           'IFS= read -r GIT_WORK_TREE <<< ~/src/agentrepo; export GIT_WORK_TREE; git checkout -- .' \
           'printf -v GIT_DIR %s ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; export GIT_DIR; git commit -m x' \
           'for GIT_DIR in ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; do export GIT_DIR; git commit -m x; done' \
           'mapfile -t GIT_INDEX_FILE <<< ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git/index; export GIT_INDEX_FILE; git add -A' \
           'echo ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git | read GIT_DIR; export GIT_DIR; git commit -m x' \
           'export GIT_DIR=~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; unset -f GIT_DIR; git commit -m x'; do
  at blocked "$W" 0 "$cmd"
done
# A read there is refused just the same, and so is any use of a folder worked
# out only when the command runs, which could be one.
for cmd in 'GIT_DIR=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git git log --oneline -3' \
           'env GIT_DIR=~/Repositories/oldrepo/.git git log -1' \
           'export GIT_DIR=~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; git status' \
           'declare -x GIT_DIR=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; git log -1' \
           'GIT_WORK_TREE=~/Library/CloudStorage/Dropbox/repositories/oldrepo git status' \
           'GIT_COMMON_DIR=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git git log -1' \
           'GIT_INDEX_FILE=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git/index git diff --cached' \
           'GIT_OBJECT_DIRECTORY=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git/objects git cat-file -t HEAD' \
           'read GIT_DIR <<< ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; export GIT_DIR; git log -1' \
           'for GIT_DIR in ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; do git --no-pager log -1; done' \
           'GIT_DIR="$(git rev-parse --git-dir)" git status'; do
  at blocked "$W" 0 "$cmd"
done
for cmd in 'env GIT_DIR=~/src/agentrepo/.git git log -1' 'GIT_INDEX_FILE="$(mktemp)" git add -A' \
           'export GIT_DIR=~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git; unset GIT_DIR; git commit -m x' \
           '(export GIT_DIR=~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git); git commit -m x' \
           'GIT_DIR=$HOME/worktrees/agentrepo/oak/.git git commit -m x' 'GIT_TRACE=1 git commit -m x' \
           'GIT_DIR=$HOME/.local/share/chezmoi/.git git log -1'; do
  at allowed "$W" 0 "$cmd"
done

section "git run by xargs or find"
for cmd in 'echo x | xargs -I{} git commit --allow-empty -m {}' 'find . -maxdepth 0 -exec git commit --allow-empty -m x {} \;' \
           'git diff --name-only | xargs git add' 'git ls-files -m | xargs git checkout --' "find . -name '*.py' -exec git rm {} +" \
           'echo other | xargs git switch' 'xargs -n 1 git add < files.txt' 'xargs -0 -I % git restore % < list'; do
  at blocked "$A" 0 "$cmd"
done
for cmd in 'git diff --name-only | xargs git add' 'find . -execdir git commit -m x \;' 'echo v1 | xargs git tag' \
           'git ls-files | xargs git describe'; do
  at blocked "$L" 0 "$cmd"
done
at blocked "$D" 0 'echo x | xargs git commit --allow-empty -m'
at blocked "$home" 0 'echo ~/.zshrc | xargs chezmoi add'
at blocked "$home" 0 'echo x | xargs chezmoi apply'
at blocked "$home" 0 'echo apply | xargs chezmoi --source ~/worktrees/dotfiles/fix'
for cmd in 'echo main | xargs git push origin' 'echo --force | xargs git push origin worktree-oak' \
           'echo 12 | xargs gh pr merge' 'echo merge | xargs gh pr' 'echo push | xargs git' \
           'find ~/src -maxdepth 1 -execdir git pull \;' \
           'find ~/Library/CloudStorage/Dropbox/repositories/oldrepo -maxdepth 0 -execdir git commit -m x \;' \
           'find ~/src/agentrepo -maxdepth 0 -execdir git commit -m x \;' \
           'ls ~/src | xargs -I{} git -C ~/src/{} commit -am x' \
           $'find ~/src -maxdepth 1 -exec sh -c \'git -C "$1" commit -am x\' _ {} \\;'; do
  at blocked "$W" 0 "$cmd"
done
for cmd in 'git diff --name-only | xargs git add' "find . -name '*.py' -exec git rm {} +" \
           'echo x | xargs -I{} git commit --allow-empty -m {}' 'git ls-files | xargs git log --oneline -1 --'; do
  at allowed "$W" 0 "$cmd"
done
at allowed "$D" 0 'git ls-files | xargs git log --oneline -1 --'
at allowed "$D" 0 "find . -name '*.md' -exec git log -1 -- {} \\;"
at blocked "$L" 0 'git ls-files | xargs git log --oneline -1 --'
at blocked "$L" 0 "find . -name '*.md' -exec git log -1 -- {} \\;"
for cmd in 'echo ~/Library/CloudStorage/Dropbox/repositories/oldrepo | xargs -I{} git -C {} log -1' \
           'find ~/Library/CloudStorage/Dropbox/repositories/oldrepo -maxdepth 0 -execdir git log -1 \;' \
           'find ~/Repositories/oldrepo -maxdepth 0 -execdir git status \;' \
           'find ~/src -maxdepth 2 -name .git -execdir git status \;' \
           'find ~/src -maxdepth 2 -name .git -execdir gh pr list \;'; do
  at blocked "$W" 0 "$cmd"
done
at allowed "$A" 0 'git ls-files | xargs git blame --'
# BSD xargs replaces only in the arguments, so a one-letter -I string is no
# command name.
at allowed "$W" 0 'git ls-files | xargs -I i git log -1 -- i'
at allowed "$W" 0 "git ls-files | xargs -I s sh -c 'wc -l s'"
at allowed "$W" 0 "find tests -name 'test_*.sh' -exec bash {} \;"
at blocked "$W" 0 'echo ~/src/agentrepo | xargs -I i git -C i reset --hard'
# A comment's apostrophe inside a "$(...)" opens no quote, and a quoted
# "$(...)" holding quotes of its own hides nothing after it.
at allowed "$W" 0 $'out="$(\n  # it\'s the slow part\n  git log --oneline -3\n)"; echo "$out"'
at blocked "$W" 0 $'out="$(\n  # it\'s the slow part\n  git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo commit -am x\n)"'
at blocked "$W" 0 $'echo "$(echo "it\'s")"\ngit -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo commit -am x\necho "$(echo "it\'s")"'

section "find's groups and every action it runs"
# A quoted or escaped ( ) or ; is a word for find, not the shell's operator.
for dir in "$A" "$L" "$D"; do
  at blocked "$dir" 0 "find . \\( -name '*.py' -o -name '*.md' \\) -exec git add {} +"
  at blocked "$dir" 0 "find . '(' -name a -o -name b ')' -exec git add {} +"
  at blocked "$dir" 0 "find . -name x -exec echo {} \\; -exec git add {} \\;"
done
at blocked "$A" 0 'find . "(" -name a ")" -exec git add {} +'
at blocked "$A" 0 "find . -name '*.orig' -exec rm {} \\; -exec git rm --cached {} \\;"
at blocked "$A" 0 'find . -name "" -exec git add {} +'
at allowed "$W" 0 "find . \\( -name '*.py' -o -name '*.md' \\) -exec git add {} +"
at allowed "$D" 0 "find . \\( -name '*.md' -o -name '*.txt' \\) -exec git log -1 -- {} \\;"
at blocked "$L" 0 "find . \\( -name '*.md' -o -name '*.txt' \\) -exec git log -1 -- {} \\;"

section "what xargs or find hands over can be the subcommand or the command"
for cmd in 'echo ~/src/agentrepo reset --hard | xargs git -C' \
           'echo ~/Library/CloudStorage/Dropbox/repositories/oldrepo commit -am x | xargs git -C' \
           "printf '%s\\n' ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git commit | xargs git --git-dir" \
           'echo git push --force | xargs env' 'echo "git -C ~/src/agentrepo reset --hard" | xargs -I{} sh -c {}' \
           'echo git -C ~/src/agentrepo reset --hard | xargs nohup'; do
  at blocked "$W" 0 "$cmd"
done
at blocked "$home" 0 'echo ~/.local/share/chezmoi add ~/.zshrc | xargs chezmoi --source'
for cmd in "git ls-files | xargs -I{} sh -c 'wc -l {}'" "find . -name '*.sh' -exec bash -n {} \\;"; do
  at allowed "$W" 0 "$cmd"
done
# A folder xargs hands over could be a repo in Dropbox, so git doesn't even
# read there.
at blocked "$W" 0 'echo ~/src/agentrepo | xargs -I{} git -C {} log -1'

section "a cd in a subshell, a substitution or a pipeline ends with it, but for zsh's last stage"
for cmd in '(cd ~/.local/share/chezmoi && git log -1 --oneline) && git commit -am "Match the dotfiles"' \
           'sha=$(cd ~/.local/share/chezmoi && git rev-parse HEAD); git commit -am "Pin at $sha"' \
           '(cd ~/src/agentrepo && git fetch origin) && git rebase origin/main' \
           'pushd ~/src/agentrepo >/dev/null && git fetch origin && popd >/dev/null && git merge origin/main' \
           'cd ~/src/agentrepo && git worktree list && cd - && git commit -m x' \
           'cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo | cat; git commit -am x' \
           'cd ~/.local/share/chezmoi && git log -1 & git commit -am x'; do
  at allowed "$W" 0 "$cmd"
done
# The read inside them, in a repo in Dropbox, is refused all the same.
for cmd in '(cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo && git log -1 --oneline) && git commit -am "Match the old copy"' \
           'sha=$(cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo && git rev-parse HEAD); git commit -am "Pin at $sha"' \
           'cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo && git log -1 & git commit -am x'; do
  at blocked "$W" 0 "$cmd"
done
at blocked "$A" 0 'cd ~/worktrees/agentrepo/oak && git status & git commit -m x'
at blocked "$A" 0 'cd /tmp & git commit -m x'
for cmd in '(cd ~/worktrees/agentrepo/oak && git status) && git commit -m x' 'v=$(cd /tmp && pwd); git commit -am x' \
           'pushd /tmp && popd && git commit -am x' 'cd /tmp && cd - && git commit -am x' \
           '(cd "$(mktemp -d)" && touch x) && git add -A && git commit -m x'; do
  at blocked "$A" 0 "$cmd"
done
at blocked "$L" 0 '(cd "$(mktemp -d)" && touch x) && git add -A && git commit -m x'
at blocked "$W" 0 '(cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo && git commit -m x)'
at blocked "$W" 0 'x="$(git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo commit -am x)"'
at blocked "$W" 0 'echo `git -C ~/src/agentrepo reset --hard`'
# zsh, which runs agents' commands, runs a pipeline's last stage in the
# current shell, so a cd there lasts. bash and sh run it in a subshell.
for cmd in 'true | cd ~/src/agentrepo; git reset --hard' \
           'git status | cd ~/Library/CloudStorage/Dropbox/repositories/oldrepo && git commit -am x' \
           'echo | cd ~/.local/share/chezmoi; git checkout -- .' "zsh -c 'true | cd ~/src/agentrepo; git reset --hard'"; do
  at blocked "$W" 0 "$cmd"
done
at allowed "$W" 0 "bash -c 'true | cd ~/src/agentrepo; git reset --hard'"
at allowed "$A" 0 'true | cd ~/worktrees/agentrepo/oak; git commit -m x'
at blocked "$A" 0 "bash -c 'true | cd ~/worktrees/agentrepo/oak; git commit -m x'"
at blocked "$A" 0 $'sh <<\'EOF\'\ntrue | cd ~/worktrees/agentrepo/oak; git commit -m x\nEOF'

section "a command too deep to check is blocked, and so is one the guard fails on"
for cmd in 'echo $(echo $(echo $(echo $(git push --force origin worktree-oak))))' \
           ': $(: $(: $(: $(git -C ~/src/agentrepo reset --hard))))' \
           'cat <(cat <(cat <(cat <(git -C ~/src/agentrepo reset --hard))))' \
           'echo "$(echo "$(echo "$(echo "$(git push --force origin worktree-oak)")")")"' \
           "bash -c 'echo \$(echo \$(echo \$(git push --force origin worktree-oak)))'"; do
  at blocked "$W" 0 "$cmd"
done
at allowed "$W" 0 'echo "$(echo "$(echo "$(git branch --show-current)")")"'
# So deep that Python gives up: a crash would let the force-push through.
deep='git push --force; echo '
for _ in $(seq 1500); do deep+='"$('; done
deep+=x
for _ in $(seq 1500); do deep+=')"'; done
at blocked "$W" 0 "$deep" 'git push --force beside 1500 nested "$( in double quotes'
# A NUL in a folder name makes Python's path calls fail.
jq -n --arg d "$W" '{tool_input: {command: "cd \"a\u0000b\" && git commit -m x"}, cwd: $d}' \
  | HOME="$home" /usr/bin/python3 -B "$hook" 2>/dev/null
got=$(outcome $?)
if [ "$got" = blocked ]; then pass "blocked in ~${W#"$home"}: a cd to a folder whose name holds a NUL"
else fail "blocked in ~${W#"$home"}: a cd to a folder whose name holds a NUL" "got $got"; fi

section "a new folder whose name is worked out when the command runs"
at allowed "$A" 0 'git worktree add --no-track -b "fix-$(date +%s)" ~/worktrees/agentrepo/"fix-$(date +%s)" origin/HEAD'
at allowed "$A" 0 'git worktree add --no-track -b fix-$(date +%s) ~/worktrees/agentrepo/fix-$(date +%s) origin/HEAD'
at allowed "$A" 0 'repo=$(basename "$PWD"); git worktree add --no-track -b fix "$HOME/worktrees/$repo/fix" origin/HEAD'
at allowed "$L" 0 'git clone https://github.com/ctejada10/oldrepo ~/worktrees/oldrepo/fix-$(date +%Y%m%d)'
at allowed "$L" 0 'gh repo clone ctejada10/oldrepo ~/worktrees/oldrepo/"fix-$(date +%s)"'
at allowed "$D" 0 'git worktree add --no-track -b fix-3 ~/worktrees/dotfiles/fix-$(date +%s) origin/HEAD'
at allowed "$home" 0 'chezmoi --source ~/worktrees/dotfiles/"$(git -C ~/worktrees/dotfiles/fix branch --show-current)" add ~/.zshrc'
at blocked "$A" 0 'git worktree add ~/src/agentrepo/wt-$(date +%s)'
at blocked "$A" 0 'git worktree add wt-$(date +%s)'
at blocked "$L" 0 'git clone https://github.com/ctejada10/oldrepo ~/Library/CloudStorage/Dropbox/repositories/oldrepo-$(date +%s)'
at blocked "$L" 0 'git clone https://github.com/ctejada10/oldrepo ~/src/oldrepo-$(date +%s)'
at blocked "$D" 0 'git worktree add ~/.local/share/chezmoi/wt-$(date +%s)'
at blocked "$W" 0 'git clone https://github.com/ctejada10/newrepo ~/$(echo src)/newrepo'
at blocked "$W" 0 'git worktree add "$(git rev-parse --show-toplevel)/../wt-2"'

section "a branch picked up with --track or gh pr checkout"
at blocked "$T" 0 'git commit -am x'
at allowed "$T" 0 'git checkout --track origin/review && git pull --no-rebase origin main && git push'
at allowed "$T" 0 'git checkout -t origin/review && git commit -am "Address review"'
at allowed "$T" 0 'gh pr checkout 12 && git pull --no-rebase origin main && git push'
at allowed "$T" 0 'gh pr checkout 12 -b review-12 && git commit -am "Address review"'
at blocked "$T" 0 'git checkout --track origin/main && git commit -am x'

section "commands shlex can't split on its own"
at allowed "$A" 0 $'cd ~/worktrees/agentrepo/oak && git commit -m "$(echo "It\'s done")"'
at allowed "$A" 0 $'cd ~/worktrees/agentrepo/oak && git commit -m $\'Fix the parser\\n\\nIt\\\'s strict now.\''
at allowed "$D" 0 $'cd ~/worktrees/dotfiles/fix && git commit -m $\'Fix the parser\\n\\nIt\\\'s strict now.\''
at blocked "$W" 0 $'cd ~/src/agentrepo && git commit -m $\'It\\\'s done\''
at blocked "$home/worktrees/dotfiles/fix" 0 $'cd ~/.local/share/chezmoi && git commit -m $\'It\\\'s done\''
at allowed "$A" 0 'cd ~/worktrees/agentrepo/oak && git commit -m "unbalanced'
at blocked "$W" 0 'cd ~/src/agentrepo && git commit -m "unbalanced'
at blocked "$W" 0 'git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo commit -m "unbalanced'
# Nor do they read a repo in Dropbox, wherever they name it.
for cmd in 'git -C ~/Library/CloudStorage/Dropbox/repositories/oldrepo log -1 && echo "unbalanced' \
           'cd ~/Repositories/oldrepo && git status && echo "unbalanced' \
           'git --git-dir ~/Library/CloudStorage/Dropbox/repositories/oldrepo/.git log -1 && echo "unbalanced' \
           'GIT_DIR=$HOME/Library/CloudStorage/Dropbox/repositories/oldrepo/.git git status && echo "unbalanced' \
           'git clone ~/Repositories/oldrepo ~/worktrees/oldrepo/fix-9 && echo "unbalanced'; do
  at blocked "$W" 0 "$cmd"
done
for cmd in 'git status && echo "unbalanced' 'gh pr view 3 && echo "unbalanced'; do
  at blocked "$L" 0 "$cmd"
done
at allowed "$W" 0 'git -C ~/.local/share/chezmoi log -1 && echo "unbalanced'

section "chezmoi writes the dotfiles checkout"
for cmd in 'chezmoi add ~/.config/t3-pstack/models.md' 'chezmoi re-add ~/.claude/settings.json' 'chezmoi re-add' \
           'chezmoi forget ~/.zshrc' 'chezmoi chattr +template ~/.zshrc' 'chezmoi edit ~/.zshrc' 'chezmoi push' \
           'chezmoi git -- commit -m "Capture the t3-pstack config"' 'chezmoi git -- push origin main' \
           'chezmoi git -- add -A' 'chezmoi git pull' 'chezmoi -S ~/.local/share/chezmoi add ~/.zshrc' \
           'cd ~/worktrees/dotfiles/fix && chezmoi add ~/.zshrc' 'chezmoi --source ~/worktrees/dotfiles/fix git -- push origin main'; do
  at blocked "$home" 0 "$cmd"
done
# apply, init and update change the Mac itself, whatever the flags say.
for cmd in 'chezmoi apply' 'chezmoi -v apply' 'chezmoi --source ~/worktrees/dotfiles/fix apply' \
           'chezmoi -S ~/worktrees/dotfiles/fix -D "$(mktemp -d)" apply --exclude=scripts' \
           'chezmoi --source=$HOME/worktrees/dotfiles/fix apply ~/.zshrc' 'chezmoi init --apply ctejada10' \
           'chezmoi --source ~/worktrees/dotfiles/fix update' 'cd ~/worktrees/dotfiles/fix && chezmoi -n apply'; do
  at blocked "$home" 0 "$cmd"
done
# So do destroy, purge, edit-config, the state writes and an edit that applies.
for cmd in 'chezmoi --source ~/worktrees/dotfiles/fix destroy --force ~/.zshrc' 'chezmoi -S ~/worktrees/dotfiles/fix purge --force' \
           'chezmoi --source ~/worktrees/dotfiles/fix edit --apply ~/.zshrc' 'chezmoi --source ~/worktrees/dotfiles/fix edit -a ~/.zshrc' \
           'chezmoi -S ~/worktrees/dotfiles/fix edit -va ~/.zshrc' 'chezmoi --source ~/worktrees/dotfiles/fix edit --watch ~/.zshrc' \
           'chezmoi --source ~/worktrees/dotfiles/fix edit --init' 'chezmoi --source ~/worktrees/dotfiles/fix edit --apply=true ~/.zshrc' \
           'chezmoi state reset' 'chezmoi --source ~/worktrees/dotfiles/fix state delete-bucket --bucket=entryState' \
           'chezmoi edit-config'; do
  at blocked "$home" 0 "$cmd"
done
for cmd in 'chezmoi git status' 'chezmoi git -- log --oneline -3' 'chezmoi git -- fetch origin' 'chezmoi diff' \
           'chezmoi status' 'chezmoi managed' 'chezmoi --source ~/worktrees/dotfiles/fix add ~/.config/t3-pstack/models.md' \
           'chezmoi -S ~/worktrees/dotfiles/fix re-add' 'chezmoi --source=$HOME/worktrees/dotfiles/fix forget ~/.zshrc' \
           'chezmoi --source ~/worktrees/dotfiles/fix git -- commit -m "Capture the t3-pstack config"' \
           'chezmoi -W ~/worktrees/dotfiles/fix git -- push -u origin fix' \
           'chezmoi --source ~/worktrees/dotfiles/fix diff' 'chezmoi --source ~/worktrees/dotfiles/fix execute-template < x.tmpl' \
           'chezmoi --source ~/worktrees/dotfiles/fix edit ~/.zshrc' 'chezmoi --source ~/worktrees/dotfiles/fix edit --apply=false ~/.zshrc' \
           'chezmoi -S ~/worktrees/dotfiles/fix edit -x scripts ~/.zshrc' 'chezmoi state dump'; do
  at allowed "$home" 0 "$cmd"
done

section "what a block offers instead"
# says <folder> <command> <text>: the block's message contains text.
says() {
  local dir="$1" cmd="$2" text="$3" out
  out=$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_input: {command: $c}, cwd: $d}' \
          | HOME="$home" /usr/bin/python3 -B "$hook" 2>&1)
  if grep -qF -- "$text" <<< "$out"; then pass "$cmd: says $text"; else fail "$cmd: says $text" "$out"; fi
}
says "$A" 'git switch -c add-parser' 'git worktree add --no-track -b <branch> ~/worktrees/agentrepo/<branch> origin/HEAD'
git -C "$work/repo" switch -q main
says "$work/repo" 'git commit -m x' "in a worktree if this is the repo's main checkout"
says "$D" 'git commit -m x' 'and git worktree lock or unlock'
says "$home" 'chezmoi add ~/.zshrc' 'chezmoi --source ~/worktrees/dotfiles/<branch> add'
says "$home" 'chezmoi -v apply' 'or bash tests/run.sh in that worktree'
says "$home" 'chezmoi destroy ~/.zshrc' 'git rm its source file in ~/worktrees/dotfiles/<branch>'
says "$W" 'GIT_DIR="$(git rev-parse --git-dir)" git commit -m x' 'Name the folder in the command'
says "$W" 'echo $(echo $(echo $(echo $(echo hi))))' 'Split it into separate commands'
says "$W" 'echo ~/src/agentrepo reset --hard | xargs git -C' 'Name the subcommand'
# ends <folder> <command> <text>: the block's message ends with text.
ends() {
  local dir="$1" cmd="$2" text="$3" out
  out=$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_input: {command: $c}, cwd: $d}' \
          | HOME="$home" /usr/bin/python3 -B "$hook" 2>&1)
  if [[ "$out" == *"$text" ]]; then pass "$cmd: ends with $text"; else fail "$cmd: ends with $text" "$out"; fi
}
# omits <folder> <command> <text>: the block's message doesn't contain text.
omits() {
  local dir="$1" cmd="$2" text="$3" out
  out=$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_input: {command: $c}, cwd: $d}' \
          | HOME="$home" /usr/bin/python3 -B "$hook" 2>&1)
  if grep -qF -- "$text" <<< "$out"; then fail "$cmd: never says $text" "$out"; else pass "$cmd: never says $text"; fi
}
says "$A" 'git reset --hard' "agentrepo's main checkout in ~/src"
for cmd in 'git switch -c add-parser' 'git commit -m "unbalanced' 'gh pr checkout 12' 'git worktree add ~/src/agentrepo-wt'; do
  ends "$A" "$cmd" 'git fetch origin, then git worktree add --no-track -b <branch> ~/worktrees/agentrepo/<branch> origin/HEAD'
  omits "$A" "$cmd" 'Dropbox'
done
ends "$home/src/superrepo/sub" "git checkout $older" \
  'git fetch origin, then git worktree add --no-track -b <branch> ~/worktrees/superrepo/<branch> origin/HEAD'
for cmd in 'git status' 'git describe --dirty' 'git commit -m x'; do
  says "$L" "$cmd" "would use oldrepo in Dropbox's repositories folder, the repos' old home, which nothing on this Mac uses, not even to read."
  ends "$L" "$cmd" 'Read it on GitHub, or clone it from GitHub into ~/worktrees/oldrepo/<branch>.'
done
says "$L" 'gh pr view 3' '`gh pr view` would use oldrepo'
says "$home" 'git clone ~/Repositories/oldrepo ~/worktrees/oldrepo/fix-9' '`git clone` would use oldrepo'
says "$W" 'echo ~/src/agentrepo | xargs -I{} git -C {} log -1' 'would use a folder worked out only when the command runs'
says "$home" 'git clone https://github.com/ctejada10/newrepo ~/src/newrepo' 'That folder holds only the clones chezmoi makes'
ends "$home" 'git clone https://github.com/ctejada10/newrepo ~/src/newrepo' \
  'git fetch origin, then git worktree add --no-track -b <branch> ~/worktrees/<repo>/<branch> origin/HEAD'
omits "$home" 'git clone https://github.com/ctejada10/newrepo ~/src/newrepo' 'Dropbox'
says "$W" 'GIT_DIR="$(git rev-parse --git-dir)" git commit -m x' "an agent repo's main checkout in ~/src"
says "$K" 'git gc' 'this repo is under ~/Library/CloudStorage/Dropbox'
says "$K" 'git worktree prune' '`git worktree prune` rewrites'

section "more that the rules forbid"
# gc and git worktree prune run as usual in a repo outside Dropbox.
expect allowed feature 'git gc --aggressive'
expect allowed feature 'git worktree prune'
expect blocked feature 'git worktree remove --force ../wt'
expect blocked feature 'git stash'
expect allowed feature 'git stash list'
expect blocked feature 'git branch -D old'
expect blocked feature 'git commit --no-verify -m x'
expect blocked feature 'git push --delete origin old'
expect blocked feature 'git push origin :old'
expect blocked feature 'gh pr create --draft --title x --body "Generated with Claude Code"'
expect allowed feature 'git push -n origin feature'

summary
