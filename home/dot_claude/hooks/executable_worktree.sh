#!/bin/bash
# WorktreeCreate and WorktreeRemove, on the mini only. Claude Code would put
# its worktrees inside the repo, under .claude/worktrees, which for the agents'
# repos is inside their main checkouts in ~/src, and nothing edits those. This
# puts them in ~/worktrees/<repo>/<name> instead, and the dotfiles' in
# ~/worktrees/dotfiles/<name>. They are still worktrees of the repo, so every
# commit made in one lands in that repo's .git.
#
# A repo in Dropbox's repositories folder, the repos' old home, gets none,
# attended or not: nothing on this Mac reads or writes that folder, so no
# worktree of it is made or removed here. Clone it from GitHub into
# ~/worktrees/<repo>/<branch> and work there.
#
#   worktree.sh create   prints the new worktree's path on its last line; the
#                        same name again reopens that worktree. A new one gets
#                        copies of the main checkout's untracked agent files
#   worktree.sh remove   removes a worktree whose removal loses nothing, by
#                        worktree-ttl --check, and its branch if pushed or merged
#
# Reads the hook payload as JSON on stdin; everything but the path goes to stderr.

set -uo pipefail
export GIT_TERMINAL_PROMPT=0

field() {
  printf '%s' "$payload" | /usr/bin/python3 -I -c \
    'import json,sys
try:
    print(json.load(sys.stdin).get(sys.argv[1]) or "")
except Exception:
    print("")' "$1" 2>/dev/null
}
die() { echo "worktree.sh: $1" >&2; exit 1; }
physical() { (cd "$1" 2>/dev/null && pwd -P); }

# The main checkout, even when asked from inside another worktree.
main_repo() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common"
}

# Whose repo the main checkout at $1 is, by guard-git.py's rule: dotfiles for
# this repo's source, dropbox for any repo in Dropbox's repositories folder (or
# a submodule of one), and nothing for the rest, the agents' clones in ~/src
# among them.
owner() {
  local top box
  top=$(physical "$1") || return 0
  [ "$top" = "$(physical "$HOME/.local/share/chezmoi")" ] && { echo dotfiles; return 0; }
  box=$(physical "$HOME/Library/CloudStorage/Dropbox/repositories") || return 0
  case "$top/" in "$box"/*) echo dropbox ;; esac
}

# Whether $2 is one of the worktrees git lists for the repo at $1.
listed() {
  local want line
  main_repo "$2" >/dev/null || return 1
  want=$(physical "$2") || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) [ "$(physical "${line#worktree }")" = "$want" ] && return 0 ;;
    esac
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
  return 1
}

dropbox_repo() {
  die "$(basename "$1") is in Dropbox's repositories folder, the repos' old home, and nothing on this Mac reads or writes that folder, so no worktree of it is made or removed here. Clone it from GitHub into ~/worktrees/$(basename "$1")/<branch> and work there."
}

# A repo's agent files are untracked (the global excludes hide them), so
# they live only in its main checkout and a new worktree gets none. Each
# copy made here is recorded by hash in the worktree's admin dir, in
# seed-copies, which worktree-ttl reads too: an unchanged copy is setup, not
# work, even once the main checkout's file has changed.
agent_files=(CLAUDE.md CLAUDE.local.md AGENTS.md)
seed_list=seed-copies
# Untracked files that never count as work, even where only the global
# excludes hide them. The same list as worktree-ttl's NOISE_PATTERNS, which
# tests/worktree.sh checks: OS litter, compiler output, logs, and Claude
# Code's per-checkout permission file.
noise_patterns='.DS_Store
._*
Thumbs.db
ehthumbs.db
*.o
*.so
*.class
*.dll
*.exe
*.log
/.claude/settings.local.json'

# seed_agent_files <repo> <worktree>: copy them in, keeping their timestamps.
seed_agent_files() {
  local admin f oid
  admin=$(git -C "$2" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 0
  for f in "${agent_files[@]}"; do
    [ -f "$1/$f" ] || continue
    if [ -e "$2/$f" ] || [ -L "$2/$f" ]; then continue; fi
    git -C "$1" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue
    cp -p "$1/$f" "$2/$f" || continue
    oid=$(git -C "$1" hash-object --no-filters -- "$2/$f") || continue
    printf '%s\t%s\n' "$oid" "$f" >>"$admin/$seed_list"
  done
}

# unchanged_copy <repo> <worktree> <file>: whether the worktree's copy still
# matches the main checkout's file, or the copy recorded when it was made.
unchanged_copy() {
  local admin want
  [ -f "$2/$3" ] && [ ! -L "$2/$3" ] || return 1
  [ -f "$1/$3" ] && cmp -s "$2/$3" "$1/$3" && return 0
  admin=$(git -C "$2" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  want=$(awk -F '\t' -v f="$3" '$2 == f { o = $1 } END { print o }' "$admin/$seed_list" 2>/dev/null)
  [ -n "$want" ] && [ "$(git -C "$1" hash-object --no-filters -- "$2/$3" 2>/dev/null)" = "$want" ]
}

payload=$(cat)

case "${1:-}" in
  create)
    name=$(field name)
    cwd=$(field cwd)
    [ -n "$name" ] || die "no worktree name in the payload"
    repo=$(main_repo "${cwd:-$PWD}") || die "${cwd:-$PWD} is not in a Git repo"
    case "$(owner "$repo")" in
      dropbox) dropbox_repo "$repo" ;;
      dotfiles) folder=dotfiles ;;
      *) folder=$(basename "$repo") ;;
    esac
    path="$HOME/worktrees/$folder/$name"
    branch="worktree-$name"

    # The same name again reopens its worktree, as Claude Code's own default
    # does, but only a real worktree of this repo.
    if [ -e "$path" ]; then
      listed "$repo" "$path" || die "$path already exists and isn't a worktree of $repo"
      printf '%s\n' "$path"
      exit 0
    fi

    mkdir -p "$(dirname "$path")" || die "can't create $(dirname "$path")"
    if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
      # A branch kept from an earlier worktree of this name: carry on from it.
      git -C "$repo" worktree add "$path" "$branch" >&2 || die "git worktree add failed"
    else
      # Branch from the remote's default branch, as Claude Code does by default.
      git -C "$repo" fetch --quiet origin >/dev/null 2>&1 || true
      base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || base=HEAD
      # --no-track: the branch is new, so its first plain `git push` creates it
      # on origin and makes that its upstream, rather than pushing to main.
      git -C "$repo" worktree add --no-track -b "$branch" "$path" "$base" >&2 || die "git worktree add failed"
    fi
    seed_agent_files "$repo" "$path" >&2
    printf '%s\n' "$path"
    ;;
  remove)
    path=$(field worktree_path)
    [ -n "$path" ] || die "no worktree path in the payload"
    [ -d "$path" ] || exit 0
    repo=$(main_repo "$path") || die "$path is not a Git worktree"
    [ "$(owner "$repo")" = dropbox ] && dropbox_repo "$repo"
    branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null)
    # git ignores these files, so git worktree remove would delete an edited
    # one without a word. Only an unchanged copy may go with the worktree.
    for f in "${agent_files[@]}"; do
      [ -e "$path/$f" ] || [ -L "$path/$f" ] || continue
      git -C "$path" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue
      unchanged_copy "$repo" "$path" "$f" \
        || die "$path/$f is not an unchanged copy of the main checkout's, and git would delete it with the worktree; copy it out or delete it first"
    done
    # The same holds for every untracked file that only the global excludes
    # or info/exclude hide, such as *.sql, a CLAUDE.md in a subfolder or
    # anything under .claude/. So list untracked files against the repo's
    # own .gitignore files and the noise list alone, as worktree-ttl does.
    lists=$(mktemp -d "${TMPDIR:-/tmp}/worktree-hook.XXXXXX") || die "can't make a temporary folder"
    trap 'rm -rf "$lists"' EXIT
    printf '%s\n' "$noise_patterns" >"$lists/noise"
    (cd "$path" && git ls-files -z --others --exclude-per-directory=.gitignore \
      --exclude-from="$lists/noise") >"$lists/untracked" \
      || die "can't list the untracked files in $path, so it stays"
    while IFS= read -r -d '' f; do
      unchanged_copy "$repo" "$path" "$f" \
        || die "$path/$f is untracked and not an unchanged copy of the main checkout's, and git would delete it with the worktree if only the global excludes hide it; commit it, copy it out or delete it first"
    done <"$lists/untracked"
    # The rest is judged by worktree-ttl's own checks, as its daily sweep
    # judges a worktree before it removes one: commits made in it that only
    # its HEAD, its HEAD reflog or a local tag holds, edits hidden by
    # skip-worktree or assume-unchanged, another repository inside an
    # ignored folder, and a git operation in progress. A rebase's halfway
    # commits, such as a squash's, live on in the tip it ended on, and a tag
    # or a teammate's branch only checked out was made elsewhere, so neither
    # counts. Exit 3 means only the branch or the branch's reflog holds such
    # commits, so the branch stays.
    ttl="$HOME/.local/bin/worktree-ttl"
    [ -f "$ttl" ] || die "can't find $ttl to judge what removing $path would lose, so it stays"
    why=$(/bin/bash "$ttl" --check "$path" 2>&1)
    case $? in
      0) keep_branch="" ;;
      3) keep_branch=$why ;;
      *) die "$path stays: ${why:-worktree-ttl could not judge it}" ;;
    esac
    # Without --force, git refuses a worktree with changes, so nothing unsaved
    # is lost; the worktree stays and Claude Code reports the removal failed.
    git -C "$repo" worktree remove "$path" >&2 || die "$path has changes; commit or discard them first"
    # -d deletes the branch only when it is merged or matches its pushed copy.
    if [ -n "$branch" ] && [ -n "$keep_branch" ]; then
      echo "worktree.sh: kept branch $branch: $keep_branch" >&2
    elif [ -n "$branch" ]; then
      git -C "$repo" branch -d "$branch" >&2 2>/dev/null \
        || echo "worktree.sh: kept branch $branch, which has work not pushed or merged" >&2
    fi
    ;;
  *)
    die "usage: worktree.sh create|remove"
    ;;
esac
exit 0
