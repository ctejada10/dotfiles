#!/usr/bin/env bash
# The mini's WorktreeCreate and WorktreeRemove hook, in a throwaway home and
# repo: worktrees go outside the repo, their commits land in it, a name used
# again reopens its worktree, removal never loses work, and a repo in Dropbox's
# repositories folder gets none, attended or not.
#
#   bash tests/worktree.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

hook="$REPO/home/dot_claude/hooks/executable_worktree.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/worktree-hook.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME/.local/bin"
# The hook asks worktree-ttl, which chezmoi installs beside it, what
# removal would lose.
ln -s "$REPO/home/dot_local/bin/executable_worktree-ttl" "$HOME/.local/bin/worktree-ttl"
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# clone_with_origin <folder>: a checkout of a new bare origin whose default is main.
clone_with_origin() {
  g init -q --bare -b main "$1.origin.git"
  g clone -q "$1.origin.git" "$1" 2>/dev/null
  g -C "$1" commit -q --allow-empty -m init
  g -C "$1" push -q origin main
  g -C "$1" remote set-head origin main
}
clone_with_origin "$work/repo"

attended=0
hookrun() {
  jq -n --arg n "$2" --arg c "$3" --arg p "$4" '{name: $n, cwd: $c, worktree_path: $p}' \
    | AGENT_ATTENDED="$attended" bash "$hook" "$1"
}

section "create"
out=$(hookrun create bold-oak "$work/repo" "" 2>/dev/null)
path=$(printf '%s\n' "$out" | tail -n 1)
[ "$path" = "$HOME/worktrees/repo/bold-oak" ] && pass "prints a path under ~/worktrees/<repo>" || fail "prints a path under ~/worktrees/<repo>" "$out"
[ -d "$path" ] && pass "creates the worktree there" || fail "creates the worktree there"
[ ! -e "$work/repo/.claude/worktrees" ] && pass "puts nothing inside the repo" || fail "puts nothing inside the repo"
[ "$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null)" = worktree-bold-oak ] \
  && pass "checks out worktree-<name>" || fail "checks out worktree-<name>"
git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 \
  && fail "the new branch tracks nothing yet" || pass "the new branch tracks nothing yet"
out2=$(hookrun create quiet-elm "$path" "" 2>/dev/null | tail -n 1)
[ "$out2" = "$HOME/worktrees/repo/quiet-elm" ] && pass "from inside a worktree, still names the main repo" || fail "from inside a worktree, still names the main repo" "$out2"

section "a name used again"
again=$(hookrun create bold-oak "$work/repo" "" 2>/dev/null) \
  && [ "$(printf '%s\n' "$again" | tail -n 1)" = "$path" ] \
  && pass "reopens the worktree that is still there" || fail "reopens the worktree that is still there" "$again"
mkdir -p "$HOME/worktrees/repo/stray"
if hookrun create stray "$work/repo" "" >/dev/null 2>&1; then
  fail "refuses a folder at the path that isn't a worktree of the repo"
else
  pass "refuses a folder at the path that isn't a worktree of the repo"
fi
[ ! -e "$HOME/worktrees/repo/stray/.git" ] && pass "leaves that folder alone" || fail "leaves that folder alone"

section "commits land in the main repo"
g -C "$path" commit -q --allow-empty -m "work"
git -C "$work/repo" rev-parse --verify -q refs/heads/worktree-bold-oak >/dev/null \
  && pass "the branch is in the main repo's .git" || fail "the branch is in the main repo's .git"

section "remove"
touch "$path/unsaved"
if hookrun remove "" "" "$path" 2>/dev/null; then fail "refuses a worktree with changes"; else pass "refuses a worktree with changes"; fi
[ -f "$path/unsaved" ] && pass "keeps the unsaved file" || fail "keeps the unsaved file"
rm "$path/unsaved"
hookrun remove "" "" "$path" 2>/dev/null && pass "removes a clean worktree" || fail "removes a clean worktree"
[ ! -e "$path" ] && pass "the folder is gone" || fail "the folder is gone"
git -C "$work/repo" rev-parse --verify -q refs/heads/worktree-bold-oak >/dev/null \
  && pass "keeps a branch with unpushed work" || fail "keeps a branch with unpushed work"
p2="$HOME/worktrees/repo/quiet-elm"
hookrun remove "" "" "$p2" 2>/dev/null
git -C "$work/repo" rev-parse --verify -q refs/heads/worktree-quiet-elm >/dev/null \
  && fail "deletes a branch with nothing new" || pass "deletes a branch with nothing new"

section "a name used again after its worktree was removed"
out=$(hookrun create bold-oak "$work/repo" "" 2>/dev/null) && pass "creates it again" || fail "creates it again" "$out"
[ "$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null)" = worktree-bold-oak ] \
  && [ "$(git -C "$path" log -1 --format=%s 2>/dev/null)" = work ] \
  && pass "carries on from the kept branch" || fail "carries on from the kept branch"

section "a detached HEAD"
det=$(hookrun create det "$work/repo" "" 2>/dev/null | tail -n 1)
g -C "$det" switch -q --detach
g -C "$det" commit -q --allow-empty -m "detached work"
if hookrun remove "" "" "$det" 2>/dev/null; then fail "refuses one with commits no branch holds"; else pass "refuses one with commits no branch holds"; fi
[ -d "$det" ] && pass "keeps that worktree" || fail "keeps that worktree"
det2=$(hookrun create det2 "$work/repo" "" 2>/dev/null | tail -n 1)
g -C "$det2" switch -q --detach
hookrun remove "" "" "$det2" 2>/dev/null && [ ! -e "$det2" ] \
  && pass "removes one with nothing new" || fail "removes one with nothing new"

section "work that git worktree remove would lose without a word"
# refuses <what> <path> <part of the message>: the hook refuses, says what
# would be lost, and leaves the worktree.
refuses() {
  local err
  if err=$(hookrun remove "" "" "$2" 2>&1 >/dev/null); then
    fail "refuses one $1"
  elif printf '%s\n' "$err" | grep -Fq -- "$3"; then
    pass "refuses one $1, saying what would be lost"
  else
    fail "refuses one $1, saying what would be lost" "$err"
  fi
  [ -d "$2" ] && pass "leaves that worktree" || fail "leaves that worktree"
}
# Not grep -q: with pipefail, rev-list's broken pipe would fail the check.
reach() { git -C "$work/repo" rev-list --all --reflog 2>/dev/null | grep -x -- "$1" >/dev/null; }
pushed() { # name: a worktree whose branch has one commit, pushed
  local p
  p=$(hookrun create "$1" "$work/repo" "" 2>/dev/null | tail -n 1)
  (cd "$p" && echo "$1" >"f-$1.txt" && g add "f-$1.txt" && g commit -q -m "$1" && g push -q -u origin HEAD 2>/dev/null)
  printf '%s\n' "$p"
}
# A commit on a detached HEAD, then the branch checked out again.
p=$(pushed h2)
g -C "$p" switch -q --detach; g -C "$p" commit -q --allow-empty -m "experiment"
x=$(git -C "$p" rev-parse HEAD); g -C "$p" switch -q worktree-h2
refuses "whose HEAD reflog alone holds a commit" "$p" "1 commit(s) on no branch or remote ($(printf '%.10s' "$x"))"
reach "$x" && pass "that commit is still there" || fail "that commit is still there"
# A commit on a branch the agent then deleted, which took its reflog along.
p=$(pushed h2b)
g -C "$p" switch -q -c side; g -C "$p" commit -q --allow-empty -m "side work"
g -C "$p" switch -q worktree-h2b; g -C "$p" branch -q -D side
refuses "whose deleted branch's commit only its HEAD reflog holds" "$p" "on no branch or remote"
# A detached commit that only a local tag holds.
p=$(hookrun create h3 "$work/repo" "" 2>/dev/null | tail -n 1)
g -C "$p" switch -q --detach; g -C "$p" commit -q --allow-empty -m "tagged"
g -C "$work/repo" tag snap-h3 "$(git -C "$p" rev-parse HEAD)"
refuses "whose commit only a local tag holds" "$p" "a local tag will not do"
# Edits that skip-worktree and assume-unchanged hide from git status.
for flag in assume-unchanged skip-worktree; do
  p=$(pushed "h-$flag")
  echo "edit that matters" >>"$p/f-h-$flag.txt"
  git -C "$p" update-index "--$flag" "f-h-$flag.txt"
  refuses "with an edit $flag hides" "$p" "edit hidden by skip-worktree or assume-unchanged (f-h-$flag.txt)"
  grep -q 'edit that matters' "$p/f-h-$flag.txt" && pass "keeps that edit" || fail "keeps that edit"
done
# A clone with a commit of its own inside a folder the worktree's .gitignore hides.
p=$(hookrun create h4 "$work/repo" "" 2>/dev/null | tail -n 1)
(cd "$p" && echo "vendor/" >.gitignore && g add .gitignore && g commit -q -m vendor && g push -q -u origin HEAD 2>/dev/null)
g clone -q "$work/repo.origin.git" "$p/vendor/lib" 2>/dev/null
g -C "$p/vendor/lib" commit -q --allow-empty -m "patch lib"
[ -z "$(git -C "$p" status --porcelain)" ] || fail "git status hides the clone" "$(git -C "$p" status --porcelain)"
refuses "with a clone in an ignored folder" "$p" "contains another repository or worktree ($(cd "$p" && pwd -P)/vendor/lib)"
git -C "$p/vendor/lib" log -1 --format=%s 2>/dev/null | grep -q 'patch lib' && pass "keeps that clone" || fail "keeps that clone"
# A commit reset away on a pushed branch, which only the branch's reflog holds.
p=$(pushed rl)
g -C "$p" commit -q --allow-empty -m "reset away"; x=$(git -C "$p" rev-parse HEAD)
g -C "$p" reset -q --hard '@{upstream}'
err=$(hookrun remove "" "" "$p" 2>&1 >/dev/null) && [ ! -e "$p" ] \
  && pass "removes the worktree of a branch whose reflog alone holds a commit" \
  || fail "removes the worktree of a branch whose reflog alone holds a commit" "$err"
git -C "$work/repo" rev-parse -q --verify refs/heads/worktree-rl >/dev/null && reach "$x" \
  && pass "keeps that branch, so its reflog keeps the commit" || fail "keeps that branch, so its reflog keeps the commit"
printf '%s\n' "$err" | grep -Fq "kept branch worktree-rl: it or its reflog holds 1 commit(s)" \
  && pass "says why it kept the branch" || fail "says why it kept the branch" "$err"
# A commit amended before the push: the old one lives on in the new one.
p=$(hookrun create amend "$work/repo" "" 2>/dev/null | tail -n 1)
(cd "$p" && echo a >a.txt && g add a.txt && g commit -q -m a && echo b >>a.txt && g commit -q -a --amend -m a &&
  g push -q -u origin HEAD 2>/dev/null)
hookrun remove "" "" "$p" 2>/dev/null && [ ! -e "$p" ] \
  && ! git -C "$work/repo" rev-parse -q --verify refs/heads/worktree-amend >/dev/null \
  && pass "removes one whose only other commit was amended, and its branch" \
  || fail "removes one whose only other commit was amended, and its branch"
# Without worktree-ttl the hook cannot tell, so nothing goes.
p=$(hookrun create nottl "$work/repo" "" 2>/dev/null | tail -n 1)
mv "$HOME/.local/bin/worktree-ttl" "$HOME/.local/bin/worktree-ttl.away"
refuses "when worktree-ttl is missing" "$p" "can't find $HOME/.local/bin/worktree-ttl"
mv "$HOME/.local/bin/worktree-ttl.away" "$HOME/.local/bin/worktree-ttl"
[ ! -e "$HOME/Library/Logs/worktree-ttl" ] && pass "the check writes no log" || fail "the check writes no log"

section "rebases and looks around that lose nothing"
# A second clone, for a teammate who moves origin's main and pushes tags.
g clone -q "$work/repo.origin.git" "$work/mover" 2>/dev/null
move_main() { (cd "$work/mover" && echo "$1" >"m-$1.txt" && g add "m-$1.txt" && g commit -q -m "main $1" && g push -q origin main) >/dev/null 2>&1; }
note() { (cd "$1" && echo "$2" >>"f-$2.txt" && g add "f-$2.txt" && g commit -q -m "$2"); }
fixup() { (cd "$1" && echo fix >>"f-$2.txt" && g commit -q -a --fixup "$3"); }
# rebase_i <path> [todo edit] [message edit]: rebase -i --autosquash onto
# origin/main, each edit a perl expression run on the file git opens.
rebase_i() {
  local todo=true msg=true
  [ -n "${2:-}" ] && todo="perl -pi -e '$2'"
  [ -n "${3:-}" ] && msg="perl -pi -e '$3'"
  GIT_SEQUENCE_EDITOR=$todo GIT_EDITOR=$msg g -C "$1" rebase -q -i --autosquash origin/main >/dev/null 2>&1
}
goes() { # what path: the hook removes the worktree and deletes its branch
  local err b
  b=$(git -C "$2" symbolic-ref -q --short HEAD)
  err=$(hookrun remove "" "" "$2" 2>&1 >/dev/null)
  if [ ! -e "$2" ] && [ -n "$b" ] && ! git -C "$work/repo" rev-parse -q --verify "refs/heads/$b" >/dev/null; then
    pass "removes one $1, and its branch"
  else
    fail "removes one $1, and its branch" "$err"
  fi
}
# A rebase leaves commits that only the HEAD reflog holds, such as a fold's
# halfway commit, but their changes live on in the tip it ended on.
p=$(hookrun create rb-fx2 "$work/repo" "" 2>/dev/null | tail -n 1)
note "$p" fx2; fixup "$p" fx2 HEAD; fixup "$p" fx2 HEAD~1
rebase_i "$p"; g -C "$p" push -q -u origin HEAD 2>/dev/null
goes "whose commit took two fixups in place and was pushed" "$p"
p=$(hookrun create rb-fx3 "$work/repo" "" 2>/dev/null | tail -n 1)
note "$p" fa; note "$p" fb; fixup "$p" fa HEAD~1; fixup "$p" fb HEAD~1
rebase_i "$p"; g -C "$p" push -q -u origin HEAD 2>/dev/null
goes "whose two commits each took a fixup in place and were pushed" "$p"
p=$(hookrun create rb-sq "$work/repo" "" 2>/dev/null | tail -n 1)
note "$p" sqa; note "$p" sqb; move_main sq; g -C "$p" fetch -q
rebase_i "$p" 's/^pick/squash/ if $. == 2'; g -C "$p" push -q -u origin HEAD 2>/dev/null
goes "whose two commits were squashed onto a moved main and pushed" "$p"
p=$(hookrun create rb-rw "$work/repo" "" 2>/dev/null | tail -n 1)
note "$p" rw; move_main rw; g -C "$p" fetch -q
rebase_i "$p" 's/^pick/reword/ if $. == 1' '$_ = "reworded\n" if $. == 1'; g -C "$p" push -q -u origin HEAD 2>/dev/null
[ "$(git -C "$p" log -1 --format=%s)" = reworded ] || fail "the reword took" "$(git -C "$p" log -1 --format=%s)"
goes "whose commit was reworded onto a moved main and pushed" "$p"
# A squash on a branch since deleted: only the HEAD reflog holds its tip,
# which keeps the worktree, and that tip is the one commit to push.
p=$(hookrun create rb-lost "$work/repo" "" 2>/dev/null | tail -n 1)
g -C "$p" switch -q -c scratch; note "$p" lost; fixup "$p" lost HEAD; fixup "$p" lost HEAD~1
rebase_i "$p"; x=$(git -C "$p" rev-parse HEAD)
mid=$(git -C "$p" log -g --format='%H %gs' | awk '/This is a combination/ { print $1; exit }')
g -C "$p" switch -q worktree-rb-lost; g -C "$p" branch -q -D scratch
refuses "whose squash only the HEAD reflog holds" "$p" "1 commit(s) on no branch or remote ($(printf '%.10s' "$x"))"
[ -n "$mid" ] && reach "$x" && reach "$mid" && pass "the squash and its halfway commit are still there" \
  || fail "the squash and its halfway commit are still there"
# A release tag that no branch holds, and a teammate's branch, pushed to origin.
(cd "$work/mover" && g switch -q --detach && echo release >rel.txt && g add rel.txt && g commit -q -m release &&
  g tag v1 && g push -q origin v1 && g switch -q main &&
  g switch -q -c teammate && echo theirs >t.txt && g add t.txt && g commit -q -m theirs &&
  g push -q origin teammate && g switch -q main) >/dev/null 2>&1
g -C "$work/repo" fetch -q --tags origin
# A look at that tag on a detached HEAD, then back to the branch.
p=$(pushed look); g -C "$p" switch -q --detach v1; g -C "$p" switch -q worktree-look
goes "whose HEAD only looked at a tag that no branch holds" "$p"
# The teammate's branch reviewed on a detached HEAD, which stays there, and
# then merged by squash and deleted, so no ref holds that commit now.
p=$(hookrun create review "$work/repo" "" 2>/dev/null | tail -n 1)
g -C "$p" switch -q --detach origin/teammate
g --git-dir="$work/repo.origin.git" branch -q -D teammate; g -C "$work/repo" fetch -q --prune origin
err=$(hookrun remove "" "" "$p" 2>&1 >/dev/null) && [ ! -e "$p" ] \
  && pass "removes one left on a teammate's commit that it only checked out" \
  || fail "removes one left on a teammate's commit that it only checked out" "$err"
# A commit made on top of the tag is work, and so is a stash checked out and
# then dropped: git stash writes no HEAD reflog entry, so only the checkout
# names it.
p=$(hookrun create tagwork "$work/repo" "" 2>/dev/null | tail -n 1)
g -C "$p" switch -q --detach v1; g -C "$p" commit -q --allow-empty -m "on the tag"
x=$(git -C "$p" rev-parse HEAD); g -C "$p" switch -q worktree-tagwork
refuses "with a commit made on a tag it looked at" "$p" "$(printf '%.10s' "$x")"
reach "$x" && pass "that commit is still there" || fail "that commit is still there"
p=$(pushed stashed)
echo "work in a stash" >>"$p/f-stashed.txt"; g -C "$p" stash -q; x=$(git -C "$p" rev-parse 'stash@{0}')
g -C "$p" checkout -q 'stash@{0}'; g -C "$p" switch -q worktree-stashed; g -C "$p" stash drop -q
refuses "whose dropped stash only a checkout of it names" "$p" "$(printf '%.10s' "$x")"
reach "$x" && pass "that stash is still there" || fail "that stash is still there"

section "whose repo it is"
# A home laid out like the mini's: the agents' repos cloned into a real ~/src,
# and Dropbox's repositories folder, the repos' old home, with a repo still in
# it. No FirstMate projects folder yet: where a repo is decides whose it is.
box="$HOME/Library/CloudStorage/Dropbox/repositories"
mkdir -p "$box" "$HOME/src"
clone_with_origin "$HOME/src/agentrepo"
clone_with_origin "$box/oldrepo"
clone_with_origin "$HOME/.local/share/chezmoi"
# The old link into the repositories folder, which a Mac set up before the
# move may still have.
ln -s "$box" "$HOME/Repositories"
rm -f "$box/oldrepo/.git/FETCH_HEAD"
for attended in 0 1; do
  if hookrun create probe "$box/oldrepo" "" >/dev/null 2>&1; then
    fail "refuses a repo in Dropbox (attended=$attended)"
  else
    pass "refuses a repo in Dropbox (attended=$attended)"
  fi
done
attended=0
if hookrun create probe "$HOME/Repositories/oldrepo" "" >/dev/null 2>&1; then
  fail "refuses a repo in Dropbox reached through a link"
else
  pass "refuses a repo in Dropbox reached through a link"
fi
err=$(hookrun create probe "$box/oldrepo" "" 2>&1 >/dev/null)
printf '%s\n' "$err" | grep -Fq "oldrepo is in Dropbox's repositories folder, the repos' old home" \
  && pass "says the repo is in the repos' old home" || fail "says the repo is in the repos' old home" "$err"
[ -z "$(git -C "$box/oldrepo" branch --list worktree-probe)" ] && [ ! -e "$box/oldrepo/.git/FETCH_HEAD" ] \
  && [ ! -e "$HOME/worktrees/oldrepo/probe" ] \
  && pass "writes nothing to the repo in Dropbox" || fail "writes nothing to the repo in Dropbox"
before=$(ls -A "$HOME/src" "$HOME/src/agentrepo")
out=$(hookrun create probe "$HOME/src/agentrepo" "" 2>/dev/null | tail -n 1)
[ "$out" = "$HOME/worktrees/agentrepo/probe" ] && [ -d "$out" ] \
  && pass "makes one for an agent repo in ~/src, in ~/worktrees/<repo>" \
  || fail "makes one for an agent repo in ~/src, in ~/worktrees/<repo>" "$out"
[ "$(ls -A "$HOME/src" "$HOME/src/agentrepo")" = "$before" ] \
  && pass "puts nothing in ~/src" || fail "puts nothing in ~/src" "$(ls -A "$HOME/src" "$HOME/src/agentrepo")"
hookrun remove "" "" "$out" 2>/dev/null && [ ! -e "$out" ] \
  && pass "removes an agent repo's worktree" || fail "removes an agent repo's worktree"
out=$(hookrun create probe "$HOME/.local/share/chezmoi" "" 2>/dev/null | tail -n 1)
[ "$out" = "$HOME/worktrees/dotfiles/probe" ] && [ -d "$out" ] \
  && pass "makes one for the dotfiles in ~/worktrees/dotfiles" || fail "makes one for the dotfiles in ~/worktrees/dotfiles" "$out"
g -C "$box/oldrepo" worktree add -q -b old "$HOME/worktrees/oldrepo/old" 2>/dev/null
if hookrun remove "" "" "$HOME/worktrees/oldrepo/old" >/dev/null 2>&1; then
  fail "refuses to remove a worktree of a repo in Dropbox"
else
  pass "refuses to remove a worktree of a repo in Dropbox"
fi
[ -d "$HOME/worktrees/oldrepo/old" ] && pass "leaves it in place" || fail "leaves it in place"
# FirstMate's projects make no difference, even linking a repo in Dropbox as
# they did before the move.
mkdir -p "$HOME/.local/share/firstmate/projects"
ln -s "$box/oldrepo" "$HOME/.local/share/firstmate/projects/oldrepo"
if hookrun create probe2 "$box/oldrepo" "" >/dev/null 2>&1; then
  fail "refuses a repo in Dropbox that FirstMate's projects link"
else
  pass "refuses a repo in Dropbox that FirstMate's projects link"
fi
out=$(hookrun create probe2 "$HOME/src/agentrepo" "" 2>/dev/null | tail -n 1)
[ "$out" = "$HOME/worktrees/agentrepo/probe2" ] && [ -d "$out" ] \
  && pass "makes one for an agent repo that FirstMate's projects don't link" \
  || fail "makes one for an agent repo that FirstMate's projects don't link" "$out"

section "the main checkout's untracked agent files"
# As on the mini, the global excludes hide them.
cp "$REPO/home/dot_gitignore_global" "$work/gitignore_global"
printf '[core]\n\texcludesfile = %s\n' "$work/gitignore_global" >"$HOME/.gitconfig"
seedrepo="$work/seedrepo"
clone_with_origin "$seedrepo"
for f in CLAUDE.md CLAUDE.local.md AGENTS.md; do printf '%s notes\n' "$f" >"$seedrepo/$f"; done
touch -t 202001020304.05 "$seedrepo/CLAUDE.md" "$seedrepo/CLAUDE.local.md" "$seedrepo/AGENTS.md"
sp=$(hookrun create seeds "$seedrepo" "" 2>/dev/null | tail -n 1)
same=1 stamps=1 want=""
for f in CLAUDE.md CLAUDE.local.md AGENTS.md; do
  cmp -s "$seedrepo/$f" "$sp/$f" || same=0
  { [ "$sp/$f" -nt "$seedrepo/$f" ] || [ "$seedrepo/$f" -nt "$sp/$f" ]; } && stamps=0
  want="$want$(printf '%s\t%s' "$(git hash-object --no-filters "$seedrepo/$f")" "$f")
"
done
[ "$same" = 1 ] && pass "copies the untracked CLAUDE.md, CLAUDE.local.md and AGENTS.md in" \
  || fail "copies the untracked CLAUDE.md, CLAUDE.local.md and AGENTS.md in" "$(ls -A "$sp")"
[ "$stamps" = 1 ] && pass "keeps their timestamps" || fail "keeps their timestamps"
admin=$(git -C "$sp" rev-parse --path-format=absolute --git-dir)
[ "$(cat "$admin/seed-copies" 2>/dev/null)" = "${want%
}" ] && pass "records each copy's hash in the admin dir" \
  || fail "records each copy's hash in the admin dir" "$(cat "$admin/seed-copies" 2>&1)"
[ -z "$(git -C "$sp" status --porcelain)" ] && pass "leaves git status clean" || fail "leaves git status clean"
g -C "$seedrepo" add -f AGENTS.md
g -C "$seedrepo" commit -q -m "track AGENTS.md"
sp2=$(hookrun create seeds2 "$seedrepo" "" 2>/dev/null | tail -n 1)
[ ! -e "$sp2/AGENTS.md" ] && [ -f "$sp2/CLAUDE.md" ] \
  && pass "copies none that the main checkout tracks" || fail "copies none that the main checkout tracks" "$(ls -A "$sp2")"
printf 'a finding\n' >>"$sp/CLAUDE.md"
if hookrun remove "" "" "$sp" >/dev/null 2>&1; then
  fail "refuses to remove a worktree whose copy was edited"
else
  pass "refuses to remove a worktree whose copy was edited"
fi
grep -q 'a finding' "$sp/CLAUDE.md" && pass "keeps the edit" || fail "keeps the edit"
cp -p "$seedrepo/CLAUDE.md" "$sp/CLAUDE.md"
printf 'newer notes\n' >"$seedrepo/CLAUDE.md"
hookrun remove "" "" "$sp" >/dev/null 2>&1 && [ ! -e "$sp" ] \
  && pass "removes one whose copies are unchanged, after the main checkout's file changed" \
  || fail "removes one whose copies are unchanged, after the main checkout's file changed"
printf 'notes of my own\n' >"$sp2/AGENTS.md"
if hookrun remove "" "" "$sp2" >/dev/null 2>&1; then
  fail "refuses to remove a worktree with a new agent file"
else
  pass "refuses to remove a worktree with a new agent file"
fi
rm "$sp2/AGENTS.md"
g -C "$sp2" commit -q --allow-empty -m "seed work"
hookrun remove "" "" "$sp2" >/dev/null 2>&1
sp2=$(hookrun create seeds2 "$seedrepo" "" 2>/dev/null | tail -n 1)
[ "$(git -C "$sp2" log -1 --format=%s 2>/dev/null)" = "seed work" ] && cmp -s "$seedrepo/CLAUDE.md" "$sp2/CLAUDE.md" \
  && pass "one made again from its kept branch gets the copies too" || fail "one made again from its kept branch gets the copies too"

section "untracked files only the global excludes hide"
# git status shows none of these and git worktree remove deletes them all.
mkdir -p "$seedrepo/src"
printf 'src notes\n' >"$seedrepo/src/CLAUDE.md"
for f in db/migrations/0042_add_index.sql src/CLAUDE.md .claude/commands/review.md; do
  hp=$(hookrun create hidden "$seedrepo" "" 2>/dev/null | tail -n 1)
  mkdir -p "$hp/$(dirname "$f")"
  printf 'work of my own\n' >"$hp/$f"
  if [ -n "$(git -C "$hp" status --porcelain)" ]; then
    fail "git status hides $f" "$(git -C "$hp" status --porcelain)"
  elif hookrun remove "" "" "$hp" >/dev/null 2>&1; then
    fail "refuses to remove a worktree holding $f"
  else
    pass "refuses to remove a worktree holding $f"
  fi
  grep -q 'work of my own' "$hp/$f" 2>/dev/null && pass "keeps $f" || fail "keeps $f"
  rm -f "$hp/$f"
  hookrun remove "" "" "$hp" >/dev/null 2>&1
done
hp=$(hookrun create hidden2 "$seedrepo" "" 2>/dev/null | tail -n 1)
mkdir -p "$hp/.claude" "$hp/src"
printf '{}\n' >"$hp/.claude/settings.local.json"
printf 'x' >"$hp/.DS_Store"
printf 'debug\n' >"$hp/debug.log"
cp "$seedrepo/src/CLAUDE.md" "$hp/src/CLAUDE.md"
hookrun remove "" "" "$hp" >/dev/null 2>&1 && [ ! -e "$hp" ] \
  && pass "removes one holding only noise and an unchanged copy of a main checkout file" \
  || fail "removes one holding only noise and an unchanged copy of a main checkout file" "$(ls -A "$hp" 2>&1)"
noise_of() { awk -v v="$2" 'index($0, v "=\047") == 1 { on = 1; sub(/^[^\047]*\047/, "") } on { e = sub(/\047$/, ""); print; if (e) exit }' "$1"; }
hook_noise=$(noise_of "$hook" noise_patterns)
job_noise=$(noise_of "$REPO/home/dot_local/bin/executable_worktree-ttl" NOISE_PATTERNS)
[ -n "$hook_noise" ] && [ "$hook_noise" = "$job_noise" ] \
  && pass "uses the same noise list as worktree-ttl" \
  || fail "uses the same noise list as worktree-ttl" "$(diff <(printf '%s\n' "$hook_noise") <(printf '%s\n' "$job_noise"))"

summary
