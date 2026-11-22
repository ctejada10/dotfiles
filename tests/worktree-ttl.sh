#!/usr/bin/env bash
# The mini's worktree cleanup job, worktree-ttl, in throwaway repos. A fake
# HOME, an isolated git config shaped like this repo's (the same global
# excludes, fetch.prune, fetch.pruneTags, push.autoSetupRemote), local bare
# "GitHub" remotes reached through url.insteadOf, a fake gh that answers from
# those bare repos, a git shim that records every git command the job runs,
# and a logger shim so nothing reaches the system log.
#
# A trash shim stands in for /usr/bin/trash, which would use the real Trash.
#
#   bash tests/worktree-ttl.sh

set -u
# The job and this test use BSD stat and date.
if [ "$(uname)" != Darwin ]; then
  echo "worktree-ttl: the job runs on the mini only; nothing to check here"
  exit 0
fi
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
JOB="$REPO/home/dot_local/bin/executable_worktree-ttl"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/worktree-ttl.XXXXXX")" && pwd -P)"
# Some cases take read permission away; give it back so the sandbox can go.
trap 'chmod -R u+rwx -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
REALGIT=$(command -v git)
mkdir -p "$T/bin" "$T/remote" "$T/tmp"
export HOME="$T/home" TMPDIR="$T/tmp"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
unset GIT_DIR GIT_WORK_TREE CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/worktrees" "$HOME/.Trash"

# This repo's own global excludes, so the job is judged against them.
cp "$REPO/home/dot_gitignore_global" "$T/gitignore_global"
cat >"$GIT_CONFIG_GLOBAL" <<EOF
[user]
    name = Test
    email = test@example.com
[init]
    defaultBranch = main
[core]
    excludesfile = $T/gitignore_global
    fsmonitor = false
[push]
    default = simple
    autoSetupRemote = true
[fetch]
    prune = true
    pruneTags = true
[protocol "file"]
    allow = always
[url "$T/remote/"]
    insteadOf = git@github.com:test/
EOF

cat >"$T/bin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/git-calls.log"
exec "$REALGIT" "\$@"
EOF
cat >"$T/bin/logger" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/logger.log"
EOF
cat >"$T/bin/trash" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/trash-calls.log"
for p in "\$@"; do mv -- "\$p" "$HOME/.Trash/\${p##*/} \$\$" || exit 1; done
EOF
# Fake gh: pr list answers from prs.tsv; api repos/<o>/<r> answers the fork
# parent from parents.tsv; api .../compare/A...B answers from the bare repo,
# and api .../commits/SHA/pulls the PRs in prs.tsv whose head holds SHA, less
# those that only share it as a commit already on main. gh-hook, a script,
# runs once, at the first call after it is written.
cat >"$T/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/gh-calls.log"
if [ -s "$T/gh-hook" ]; then mv "$T/gh-hook" "$T/gh-hook.ran"; bash "$T/gh-hook.ran"; fi
G="$REALGIT"
if [ -e "$T/gh-fail-all" ]; then echo "HTTP 401: Bad credentials" >&2; exit 1; fi
case \$1 in
  pr)
    slug="" head=""
    while [ \$# -gt 0 ]; do
      case \$1 in -R) shift; slug=\$1 ;; --head) shift; head=\$1 ;; esac
      shift
    done
    if grep -Fxq -- "\$head" "$T/gh-fail" 2>/dev/null; then
      echo "error connecting to api.github.com" >&2
      exit 1
    fi
    awk -F '\t' -v s="\$slug" -v h="\$head" '\$1 == s && \$2 == h { print \$3 "\t" \$4 "\t" \$5 "\t" \$6 }' "$T/prs.tsv"
    ;;
  api)
    p=\${2#repos/}
    case \$p in
      */*/compare/*)
        slug=\${p%%/compare/*}; spec=\${p##*/compare/}; a=\${spec%%...*}; b=\${spec#*...}
        repo="$T/remote/\${slug#*/}.git"
        if ! "\$G" --git-dir="\$repo" cat-file -e "\$a^{commit}" 2>/dev/null ||
          ! "\$G" --git-dir="\$repo" cat-file -e "\$b^{commit}" 2>/dev/null; then
          echo '{"message":"Not Found","status":"404"}'
          echo "gh: Not Found (HTTP 404)" >&2
          exit 1
        fi
        if [ "\$a" = "\$b" ]; then echo identical
        elif "\$G" --git-dir="\$repo" merge-base --is-ancestor "\$a" "\$b"; then echo ahead
        elif "\$G" --git-dir="\$repo" merge-base --is-ancestor "\$b" "\$a"; then echo behind
        else echo diverged; fi
        ;;
      */*/commits/*/pulls)
        slug=\${p%%/commits/*}; a=\${p##*/commits/}; a=\${a%/pulls}
        repo="$T/remote/\${slug#*/}.git"
        if [ -s "$T/gh-commit-fail" ]; then cat "$T/gh-commit-fail" >&2; exit 1; fi
        if ! "\$G" --git-dir="\$repo" cat-file -e "\$a^{commit}" 2>/dev/null; then
          echo "gh: No commit found for SHA: \$a (HTTP 422)" >&2
          exit 1
        fi
        onmain=no
        "\$G" --git-dir="\$repo" merge-base --is-ancestor "\$a" main 2>/dev/null && onmain=yes
        while IFS=\$'\t' read -r s h num state oid draft; do
          [ "\$s" = "\$slug" ] || continue
          [ "\$state" = CLOSED ] && continue
          [ "\$onmain" = no ] || [ "\$a" = "\$oid" ] || continue
          "\$G" --git-dir="\$repo" merge-base --is-ancestor "\$a" "\$oid" 2>/dev/null &&
            printf '%s\t%s\t%s\t%s\n' "\$num" "\$state" "\$oid" "\$draft"
        done <"$T/prs.tsv"
        exit 0
        ;;
      */*) awk -F '\t' -v s="\$p" '\$1 == s { print \$2 }' "$T/parents.tsv" ;;
    esac
    ;;
esac
EOF
chmod +x "$T/bin/git" "$T/bin/gh" "$T/bin/logger" "$T/bin/trash"
: >"$T/prs.tsv"
: >"$T/gh-fail"
: >"$T/parents.tsv"

R="$HOME/src"
W="$HOME/worktrees"
mkdir -p "$R"

# --- remotes and main checkouts
for n in r cv sub s t2 fk up hk co rb tr fz uz; do git init -q --bare "$T/remote/$n.git"; done
git clone -q git@github.com:test/r.git "$T/seed" 2>/dev/null
(cd "$T/seed" && echo base >README && git add README && git commit -q -m base && git push -q origin main)
for n in cv s t2 fk up hk co rb tr fz uz; do git -C "$T/seed" push -q "git@github.com:test/$n.git" main; done
(cd "$T" && git clone -q "$T/remote/sub.git" subseed 2>/dev/null && cd subseed &&
  echo s >s && git add s && git commit -q -m s && git push -q origin main) >/dev/null 2>&1
git clone -q git@github.com:test/r.git "$R/r"
git clone -q git@github.com:test/cv.git "$R/curriculum vitae"
git clone -q git@github.com:test/r.git "$R/gl"
git -C "$R/gl" remote set-url origin git@gitlab.example.com:x/gl.git
git init -q "$R/local"
(cd "$R/local" && echo l >l && git add l && git commit -q -m l)
git clone -q git@github.com:test/s.git "$R/s"
git clone -q git@github.com:test/t2.git "$R/t2"
git clone -q git@github.com:test/fk.git "$R/fk"
printf 'test/fk\ttest/up\n' >>"$T/parents.tsv"
git clone -q git@github.com:test/hk.git "$R/hk"
git clone -q git@github.com:test/rb.git "$R/rb"
git clone -q git@github.com:test/rb.git "$T/rbseed"

# --- helpers
hookwt() { # main short-name name [start]: what the WorktreeCreate hook does
  git -C "$1" worktree add -q --no-track -b "worktree-$3" "$W/$2/$3" "${4:-origin/main}" 2>/dev/null
}
work() { (cd "$1" && echo "$2" >"f-$2.txt" && git add . && git commit -q -m "$2"); }
pushwt() { git -C "$1" push -q >/dev/null 2>&1; }
tip() { git -C "$1" rev-parse HEAD; }
pr() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-false}" >>"$T/prs.tsv"; }
stamp_of() { date -r "$1" +%Y%m%d%H%M.%S; }
age_admin() { # admin-dir days
  local old
  old=$(($(date +%s) - $2 * 86400))
  touch -t "$(stamp_of "$old")" "$1/index" "$1/HEAD"
  OLD=$old perl -pi -e 's/> \d+ ([+-]\d{4})(\t|$)/> $ENV{OLD} $1$2/' "$1/logs/HEAD"
}
age() { # worktree days
  local wt=$1 admin
  admin=$(git -C "$wt" rev-parse --path-format=absolute --git-dir)
  find "$wt" -path "$wt/.git" -prune -o -exec touch -h -t "$(stamp_of $(($(date +%s) - $2 * 86400)))" {} +
  age_admin "$admin" "$2"
}
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# ===================== cases carried over from the first design
# A: squash-merged PR, remote branch deleted and pruned, so commits look unpushed
hookwt "$R/r" r merged; work "$W/r/merged" a; pushwt "$W/r/merged"
pr test/r worktree-merged 11 MERGED "$(tip "$W/r/merged")"
git --git-dir="$T/remote/r.git" branch -q -D worktree-merged
git -C "$R/r" fetch -q --prune
age "$W/r/merged" 20
# B: open draft PR
hookwt "$R/r" r open; work "$W/r/open" b; pushwt "$W/r/open"
pr test/r worktree-open 12 OPEN "$(tip "$W/r/open")" true
age "$W/r/open" 40
# C: dirty (untracked file)
hookwt "$R/r" r dirty; work "$W/r/dirty" c; pushwt "$W/r/dirty"
age "$W/r/dirty" 20; echo x >"$W/r/dirty/untracked.txt"
touch -t "$(stamp_of $(($(date +%s) - 20 * 86400)))" "$W/r/dirty/untracked.txt"
# D: unpushed commit, no PR
hookwt "$R/r" r unpushed; work "$W/r/unpushed" d; age "$W/r/unpushed" 20
# E: recent
hookwt "$R/r" r recent; work "$W/r/recent" e; pushwt "$W/r/recent"
# F: pushed, no PR, idle
hookwt "$R/r" r nopr; work "$W/r/nopr" f; pushwt "$W/r/nopr"; age "$W/r/nopr" 20
# G: user pin
hookwt "$R/r" r pinned; age "$W/r/pinned" 30
git -C "$R/r" worktree lock --reason "keep: follow-up on billing" "$W/r/pinned"
# CL: Claude Code style lock
hookwt "$R/r" r cllock; age "$W/r/cllock" 30
git -C "$R/r" worktree lock --reason "claude agent a1b2 (pid 99999 start Sat Oct 24 05:55:26 2026)" "$W/r/cllock"
# H: process cwd inside
hookwt "$R/r" r inuse; age "$W/r/inuse" 20
(cd "$W/r/inuse" && exec sleep 900) &
SLEEPER=$!
# I: live Claude Code session registered with cwd inside (no procStart)
hookwt "$R/r" r session; age "$W/r/session" 20
printf '{"pid":%s,"cwd":"%s","kind":"interactive"}\n' "$$" "$W/r/session" >"$HOME/.claude/sessions/a-$$.json"
# J: detached with a private commit
git -C "$R/r" worktree add -q --detach "$W/r/detpriv" origin/main 2>/dev/null
work "$W/r/detpriv" j; age "$W/r/detpriv" 20
# K: detached, clean, at origin/main
git -C "$R/r" worktree add -q --detach "$W/r/detclean" origin/main 2>/dev/null
age "$W/r/detclean" 20
# L: directory deleted outside git, old entry
hookwt "$R/r" r gone; work "$W/r/gone" l; pushwt "$W/r/gone"; age "$W/r/gone" 20
rm -r -- "$W/r/gone"
# L3: directory and its repo folder deleted (what another machine sees)
git -C "$R/r" worktree add -q --no-track -b worktree-solo "$W/solo/only" origin/main 2>/dev/null
age "$W/solo/only" 20; rm -r -- "$W/solo"
# L2: directory deleted outside git, recent entry
hookwt "$R/r" r gone2; rm -r -- "$W/r/gone2"
# M: PR closed without merging, branch pushed
hookwt "$R/r" r closed; work "$W/r/closed" m; pushwt "$W/r/closed"
pr test/r worktree-closed 13 CLOSED "$(tip "$W/r/closed")"; age "$W/r/closed" 20
# N: PR merged at an older tip, then a new unpushed commit
hookwt "$R/r" r moved; work "$W/r/moved" n1; pushwt "$W/r/moved"
pr test/r worktree-moved 14 MERGED "$(tip "$W/r/moved")"
work "$W/r/moved" n2; age "$W/r/moved" 20
# O: index.lock in the admin dir
hookwt "$R/r" r lk; age "$W/r/lk" 20
touch "$(git -C "$W/r/lk" rev-parse --path-format=absolute --git-dir)/index.lock"
# P: paused rebase state
hookwt "$R/r" r rb; age "$W/r/rb" 20
mkdir "$(git -C "$W/r/rb" rev-parse --path-format=absolute --git-dir)/rebase-merge"
# Q: hand-made worktree, branch with a slash, true-merged into main, no PR
git -C "$R/r" worktree add -q -b feature/slash "$W/r/feature/slash" origin/main 2>/dev/null
work "$W/r/feature/slash" q
git -C "$W/r/feature/slash" push -q origin HEAD:main 2>/dev/null
git -C "$W/r/feature/slash" push -q origin HEAD:feature/slash 2>/dev/null
git -C "$R/r" fetch -q
age "$W/r/feature/slash" 20
# R, S: tool-managed folders, old and clean, must be left alone
git -C "$R/r" worktree add -q -b t3/thing "$HOME/.t3/worktrees/r/t3-thing" origin/main 2>/dev/null
age "$HOME/.t3/worktrees/r/t3-thing" 60
git -C "$R/r" worktree add -q --detach "$HOME/.treehouse/r-pool/slot1" origin/main 2>/dev/null
age "$HOME/.treehouse/r-pool/slot1" 60
# U: gh failure
hookwt "$R/r" r ghfail; work "$W/r/ghfail" u; pushwt "$W/r/ghfail"; age "$W/r/ghfail" 20
echo worktree-ghfail >>"$T/gh-fail"
# V: touched file, no git activity
hookwt "$R/r" r edit; work "$W/r/edit" v; pushwt "$W/r/edit"; age "$W/r/edit" 20
touch "$W/r/edit/f-v.txt"
# W: recent Claude Code transcript in a folder named for the path
hookwt "$R/r" r transcript; work "$W/r/transcript" w; pushwt "$W/r/transcript"; age "$W/r/transcript" 20
mkdir -p "$HOME/.claude/projects/$(enc "$W/r/transcript")"; echo '{}' >"$HOME/.claude/projects/$(enc "$W/r/transcript")/s1.jsonl"
# X: broken gitfile (admin dir gone, as after a git worktree prune while the folder was moved away)
mkdir -p "$W/r/broken"; echo "gitdir: $R/r/.git/worktrees/vanished" >"$W/r/broken/.git"
# X2: gitfile pointing at a folder that is there but is no admin dir
mkdir -p "$W/r/husk" "$T/husk-admin"; echo "gitdir: $T/husk-admin" >"$W/r/husk/.git"
# Y: ignored files present
hookwt "$R/r" r ign
(cd "$W/r/ign" && printf 'node_modules/\n.env\n' >.gitignore && git add .gitignore && git commit -q -m ign)
pushwt "$W/r/ign"; mkdir -p "$W/r/ign/node_modules/x"; echo m >"$W/r/ign/node_modules/x/i.js"; echo SECRET=1 >"$W/r/ign/.env"; age "$W/r/ign" 20
# Z: repo with no remote
git -C "$R/local" worktree add -q --no-track -b worktree-empty "$W/local/empty" main 2>/dev/null
age "$W/local/empty" 20
git -C "$R/local" worktree add -q --no-track -b worktree-work "$W/local/work" main 2>/dev/null
work "$W/local/work" z; age "$W/local/work" 20
# SP: main checkout path with a space, merged PR
hookwt "$R/curriculum vitae" cv merged; work "$W/cv/merged" sp; pushwt "$W/cv/merged"
pr test/cv worktree-merged 3 MERGED "$(tip "$W/cv/merged")"; age "$W/cv/merged" 20
# NG: remote not on github.com; one worktree at origin/main, one with a commit
hookwt "$R/gl" gl idle; age "$W/gl/idle" 20
hookwt "$R/gl" gl wip; work "$W/gl/wip" ng; age "$W/gl/wip" 20
# SM: populated submodule
hookwt "$R/r" r sm
(cd "$W/r/sm" && git submodule -q add "$T/remote/sub.git" sub >/dev/null 2>&1 && git commit -q -m sm)
pushwt "$W/r/sm"; age "$W/r/sm" 20
# FC: a full clone sitting in ~/worktrees
git clone -q git@github.com:test/r.git "$W/r/fullclone" 2>/dev/null
# BD: one day short of the TTL
hookwt "$R/r" r boundary; work "$W/r/boundary" bd; pushwt "$W/r/boundary"; age "$W/r/boundary" 13
# DS: Claude Code session file whose pid is gone does not count as use
hookwt "$R/r" r deadsess; work "$W/r/deadsess" ds; pushwt "$W/r/deadsess"; age "$W/r/deadsess" 20
printf '{"pid":%s,"cwd":"%s"}\n' 99999 "$W/r/deadsess" >"$HOME/.claude/sessions/99999.json"
# RU: head name reused: an old merged PR at this tip plus a new open PR
hookwt "$R/r" r reused; work "$W/r/reused" ru; pushwt "$W/r/reused"
pr test/r worktree-reused 20 MERGED "$(tip "$W/r/reused")"
pr test/r worktree-reused 21 OPEN 0000000000000000000000000000000000000000
age "$W/r/reused" 20
# HM: merged PR head matches an older commit, then a newer commit was pushed
hookwt "$R/r" r after; work "$W/r/after" h1; pushwt "$W/r/after"
pr test/r worktree-after 22 MERGED "$(tip "$W/r/after")"
work "$W/r/after" h2; pushwt "$W/r/after"; age "$W/r/after" 20

# ===================== the skeptic's cases, in repo s
MS="$R/s"
# S1: new files only the global excludes hide (*.sql, AGENTS.md), written now
hookwt "$MS" s sqlwork; work "$W/s/sqlwork" s1; pushwt "$W/s/sqlwork"; age "$W/s/sqlwork" 20
mkdir -p "$W/s/sqlwork/db/migrations"
echo "CREATE INDEX idx ON t(c);" >"$W/s/sqlwork/db/migrations/0042_add_index.sql"
echo "notes for the next agent" >"$W/s/sqlwork/AGENTS.md"
# S1b: the same kind of file, but written 20 days ago
hookwt "$MS" s sqlold; work "$W/s/sqlold" s1b; pushwt "$W/s/sqlold"
echo "CREATE TABLE x (y int);" >"$W/s/sqlold/0001_init.sql"; age "$W/s/sqlold" 20
# S1c: hand-made copies of the main checkout's untracked CLAUDE.md. One
# identical copy is a seed. One taken with cp -p before main's copy changed
# is kept: nothing recorded it, so it may hold an edit.
echo "project notes v1" >"$MS/CLAUDE.md"; echo "local" >"$MS/CLAUDE.local.md"
hookwt "$MS" s seedstale; work "$W/s/seedstale" s1c2; pushwt "$W/s/seedstale"
cp -p "$MS/CLAUDE.md" "$W/s/seedstale/CLAUDE.md"; age "$W/s/seedstale" 20
echo "project notes v2" >"$MS/CLAUDE.md"
touch -t "$(stamp_of $(($(date +%s) - 30 * 86400)))" "$W/s/seedstale/CLAUDE.md"
hookwt "$MS" s seeded; work "$W/s/seeded" s1c; pushwt "$W/s/seeded"
cp -p "$MS/CLAUDE.md" "$W/s/seeded/CLAUDE.md"; cp "$MS/CLAUDE.local.md" "$W/s/seeded/CLAUDE.local.md"
age "$W/s/seeded" 20
# S1d: a seed copy that was edited an hour after the worktree was made
hookwt "$MS" s seededit; work "$W/s/seededit" s1d; pushwt "$W/s/seededit"
cp "$MS/CLAUDE.local.md" "$W/s/seededit/CLAUDE.local.md"; age "$W/s/seededit" 20
echo "hand-off: finish the parser" >>"$W/s/seededit/CLAUDE.local.md"
touch -t "$(stamp_of $(($(date +%s) - 20 * 86400 + 3600)))" "$W/s/seededit/CLAUDE.local.md"
# S1e: a file only info/exclude hides
hookwt "$MS" s infoexcl; work "$W/s/infoexcl" s1e; pushwt "$W/s/infoexcl"
echo "scratch.txt" >>"$MS/.git/info/exclude"
echo "working notes" >"$W/s/infoexcl/scratch.txt"; age "$W/s/infoexcl" 20
# S1f: only noise (.DS_Store, a .log file) besides committed work
hookwt "$MS" s noise; work "$W/s/noise" s1f; pushwt "$W/s/noise"
printf 'x' >"$W/s/noise/.DS_Store"; echo "build ok" >"$W/s/noise/build.log"; age "$W/s/noise" 20
# S2: a nested worktree in .claude/worktrees, which the repo's .gitignore lists
hookwt "$MS" s outer
(cd "$W/s/outer" && echo ".claude/worktrees/" >.gitignore && git add .gitignore && git commit -q -m gi)
pushwt "$W/s/outer"; age "$W/s/outer" 20
git -C "$MS" worktree add -q -b inner-work "$W/s/outer/.claude/worktrees/inner" origin/main 2>/dev/null
echo "half-done refactor" >"$W/s/outer/.claude/worktrees/inner/wip.txt"
# Its files are as old as the outer's, as S2b's are, so the outer is judged
# on what it contains rather than on a recent change below it.
find "$W/s/outer/.claude/worktrees/inner" -name .git -prune -o -exec touch -h -t "$(stamp_of $(($(date +%s) - 20 * 86400)))" {} +
# S2b: a plain clone inside an ignored vendor/ folder
hookwt "$MS" s outer2
(cd "$W/s/outer2" && echo "vendor/" >.gitignore && git add .gitignore && git commit -q -m gi)
pushwt "$W/s/outer2"
git clone -q git@github.com:test/r.git "$W/s/outer2/vendor/lib" 2>/dev/null
echo "patched" >>"$W/s/outer2/vendor/lib/README"; age "$W/s/outer2" 20
# S3: edit hidden with skip-worktree; S3b with assume-unchanged
hookwt "$MS" s skipwt; work "$W/s/skipwt" s3; pushwt "$W/s/skipwt"
echo "local edit that matters" >>"$W/s/skipwt/f-s3.txt"
git -C "$W/s/skipwt" update-index --skip-worktree f-s3.txt; age "$W/s/skipwt" 20
hookwt "$MS" s assume; work "$W/s/assume" s3b; pushwt "$W/s/assume"
echo "local edit that matters" >>"$W/s/assume/f-s3b.txt"
git -C "$W/s/assume" update-index --assume-unchanged f-s3b.txt; age "$W/s/assume" 20
# S3c: skip-worktree on a file that is not on disk (sparse-style), nothing hidden
hookwt "$MS" s sparse; work "$W/s/sparse" s3c; pushwt "$W/s/sparse"
git -C "$W/s/sparse" update-index --skip-worktree f-s3c.txt; rm "$W/s/sparse/f-s3c.txt"; age "$W/s/sparse" 20
# S4: renamed with mv, with a staged file and an unstaged edit
hookwt "$MS" s moved1; work "$W/s/moved1" s4; pushwt "$W/s/moved1"
echo staged >"$W/s/moved1/staged.txt"; git -C "$W/s/moved1" add staged.txt
echo edit >>"$W/s/moved1/f-s4.txt"; age "$W/s/moved1" 20
mv "$W/s/moved1" "$W/s/moved1-renamed"
# S4b: copied with cp -R; the original is otherwise removable
hookwt "$MS" s orig; work "$W/s/orig" s4b; pushwt "$W/s/orig"; age "$W/s/orig" 20
cp -Rp "$W/s/orig" "$W/s/orig-copy"
# S5: pushed under another name, PR open on that name
hookwt "$MS" s rp; work "$W/s/rp" s5; git -C "$W/s/rp" push -q -u origin HEAD:feature/nice-name 2>/dev/null
pr test/s feature/nice-name 31 OPEN "$(tip "$W/s/rp")"; age "$W/s/rp" 20
# S5b: same, PR squash-merged, remote branch deleted, fetch pruned
hookwt "$MS" s rpm; work "$W/s/rpm" s5b; git -C "$W/s/rpm" push -q -u origin HEAD:feature/rpm-nice 2>/dev/null
pr test/s feature/rpm-nice 32 MERGED "$(tip "$W/s/rpm")"
git --git-dir="$T/remote/s.git" branch -q -D feature/rpm-nice
git -C "$MS" fetch -q --prune; age "$W/s/rpm" 20
# S6: GitHub added a commit before the merge; remote branch deleted, pruned
hookwt "$MS" s upd; work "$W/s/upd" s6; pushwt "$W/s/upd"
git clone -q git@github.com:test/s.git "$T/ghui" 2>/dev/null
(cd "$T/ghui" && git checkout -q worktree-upd && echo ui >ui.txt && git add ui.txt && git commit -q -m "Apply suggestion" && git push -q origin worktree-upd)
pr test/s worktree-upd 33 MERGED "$(git -C "$T/ghui" rev-parse HEAD)"
git --git-dir="$T/remote/s.git" branch -q -D worktree-upd
git -C "$MS" fetch -q --prune; age "$W/s/upd" 20
# S9: one tracked file with a far-future mtime
hookwt "$MS" s future; work "$W/s/future" s9; pushwt "$W/s/future"; age "$W/s/future" 20
touch -t 203001010000 "$W/s/future/f-s9.txt"
# S10: detached; its commit is only in its own HEAD reflog
git -C "$MS" worktree add -q --detach "$W/s/detref" origin/main 2>/dev/null
work "$W/s/detref" s10; DETREF=$(tip "$W/s/detref")
git -C "$W/s/detref" checkout -q --detach origin/main; age "$W/s/detref" 20
# S10b: branch worktree whose unpushed commit was reset away
hookwt "$MS" s resetaway; work "$W/s/resetaway" s10b; RESETAWAY=$(tip "$W/s/resetaway")
git -C "$W/s/resetaway" reset -q --hard origin/main; age "$W/s/resetaway" 20
# S10c: detached; commit amended before it was pushed under a branch name
git -C "$MS" worktree add -q --detach "$W/s/amenddet" origin/main 2>/dev/null
work "$W/s/amenddet" s10c; (cd "$W/s/amenddet" && echo more >>f-s10c.txt && git commit -q -a --amend -m s10c)
git -C "$W/s/amenddet" push -q origin HEAD:refs/heads/amenddet 2>/dev/null
git -C "$MS" fetch -q; age "$W/s/amenddet" 20
# S11: detached; its only commit is held by a local tag
git -C "$MS" worktree add -q --detach "$W/s/tagged" origin/main 2>/dev/null
work "$W/s/tagged" s11; git -C "$MS" tag snapshot-s11 "$(tip "$W/s/tagged")"; age "$W/s/tagged" 20
# S13: live session with a matching procStart, and one whose pid was reused
hookwt "$MS" s sessstart; work "$W/s/sessstart" s13; pushwt "$W/s/sessstart"; age "$W/s/sessstart" 20
LSTART=$(TZ=UTC LC_ALL=C ps -o lstart= -p $$ | sed 's/ *$//')
printf '{"pid":%s,"cwd":"%s","procStart":"%s"}\n' "$$" "$W/s/sessstart" "$LSTART" >"$HOME/.claude/sessions/b-$$.json"
hookwt "$MS" s sessreuse; work "$W/s/sessreuse" s13b; pushwt "$W/s/sessreuse"; age "$W/s/sessreuse" 20
printf '{"pid":%s,"cwd":"%s","procStart":"%s"}\n' "$$" "$W/s/sessreuse" "Mon Jan  1 00:00:00 2001" >"$HOME/.claude/sessions/c-$$.json"
# S14: a hook-made worktree's transcript lives under the launch directory
hookwt "$MS" s launchdir; work "$W/s/launchdir" s14; pushwt "$W/s/launchdir"; age "$W/s/launchdir" 20
mkdir -p "$HOME/.claude/projects/$(enc "$MS")"
printf '{"type":"user","cwd":"%s","timestamp":"2026-10-24T00:00:00Z"}\n' "$W/s/launchdir/src" >"$HOME/.claude/projects/$(enc "$MS")/sess.jsonl"
# S7: the job's own rmdir must not switch off clearing for that repo
hookwt "$R/t2" t2 a; work "$W/t2/a" s7; pushwt "$W/t2/a"; age "$W/t2/a" 20
hookwt "$R/t2" t2 b; ADMIN_B=$(git -C "$W/t2/b" rev-parse --path-format=absolute --git-dir); rm -r -- "$W/t2/b"
# S12: fork; origin test/fk is a fork of test/up, PR open on the parent
hookwt "$R/fk" fk forkpr; work "$W/fk/forkpr" s12; pushwt "$W/fk/forkpr"
pr test/up worktree-forkpr 41 OPEN "$(tip "$W/fk/forkpr")"; age "$W/fk/forkpr" 20

# ===================== the WorktreeCreate hook's own copies, in repo hk
MH="$R/hk"
hook() { printf '{"name":"%s","cwd":"%s"}' "$1" "$MH" | bash "$REPO/home/dot_claude/hooks/executable_worktree.sh" create >/dev/null 2>&1; }
created() { head -n 1 "$(git -C "$1" rev-parse --path-format=absolute --git-dir)/logs/HEAD" | cut -f1 | awk '{ print $(NF-1) }'; }
echo "hk notes v1" >"$MH/CLAUDE.md"; echo "hk local" >"$MH/CLAUDE.local.md"
# HK1: the hook's copies, then main's CLAUDE.md changed; they match what the hook recorded
hook hkstale; work "$W/hk/hkstale" hk1; pushwt "$W/hk/hkstale"; age "$W/hk/hkstale" 20
echo "hk notes v2" >"$MH/CLAUDE.md"
# HK2: the hook's copies, identical to main's
hook hksame; work "$W/hk/hksame" hk2; pushwt "$W/hk/hksame"; age "$W/hk/hksame" 20
HK_SEEDED=no
[ -f "$W/hk/hksame/CLAUDE.md" ] && [ -f "$W/hk/hksame/CLAUDE.local.md" ] &&
  [ -s "$MH/.git/worktrees/hksame/seed-copies" ] && HK_SEEDED=yes
# HK3: PR merged, and the agent added to the hook's CLAUDE.md 5 minutes after the worktree was made
hook hkedit; work "$W/hk/hkedit" hk3; pushwt "$W/hk/hkedit"
pr test/hk worktree-hkedit 51 MERGED "$(tip "$W/hk/hkedit")"; age "$W/hk/hkedit" 20
echo "Use --no-cov for a subset run." >>"$W/hk/hkedit/CLAUDE.md"
touch -t "$(stamp_of $(($(created "$W/hk/hkedit") + 300)))" "$W/hk/hkedit/CLAUDE.md"
# HK4: no commits, so its tip is origin/HEAD; CLAUDE.md edited 4 minutes in
hook hknotes; age "$W/hk/hknotes" 20
echo "Use --no-cov for a subset run." >>"$W/hk/hknotes/CLAUDE.md"
touch -t "$(stamp_of $(($(created "$W/hk/hknotes") + 240)))" "$W/hk/hknotes/CLAUDE.md"

# ===================== the second review's cases, in repo rb
MRB="$R/rb"
# A commit on origin's main that clashes with an agent's file of that name,
# or one that clashes with nothing.
clash() {
  (cd "$T/rbseed" && echo theirs >"$1" && git add "$1" && git commit -q -m "clash $1" && git push -q origin main) >/dev/null 2>&1
  git -C "$MRB" fetch -q
}
rebase_abort() { git -C "$1" rebase -q origin/main >/dev/null 2>&1; git -C "$1" rebase --abort; }
detwt() { git -C "$MRB" worktree add -q --detach "$W/rb/$1" origin/main 2>/dev/null; }
brwt() { git -C "$MRB" worktree add -q --no-track -b "worktree-$1" "$W/rb/$1" origin/main 2>/dev/null; }
reachin() { git -C "$1" rev-list --all --reflog 2>/dev/null | grep -c "^$2$"; }
# RB1: detached, two commits on no branch, a rebase that hit a conflict and was aborted
detwt abort; work "$W/rb/abort" rb1a; work "$W/rb/abort" rb1b; clash f-rb1b.txt
rebase_abort "$W/rb/abort"; RB1=$(tip "$W/rb/abort"); age "$W/rb/abort" 20
# RB2: detached, a rebase --exec whose picks were all fast-forwards
detwt execff; work "$W/rb/execff" rb2a; work "$W/rb/execff" rb2b; RB2=$(tip "$W/rb/execff")
git -C "$W/rb/execff" rebase -q --exec true origin/main >/dev/null 2>&1; age "$W/rb/execff" 20
# RB3: as RB1 with one commit, then the folder was deleted
detwt abgone; work "$W/rb/abgone" rb3; RB3=$(tip "$W/rb/abgone"); clash f-rb3.txt
rebase_abort "$W/rb/abgone"; age "$W/rb/abgone" 20; rm -r -- "$W/rb/abgone"
# RB4: a branch whose commit was rebased, aborted and then reset away
brwt abreset; work "$W/rb/abreset" rb4; RB4=$(tip "$W/rb/abreset"); clash f-rb4.txt
rebase_abort "$W/rb/abreset"; git -C "$W/rb/abreset" reset -q --hard origin/main; age "$W/rb/abreset" 20
# RB5: detached; after the aborted rebase the agent checked out origin/main
detwt abaway; work "$W/rb/abaway" rb5; RB5=$(tip "$W/rb/abaway"); clash f-rb5.txt
rebase_abort "$W/rb/abaway"; git -C "$W/rb/abaway" checkout -q --detach origin/main; age "$W/rb/abaway" 20
# RB6: detached; a rebase that rewrote its commit, then pushed under a branch name
detwt rewrote; work "$W/rb/rewrote" rb6; clash bump-rb6.txt
git -C "$W/rb/rewrote" rebase -q origin/main >/dev/null 2>&1
git -C "$W/rb/rewrote" push -q origin HEAD:refs/heads/rewrote 2>/dev/null; git -C "$MRB" fetch -q; age "$W/rb/rewrote" 20
# RB7: a branch whose aborted rebase left a copy of its first commit; pushed, no PR
brwt abpick; work "$W/rb/abpick" rb7a; work "$W/rb/abpick" rb7b; clash f-rb7b.txt
rebase_abort "$W/rb/abpick"; pushwt "$W/rb/abpick"; age "$W/rb/abpick" 20
# RB8: detached; the agent committed at an edit stop, aborted, then left for origin/main
detwt editstop; work "$W/rb/editstop" rb8a; work "$W/rb/editstop" rb8b
(cd "$W/rb/editstop" && GIT_SEQUENCE_EDITOR="sed -i '' '1s/^pick/edit/'" GIT_EDITOR=true git rebase -q -i HEAD~2 >/dev/null 2>&1)
work "$W/rb/editstop" rb8mid; RB8=$(tip "$W/rb/editstop")
git -C "$W/rb/editstop" rebase --abort; git -C "$W/rb/editstop" checkout -q --detach origin/main; age "$W/rb/editstop" 20
# RB9: pushed under another name with no upstream; PR open from that name
brwt othername; work "$W/rb/othername" rb9; git -C "$W/rb/othername" push -q origin HEAD:feature/other-name 2>/dev/null
pr test/rb feature/other-name 71 OPEN "$(tip "$W/rb/othername")"; age "$W/rb/othername" 20
# RB10: PR merged at the branch tip; earlier the agent committed on a detached HEAD and switched back
brwt mexp; work "$W/rb/mexp" rb10; pushwt "$W/rb/mexp"
git -C "$W/rb/mexp" switch -q --detach; work "$W/rb/mexp" rb10x; RB10=$(tip "$W/rb/mexp")
git -C "$W/rb/mexp" switch -q worktree-mexp 2>/dev/null
pr test/rb worktree-mexp 72 MERGED "$(tip "$W/rb/mexp")"; age "$W/rb/mexp" 20
# RB11: detached; its commit is only in its own HEAD reflog, which cannot be read (chmod below)
detwt unread; work "$W/rb/unread" rb11; RB11=$(tip "$W/rb/unread")
git -C "$W/rb/unread" checkout -q --detach origin/main; age "$W/rb/unread" 20
UNREAD_LOG="$(git -C "$W/rb/unread" rev-parse --path-format=absolute --git-dir)/logs/HEAD"
# RB12: a .env and notes the repo's .gitignore hides, edited now in an otherwise idle worktree
brwt ignuse; (cd "$W/rb/ignuse" && printf '.env\nnotes/\n' >.gitignore && git add .gitignore && git commit -q -m ignuse)
pushwt "$W/rb/ignuse"; age "$W/rb/ignuse" 20
mkdir -p "$W/rb/ignuse/notes"; echo "API_KEY=new" >"$W/rb/ignuse/.env"; echo "hand-off" >"$W/rb/ignuse/notes/todo.md"
# RB13: only ignored caches, environments and build output changed now
brwt igncache
(cd "$W/rb/igncache" && printf '.venv/\nnode_modules/\n__pycache__/\n.pytest_cache/\ndist/\n' >.gitignore && git add .gitignore && git commit -q -m igncache)
pushwt "$W/rb/igncache"; age "$W/rb/igncache" 20
for f in .venv/lib/x.py node_modules/p/i.js src/__pycache__/m.pyc .pytest_cache/v dist/app.js; do
  mkdir -p "$(dirname "$W/rb/igncache/$f")"; echo x >"$W/rb/igncache/$f"
done
seq_edit() { (cd "$1" && GIT_SEQUENCE_EDITOR="sed -i '' '$2'" GIT_EDITOR=true git rebase -q -i "$3" >/dev/null 2>&1); }
# RB14: detached; its commit is only in its own HEAD reflog, in a logs folder that cannot be listed (chmod below)
detwt unlist; work "$W/rb/unlist" rb14; RB14=$(tip "$W/rb/unlist")
git -C "$W/rb/unlist" checkout -q --detach origin/main; age "$W/rb/unlist" 20
UNLIST_LOGS="$(git -C "$W/rb/unlist" rev-parse --path-format=absolute --git-dir)/logs"
# RB15: detached; a rebase stopped at a conflict on the last of three commits
# and was quit, the conflict thrown away, and the two it did copy pushed
detwt quit; work "$W/rb/quit" rb15a; work "$W/rb/quit" rb15b; work "$W/rb/quit" rb15c; RB15=$(tip "$W/rb/quit")
clash f-rb15c.txt; git -C "$W/rb/quit" rebase -q origin/main >/dev/null 2>&1; git -C "$W/rb/quit" rebase --quit
git -C "$W/rb/quit" reset -q --hard; git -C "$W/rb/quit" push -q origin HEAD:refs/heads/quit 2>/dev/null
git -C "$MRB" fetch -q; age "$W/rb/quit" 20
# RB16: detached; `rebase -i` dropped the first of two commits, then the rest was pushed
detwt dropped; work "$W/rb/dropped" rb16a; work "$W/rb/dropped" rb16b; RB16=$(git -C "$W/rb/dropped" rev-parse HEAD~1)
seq_edit "$W/rb/dropped" '1s/^pick/drop/' HEAD~2
git -C "$W/rb/dropped" push -q origin HEAD:refs/heads/dropped 2>/dev/null; git -C "$MRB" fetch -q; age "$W/rb/dropped" 20
# RB17: detached; `rebase -i` folded the second commit into the first with fixup, then pushed
detwt fixup; work "$W/rb/fixup" rb17a; work "$W/rb/fixup" rb17b
seq_edit "$W/rb/fixup" '2s/^pick/fixup/' HEAD~2
git -C "$W/rb/fixup" push -q origin HEAD:refs/heads/fixup 2>/dev/null; git -C "$MRB" fetch -q; age "$W/rb/fixup" 20
# RB18: detached; a rebase whose conflict the agent resolved, then pushed
detwt resolved; work "$W/rb/resolved" rb18; clash f-rb18.txt
(cd "$W/rb/resolved" && git rebase -q origin/main >/dev/null 2>&1; echo resolved >f-rb18.txt && git add f-rb18.txt &&
  GIT_EDITOR=true git rebase --continue >/dev/null 2>&1)
git -C "$W/rb/resolved" push -q origin HEAD:refs/heads/resolved 2>/dev/null; git -C "$MRB" fetch -q; age "$W/rb/resolved" 20
# RB19: detached; a commit left behind, then a rebase onto it that copied one
# commit before a conflict and was aborted; the rest was pushed
detwt ontolost; work "$W/rb/ontolost" rb19; RB19=$(tip "$W/rb/ontolost")
git -C "$W/rb/ontolost" checkout -q --detach origin/main
(cd "$W/rb/ontolost" && echo one >one.txt && git add one.txt && git commit -q -m one &&
  echo clash >f-rb19.txt && git add f-rb19.txt && git commit -q -m clashing)
git -C "$W/rb/ontolost" rebase -q "$RB19" >/dev/null 2>&1; git -C "$W/rb/ontolost" rebase --abort
git -C "$W/rb/ontolost" push -q origin HEAD:refs/heads/ontolost 2>/dev/null; git -C "$MRB" fetch -q; age "$W/rb/ontolost" 20
# RB20: otherwise idle, but a folder inside its ignored data/ cannot be read (chmod below, for every run)
brwt ignlocked; (cd "$W/rb/ignlocked" && echo "data/" >.gitignore && git add .gitignore && git commit -q -m ignlocked)
pushwt "$W/rb/ignlocked"; mkdir -p "$W/rb/ignlocked/data/locked"; echo x >"$W/rb/ignlocked/data/locked/f"
age "$W/rb/ignlocked" 20

# ===================== the third review's cases, in repos tr, fz and its parent uz
MTR="$R/tr"
git clone -q git@github.com:test/tr.git "$MTR"
git clone -q git@github.com:test/tr.git "$T/trseed"
# TR1: a commit, then a reset onto a teammate's branch, whose PR was
# squash-merged while the branch stayed on origin
(cd "$T/trseed" && git switch -q -c feat && echo feat >feat.txt && git add feat.txt &&
  git commit -q -m feat && git push -q origin feat) >/dev/null 2>&1
pr test/tr feat 90 MERGED "$(git -C "$T/trseed" rev-parse HEAD)"
git -C "$MTR" fetch -q
hookwt "$MTR" tr teamreset; work "$W/tr/teamreset" tr1; TR1=$(tip "$W/tr/teamreset")
git -C "$W/tr/teamreset" reset -q --hard origin/feat; age "$W/tr/teamreset" 20
# TR2: pushed under another name by its push ref (a pushRemote with a push
# refspec, so no upstream), and that PR merged at the tip
hookwt "$MTR" tr pushref; work "$W/tr/pushref" tr2
git -C "$MTR" config remote.mapped.url git@github.com:test/tr.git
git -C "$MTR" config remote.mapped.fetch '+refs/heads/*:refs/remotes/mapped/*'
git -C "$MTR" config remote.mapped.push refs/heads/worktree-pushref:refs/heads/agent/pushref
git -C "$MTR" config branch.worktree-pushref.pushRemote mapped
git -C "$W/tr/pushref" push -q 2>/dev/null
pr test/tr agent/pushref 91 MERGED "$(tip "$W/tr/pushref")"; age "$W/tr/pushref" 20
# TR3: pushed under another name with no upstream, as RB9, but that name's
# PR merged while the branch stayed on origin: it landed, and its branch stays
hookwt "$MTR" tr pushedmerged; work "$W/tr/pushedmerged" tr3
git -C "$W/tr/pushedmerged" push -q origin HEAD:feature/tr3-name 2>/dev/null
pr test/tr feature/tr3-name 92 MERGED "$(tip "$W/tr/pushedmerged")"; age "$W/tr/pushedmerged" 20
# FZ1: fork test/fz of test/uz, with uz as remote upstream. Its PR to uz
# merged with a merge commit, so upstream/main holds the tip, while someone
# else's PR from their fork's main is open on uz.
MFZ="$R/fz"
git clone -q git@github.com:test/fz.git "$MFZ"
git -C "$MFZ" remote add upstream git@github.com:test/uz.git
printf 'test/fz\ttest/uz\n' >>"$T/parents.tsv"
hookwt "$MFZ" fz merged; work "$W/fz/merged" fz1; pushwt "$W/fz/merged"
pr test/uz worktree-merged 7 MERGED "$(tip "$W/fz/merged")"
git clone -q git@github.com:test/uz.git "$T/uzseed" 2>/dev/null
(cd "$T/uzseed" && git fetch -q git@github.com:test/fz.git worktree-merged &&
  git merge -q --no-ff -m "Merge pull request #7" FETCH_HEAD && git push -q origin main) >/dev/null 2>&1
pr test/uz main 8 OPEN "$(git -C "$T/uzseed" rev-parse HEAD)"
git -C "$MFZ" fetch -q upstream; age "$W/fz/merged" 20

# ===================== the fourth review's cases, in repo rb
# Removal loses nothing when the HEAD reflog alone holds commits a rebase
# folded into its tip, or commits HEAD only checked out. It would lose a
# rebase's tip that nothing else holds, a commit made on a tag looked at,
# and a dropped stash that was checked out.
autosquash() { (cd "$1" && GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true git rebase -q -i --autosquash origin/main >/dev/null 2>&1); }
fix() { (cd "$1" && echo fix >>"f-$2.txt" && git commit -q -a --fixup "$3"); }
# RB21: two commits squashed onto a moved main, pushed, PR merged at that tip
brwt sqmerged; work "$W/rb/sqmerged" rb21a; work "$W/rb/sqmerged" rb21b; clash bump-rb21.txt
seq_edit "$W/rb/sqmerged" '2s/^pick/squash/' origin/main; pushwt "$W/rb/sqmerged"
pr test/rb worktree-sqmerged 73 MERGED "$(tip "$W/rb/sqmerged")"; age "$W/rb/sqmerged" 20
# RB22: two commits that each took a fixup, folded in place, pushed, no PR
brwt fixups; work "$W/rb/fixups" rb22a; work "$W/rb/fixups" rb22b
fix "$W/rb/fixups" rb22a HEAD~1; fix "$W/rb/fixups" rb22b HEAD~1
autosquash "$W/rb/fixups"; pushwt "$W/rb/fixups"; age "$W/rb/fixups" 20
# RB23: detached; a commit reworded onto a moved main, pushed under a branch name
detwt reword; work "$W/rb/reword" rb23; clash bump-rb23.txt
(cd "$W/rb/reword" && GIT_SEQUENCE_EDITOR="sed -i '' '1s/^pick/reword/'" GIT_EDITOR="sed -i '' '1s/.*/rb23 reworded/'" \
  git rebase -q -i origin/main >/dev/null 2>&1)
git -C "$W/rb/reword" push -q origin HEAD:refs/heads/reword 2>/dev/null; git -C "$MRB" fetch -q; age "$W/rb/reword" 20
# RB24: two fixups folded on a branch the agent then deleted, so only the
# HEAD reflog holds the tip and its halfway commit
brwt sqlost; git -C "$W/rb/sqlost" switch -q -c scratch-rb24; work "$W/rb/sqlost" rb24
fix "$W/rb/sqlost" rb24 HEAD; fix "$W/rb/sqlost" rb24 HEAD~1; autosquash "$W/rb/sqlost"; RB24=$(tip "$W/rb/sqlost")
RB24MID=$(git -C "$W/rb/sqlost" log -g --format='%H %gs' | awk '/This is a combination/ { print $1; exit }')
git -C "$W/rb/sqlost" switch -q worktree-sqlost; git -C "$MRB" branch -q -D scratch-rb24; age "$W/rb/sqlost" 20
# A release commit on no branch, tagged and pushed by a teammate
(cd "$T/rbseed" && git switch -q --detach && echo release >rel-rb.txt && git add rel-rb.txt &&
  git commit -q -m release && git tag v-rb && git push -q origin v-rb && git switch -q main) >/dev/null 2>&1
git -C "$MRB" fetch -q --tags
# RB25: pushed; a look at that tag on a detached HEAD, then back to the branch
brwt look; work "$W/rb/look" rb25; pushwt "$W/rb/look"
git -C "$W/rb/look" switch -q --detach v-rb; git -C "$W/rb/look" switch -q worktree-look; age "$W/rb/look" 20
# RB26: detached and left on that tag
detwt attag; git -C "$W/rb/attag" switch -q --detach v-rb; age "$W/rb/attag" 20
# RB27: detached; a commit made on that tag, then left for origin/main
detwt ontag; git -C "$W/rb/ontag" switch -q --detach v-rb; work "$W/rb/ontag" rb27; RB27=$(tip "$W/rb/ontag")
git -C "$W/rb/ontag" checkout -q --detach origin/main; age "$W/rb/ontag" 20
# RB28: pushed; a stash checked out, then the branch again, then the stash dropped
brwt stashed; work "$W/rb/stashed" rb28; pushwt "$W/rb/stashed"
echo "work in a stash" >>"$W/rb/stashed/f-rb28.txt"; git -C "$W/rb/stashed" stash -q
RB28=$(git -C "$W/rb/stashed" rev-parse 'stash@{0}')
git -C "$W/rb/stashed" checkout -q 'stash@{0}'; git -C "$W/rb/stashed" switch -q worktree-stashed
git -C "$W/rb/stashed" stash drop -q; age "$W/rb/stashed" 20

# ===================== full clones of another repo in ~/worktrees, from test/co
clone() { git clone -q git@github.com:test/co.git "$W/co/$1" 2>/dev/null && git -C "$W/co/$1" switch -q -c "$1"; }
# CO1: PR merged at this tip, remote branch deleted and pruned
clone merged; work "$W/co/merged" co1; pushwt "$W/co/merged"
pr test/co merged 61 MERGED "$(tip "$W/co/merged")"
git --git-dir="$T/remote/co.git" branch -q -D merged; git -C "$W/co/merged" fetch -q --prune
age "$W/co/merged" 20
# CO2: draft PR open, idle 40 days
clone openpr; work "$W/co/openpr" co2; pushwt "$W/co/openpr"
pr test/co openpr 62 OPEN "$(tip "$W/co/openpr")" true; age "$W/co/openpr" 40
# CO3: an uncommitted edit
clone dirty; work "$W/co/dirty" co3; pushwt "$W/co/dirty"; echo more >>"$W/co/dirty/README"; age "$W/co/dirty" 20
# CO4: a commit never pushed, no PR
clone unpushed; work "$W/co/unpushed" co4; age "$W/co/unpushed" 20
# CO5: a stash
clone stashed; work "$W/co/stashed" co5; pushwt "$W/co/stashed"
echo wip >>"$W/co/stashed/README"; git -C "$W/co/stashed" stash -q; age "$W/co/stashed" 20
# CO6: a CLAUDE.md that only the global excludes hide
clone notes; work "$W/co/notes" co6; pushwt "$W/co/notes"; echo notes >"$W/co/notes/CLAUDE.md"; age "$W/co/notes" 20
# CO7: a worktree of its own, outside the sweep folder
clone ownwt; work "$W/co/ownwt" co7; pushwt "$W/co/ownwt"
git -C "$W/co/ownwt" worktree add -q -b side "$T/ownwt-side" 2>/dev/null; age "$W/co/ownwt" 20
# CO8: pushed, no PR
clone pushed; work "$W/co/pushed" co8; pushwt "$W/co/pushed"; age "$W/co/pushed" 20
# CO9: made just now, with an untracked note: kept, and not flagged
clone fresh; echo wip >"$W/co/fresh/notes.txt"
# CO10: a commit reset away, so only the reflog holds it
clone resetaway; work "$W/co/resetaway" co10; git -C "$W/co/resetaway" reset -q --hard origin/main
age "$W/co/resetaway" 20
# CO11: detached at a commit no remote has
clone detached; git -C "$W/co/detached" switch -q --detach; work "$W/co/detached" co11; age "$W/co/detached" 20
# CO12: PR merged, plus a commit only the reflog holds
clone mergedrl; work "$W/co/mergedrl" co12a; git -C "$W/co/mergedrl" reset -q --hard HEAD~1
work "$W/co/mergedrl" co12b; pushwt "$W/co/mergedrl"
pr test/co mergedrl 63 MERGED "$(tip "$W/co/mergedrl")"; age "$W/co/mergedrl" 20
# CO13: no remote left
clone norem; work "$W/co/norem" co13; git -C "$W/co/norem" remote remove origin; age "$W/co/norem" 20
# CO15: branch twobr merged; branch twobr-b pushed with no PR, plus a commit reset away on it
clone twobr; work "$W/co/twobr" co15a; pushwt "$W/co/twobr"; pr test/co twobr 64 MERGED "$(tip "$W/co/twobr")"
git -C "$W/co/twobr" switch -q --no-track -c twobr-b origin/main; work "$W/co/twobr" co15b; pushwt "$W/co/twobr"
work "$W/co/twobr" co15x; CO15=$(tip "$W/co/twobr"); git -C "$W/co/twobr" reset -q --hard HEAD~1; age "$W/co/twobr" 20
# CO16: pushed under another name with no upstream; a draft PR open from that name
clone otherpush; work "$W/co/otherpush" co16; git -C "$W/co/otherpush" push -q origin HEAD:fix-login 2>/dev/null
pr test/co fix-login 65 OPEN "$(tip "$W/co/otherpush")" true; age "$W/co/otherpush" 20
# CO17: a commit only the reflogs hold, in a clone whose logs folder cannot be read (chmod below)
clone unreadrl; work "$W/co/unreadrl" co17; pushwt "$W/co/unreadrl"; work "$W/co/unreadrl" co17x
git -C "$W/co/unreadrl" reset -q --hard HEAD~1; age "$W/co/unreadrl" 20
# CO18: as TR1 in a clone: a commit, then a reset onto a teammate's branch whose PR merged
git clone -q git@github.com:test/co.git "$T/coteam" 2>/dev/null
(cd "$T/coteam" && git switch -q -c teamfeat && echo t >t.txt && git add t.txt &&
  git commit -q -m teamfeat && git push -q origin teamfeat) >/dev/null 2>&1
pr test/co teamfeat 66 MERGED "$(git -C "$T/coteam" rev-parse HEAD)"
clone teamreset; work "$W/co/teamreset" co18; CO18=$(tip "$W/co/teamreset")
git -C "$W/co/teamreset" reset -q --hard origin/teamfeat; age "$W/co/teamreset" 20
# CO14: a commit only the reflogs hold, after an aborted rebase and a reset.
# Last, since it moves test/co's main.
clone abortrl; work "$W/co/abortrl" co14; CO14=$(tip "$W/co/abortrl")
git clone -q git@github.com:test/co.git "$T/coseed" 2>/dev/null
(cd "$T/coseed" && echo theirs >f-co14.txt && git add f-co14.txt && git commit -q -m clash && git push -q origin main) >/dev/null 2>&1
git -C "$W/co/abortrl" fetch -q; rebase_abort "$W/co/abortrl"
git -C "$W/co/abortrl" reset -q --hard origin/main; age "$W/co/abortrl" 20
# Reflogs that cannot be read, as a file with no read permission
chmod 000 "$UNREAD_LOG" "$W/co/unreadrl/.git/logs" "$UNLIST_LOGS"
IGNLOCKED="$W/rb/ignlocked/data/locked"; chmod 000 "$IGNLOCKED"

ADMIN_OPEN=$(git -C "$W/r/open" rev-parse --path-format=absolute --git-dir)
IDX_BEFORE=$(stat -f %m "$ADMIN_OPEN/index")
reach() { git -C "$MS" rev-list --all --reflog 2>/dev/null | grep -c "^$1$"; }

snapshot() {
  {
    for m in "$R/r" "$R/curriculum vitae" "$R/local" "$R/gl" "$R/s" "$R/t2" "$R/fk" "$R/hk" "$R/rb" "$R/tr" "$R/fz" "$W"/co/*; do
      git -C "$m" worktree list --porcelain
      git -C "$m" for-each-ref --format='%(refname) %(objectname)'
      git -C "$m" config --get-regexp '^branch\.' || true
      find "$m/.git/worktrees" "$m/.git/logs" -type f 2>/dev/null | sort
    done
    find "$HOME/worktrees" "$HOME/.t3" "$HOME/.treehouse" "$HOME/.Trash" -maxdepth 5 | sort
  } 2>/dev/null
}

GITBIN=$(dirname "$REALGIT")
export WORKTREE_TTL_PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin:$GITBIN"
export WORKTREE_TTL_GIT="$T/bin/git" WORKTREE_TTL_GH="$T/bin/gh" WORKTREE_TTL_TRASH="$T/bin/trash"
ATT="$HOME/Library/Logs/worktree-ttl/attention.txt"

PASS=0 FAILS=0
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; }
expect() { # file action path-suffix reason-substring
  local pat
  pat=$(printf '%-7s %s' "$2" "$HOME/$3 |")
  if grep -F -- "$pat" "$1" | grep -Fq -- "$4"; then ok "$2 $3 ($4)"; else bad "$2 $3 ($4)"; grep -F -- "$HOME/$3 |" "$1" | sed 's/^/      got: /'; fi
}
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== dry run"
snapshot >"$T/snap0"
/bin/bash "$JOB" --dry-run >"$T/dry.out" 2>"$T/dry.err"
snapshot >"$T/snap1"
if cmp -s "$T/snap0" "$T/snap1"; then ok "dry run changed nothing"; else bad "dry run changed state"; diff "$T/snap0" "$T/snap1" | head -20; fi
expect "$T/dry.out" WOULD worktrees/r/merged "PR test/r#11 merged at this exact tip"
expect "$T/dry.out" WOULD worktrees/r/merged "would delete branch"
expect "$T/dry.out" WOULD worktrees/co/merged "would move it to the Trash"
chk "dry run moved nothing to the Trash" "[ ! -e '$T/trash-calls.log' ]"
/bin/bash "$JOB" --dry-run --keep-missing >"$T/dry2.out" 2>&1
expect "$T/dry2.out" KEEP worktrees/r/gone "entry kept (--keep-missing)"

echo "== real run"
/bin/bash "$JOB" >"$T/run1.out" 2>"$T/run1.err"
echo "exit $?" >>"$T/run1.out"
chmod 644 "$UNREAD_LOG"; chmod 755 "$W/co/unreadrl/.git/logs" "$UNLIST_LOGS"
O="$T/run1.out"
echo "-- first design's cases"
expect "$O" REMOVED worktrees/r/merged "PR test/r#11 merged at this exact tip"
expect "$O" REMOVED worktrees/r/merged "branch deleted (PR test/r#11 merged)"
expect "$O" KEEP worktrees/r/open "PR test/r#12 (draft) open"
expect "$O" KEEP worktrees/r/dirty "uncommitted or untracked changes"
expect "$O" KEEP worktrees/r/unpushed "1 commit(s) not on any remote"
expect "$O" KEEP worktrees/r/recent "used 0d ago"
expect "$O" REMOVED worktrees/r/nopr "every commit is on a remote"
expect "$O" REMOVED worktrees/r/nopr "branch kept"
expect "$O" KEEP worktrees/r/pinned "locked: keep: follow-up on billing"
expect "$O" KEEP worktrees/r/cllock "locked: claude agent a1b2"
expect "$O" KEEP worktrees/r/inuse "in use"
expect "$O" KEEP worktrees/r/session "in use"
expect "$O" KEEP worktrees/r/detpriv "detached HEAD with 1 commit(s) on no branch or remote"
expect "$O" REMOVED worktrees/r/detclean "detached HEAD, every commit is on a branch or remote"
expect "$O" REMOVED worktrees/r/gone "stale entry cleared"
expect "$O" KEEP worktrees/r/gone2 "directory missing, entry used 0d ago"
expect "$O" KEEP worktrees/solo/only "and so is"
expect "$O" REMOVED worktrees/r/closed "PR test/r#13 closed unmerged"
expect "$O" KEEP worktrees/r/moved "1 commit(s) not on any remote and no merged PR contains this tip"
expect "$O" KEEP worktrees/r/lk "git lock file present (index.lock)"
expect "$O" KEEP worktrees/r/rb "operation in progress (rebase-merge)"
expect "$O" REMOVED worktrees/r/feature/slash "tip already in refs/remotes/origin/HEAD"
expect "$O" REMOVED worktrees/r/feature/slash "branch deleted"
expect "$O" KEEP worktrees/r/ghfail "PR state unknown (error connecting"
expect "$O" KEEP worktrees/r/edit "file edit"
expect "$O" KEEP worktrees/r/transcript "Claude Code transcript"
expect "$O" KEEP worktrees/r/broken "broken: .git points to"
expect "$O" KEEP worktrees/r/husk "broken: .git points to $T/husk-admin"
expect "$O" REMOVED worktrees/r/ign "ignored files deleted with it: .env node_modules/"
expect "$O" REMOVED worktrees/local/empty "every commit is on another branch or tag (repo has no remote)"
expect "$O" KEEP worktrees/local/work "only on this branch (repo has no remote)"
expect "$O" REMOVED "worktrees/cv/merged" "PR test/cv#3 merged"
expect "$O" REMOVED worktrees/gl/idle "tip already in refs/remotes/origin/HEAD"
expect "$O" REMOVED worktrees/gl/idle "branch deleted"
expect "$O" KEEP worktrees/gl/wip "not on github.com"
expect "$O" KEEP worktrees/r/sm "submodule"
expect "$O" KEEP worktrees/r/fullclone "clone, used 0d ago"
expect "$O" KEEP worktrees/r/boundary "reaches the 14d TTL within a day"
expect "$O" REMOVED worktrees/r/deadsess "every commit is on a remote"
expect "$O" KEEP worktrees/r/reused "PR test/r#21 open"
expect "$O" REMOVED worktrees/r/after "every commit is on a remote"
expect "$O" REMOVED worktrees/r/after "branch kept"
echo "-- skeptic's cases"
expect "$O" KEEP worktrees/s/sqlwork "used 0d ago (file edit)"
expect "$O" KEEP worktrees/s/sqlold "only the global excludes or info/exclude hide (0001_init.sql)"
expect "$O" REMOVED worktrees/s/seeded "every commit is on a remote"
expect "$O" KEEP worktrees/s/seedstale "only the global excludes or info/exclude hide (CLAUDE.md)"
expect "$O" KEEP worktrees/s/seededit "only the global excludes or info/exclude hide (CLAUDE.local.md)"
expect "$O" KEEP worktrees/s/infoexcl "only the global excludes or info/exclude hide (scratch.txt)"
expect "$O" REMOVED worktrees/s/noise "every commit is on a remote"
expect "$O" KEEP worktrees/s/outer "contains another repository or worktree ($W/s/outer/.claude/worktrees/inner)"
expect "$O" KEEP worktrees/s/outer/.claude/worktrees/inner "used 0d ago"
expect "$O" KEEP worktrees/s/outer2 "contains another repository or worktree ($W/s/outer2/vendor/lib)"
expect "$O" KEEP worktrees/s/skipwt "edit hidden by skip-worktree or assume-unchanged (f-s3.txt)"
expect "$O" KEEP worktrees/s/assume "edit hidden by skip-worktree or assume-unchanged (f-s3b.txt)"
expect "$O" REMOVED worktrees/s/sparse "every commit is on a remote"
expect "$O" KEEP worktrees/s/moved1 "points at this entry (moved?)"
expect "$O" KEEP worktrees/s/moved1-renamed "moved here from $W/s/moved1"
expect "$O" KEEP worktrees/s/orig "also points at this worktree's admin dir"
expect "$O" KEEP worktrees/s/orig-copy "shares the admin dir of $W/s/orig"
expect "$O" KEEP worktrees/s/rp "PR test/s#31 open"
expect "$O" REMOVED worktrees/s/rpm "PR test/s#32 merged at this exact tip"
expect "$O" REMOVED worktrees/s/rpm "branch deleted"
expect "$O" REMOVED worktrees/s/upd "PR test/s#33 merged, and its head contains this tip"
expect "$O" REMOVED worktrees/s/upd "branch deleted"
expect "$O" REMOVED worktrees/s/future "1 file(s) dated in the future, ignored"
expect "$O" KEEP worktrees/s/detref "detached HEAD with 1 commit(s) on no branch or remote"
expect "$O" REMOVED worktrees/s/resetaway "branch kept: its reflog holds 1 commit(s) found nowhere else"
expect "$O" REMOVED worktrees/s/amenddet "detached HEAD, every commit is on a branch or remote"
expect "$O" KEEP worktrees/s/tagged "detached HEAD with 1 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/s/sessstart "in use"
expect "$O" REMOVED worktrees/s/sessreuse "every commit is on a remote"
expect "$O" KEEP worktrees/s/launchdir "Claude Code transcript"
expect "$O" REMOVED worktrees/t2/a "every commit is on a remote"
expect "$O" KEEP worktrees/t2/b "directory missing, entry used 0d ago"
expect "$O" KEEP worktrees/fk/forkpr "PR test/up#41 open"
echo "-- the hook's copies"
expect "$O" REMOVED worktrees/hk/hkstale "every commit is on a remote"
expect "$O" REMOVED worktrees/hk/hksame "every commit is on a remote"
expect "$O" KEEP worktrees/hk/hkedit "only the global excludes or info/exclude hide (CLAUDE.md)"
expect "$O" KEEP worktrees/hk/hknotes "only the global excludes or info/exclude hide (CLAUDE.md)"
echo "-- full clones"
expect "$O" REMOVED worktrees/co/merged "clone, PR test/co#61 merged, and every other local branch is on a remote"
expect "$O" REMOVED worktrees/co/merged "moved to the Trash"
expect "$O" KEEP worktrees/co/openpr "clone, PR test/co#62 (draft) open"
expect "$O" KEEP worktrees/co/dirty "uncommitted or untracked changes"
expect "$O" KEEP worktrees/co/unpushed "1 commit(s) on branch unpushed not on any remote"
expect "$O" KEEP worktrees/co/stashed "has refs/stash"
expect "$O" KEEP worktrees/co/notes "only the global excludes or info/exclude hide (CLAUDE.md)"
expect "$O" KEEP worktrees/co/ownwt "it has worktrees of its own"
expect "$O" REMOVED worktrees/co/pushed "clone, every local branch is on a remote"
expect "$O" KEEP worktrees/co/fresh "clone, used 0d ago"
expect "$O" KEEP worktrees/co/resetaway "its reflogs hold 1 commit(s) on no remote"
expect "$O" KEEP worktrees/co/detached "detached HEAD with 1 commit(s) on no remote"
expect "$O" REMOVED worktrees/co/mergedrl "reflog-only commits dropped with it: 1"
expect "$O" KEEP worktrees/co/norem "no remote"
expect "$O" KEEP worktrees/co/twobr "its reflogs hold 1 commit(s) on no remote"
expect "$O" KEEP worktrees/co/otherpush "clone, PR test/co#65 (draft) open"
expect "$O" KEEP worktrees/co/unreadrl "could not read its reflogs"
expect "$O" KEEP worktrees/co/abortrl "its reflogs hold 1 commit(s) on no remote"
echo "-- the second review's cases"
expect "$O" KEEP worktrees/rb/abort "detached HEAD with 2 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/rb/execff "detached HEAD with 2 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/rb/abgone "directory missing, HEAD reflog holds 1 commit(s) on no branch or remote"
expect "$O" REMOVED worktrees/rb/abreset "branch kept: its reflog holds 1 commit(s) found nowhere else"
expect "$O" KEEP worktrees/rb/abaway "detached HEAD with 1 commit(s) on no branch or remote"
expect "$O" REMOVED worktrees/rb/rewrote "detached HEAD, every commit is on a branch or remote"
expect "$O" REMOVED worktrees/rb/abpick "every commit is on a remote"
expect "$O" KEEP worktrees/rb/editstop "detached HEAD with 3 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/rb/othername "PR test/rb#71 open"
expect "$O" KEEP worktrees/rb/mexp "its HEAD reflog holds 1 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/rb/unread "detached HEAD, and its reflog could not be read"
expect "$O" KEEP worktrees/rb/ignuse "used 0d ago (ignored file edit)"
expect "$O" REMOVED worktrees/rb/igncache "every commit is on a remote"
expect "$O" KEEP worktrees/rb/unlist "detached HEAD, and its reflog could not be read"
expect "$O" KEEP worktrees/rb/quit "detached HEAD with 3 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/rb/dropped "detached HEAD with 2 commit(s) on no branch or remote"
expect "$O" REMOVED worktrees/rb/fixup "detached HEAD, every commit is on a branch or remote"
expect "$O" REMOVED worktrees/rb/resolved "detached HEAD, every commit is on a branch or remote"
expect "$O" KEEP worktrees/rb/ontolost "detached HEAD with 1 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/rb/ignlocked "could not read all of data/locked/, so its last use is unknown (idle 20d otherwise)"
echo "-- the third review's cases"
expect "$O" REMOVED worktrees/tr/teamreset "PR test/tr#90 merged under another branch's name"
expect "$O" REMOVED worktrees/tr/teamreset "branch kept"
expect "$O" REMOVED worktrees/tr/pushref "PR test/tr#91 merged at this exact tip"
expect "$O" REMOVED worktrees/tr/pushref "branch deleted (PR test/tr#91 merged)"
expect "$O" REMOVED worktrees/tr/pushedmerged "PR test/tr#92 merged under another branch's name"
expect "$O" REMOVED worktrees/tr/pushedmerged "branch kept"
expect "$O" REMOVED worktrees/fz/merged "PR test/uz#7 merged at this exact tip"
expect "$O" REMOVED worktrees/fz/merged "branch deleted (PR test/uz#7 merged)"
expect "$O" KEEP worktrees/co/teamreset "its reflogs hold 1 commit(s) on no remote"
echo "-- the fourth review's cases"
expect "$O" REMOVED worktrees/rb/sqmerged "PR test/rb#73 merged at this exact tip"
expect "$O" REMOVED worktrees/rb/sqmerged "branch deleted (PR test/rb#73 merged)"
expect "$O" REMOVED worktrees/rb/fixups "every commit is on a remote"
expect "$O" REMOVED worktrees/rb/reword "detached HEAD, every commit is on a branch or remote"
expect "$O" KEEP worktrees/rb/sqlost "its HEAD reflog holds 1 commit(s) on no branch or remote (${RB24:0:10})"
expect "$O" REMOVED worktrees/rb/look "every commit is on a remote"
expect "$O" REMOVED worktrees/rb/attag "detached HEAD, every commit is on a branch or remote"
expect "$O" KEEP worktrees/rb/ontag "detached HEAD with 2 commit(s) on no branch or remote"
expect "$O" KEEP worktrees/rb/stashed "its HEAD reflog holds 2 commit(s) on no branch or remote"
if grep -Fq "LEFT    $HOME/.t3/worktrees | 1 worktree(s) left to T3 Code" "$O"; then ok "T3 folder left to T3"; else bad "T3 folder count"; fi
if grep -Fq "LEFT    $HOME/.treehouse | 1 worktree(s) left to treehouse" "$O"; then ok "treehouse folder left to treehouse"; else bad "treehouse folder count"; fi
if grep -q "^exit 0$" "$O"; then ok "exit status 0"; else bad "exit status nonzero"; grep -E 'FAILED' "$O" | sed 's/^/      /'; fi
if [ -s "$T/run1.err" ]; then bad "stderr not empty"; sed 's/^/      /' "$T/run1.err"; else ok "stderr empty"; fi

echo "== state after the run"
chk "merged worktree dir gone" "[ ! -e '$W/r/merged' ]"
chk "merged branch deleted" "! git -C '$R/r' rev-parse -q --verify refs/heads/worktree-merged >/dev/null"
chk "merged branch config section gone" "! git -C '$R/r' config --get branch.worktree-merged.remote >/dev/null"
chk "merged branch reflog gone" "[ ! -e '$R/r/.git/logs/refs/heads/worktree-merged' ]"
chk "nopr branch kept" "git -C '$R/r' rev-parse -q --verify refs/heads/worktree-nopr >/dev/null"
chk "closed branch kept" "git -C '$R/r' rev-parse -q --verify refs/heads/worktree-closed >/dev/null"
chk "gone branch kept" "git -C '$R/r' rev-parse -q --verify refs/heads/worktree-gone >/dev/null"
chk "slash branch deleted" "! git -C '$R/r' rev-parse -q --verify refs/heads/feature/slash >/dev/null"
chk "empty parent dir of slash worktree removed" "[ ! -e '$W/r/feature' ]"
chk "cv merged branch deleted" "! git -C '$R/curriculum vitae' rev-parse -q --verify refs/heads/worktree-merged >/dev/null"
chk "local-only empty branch kept" "git -C '$R/local' rev-parse -q --verify refs/heads/worktree-empty >/dev/null"
chk "T3 worktree untouched" "[ -d '$HOME/.t3/worktrees/r/t3-thing' ]"
chk "treehouse slot untouched" "[ -d '$HOME/.treehouse/r-pool/slot1' ]"
chk "detpriv kept on disk" "[ -d '$W/r/detpriv' ]"
chk "open worktree admin index mtime unchanged" "[ \"\$(stat -f %m '$ADMIN_OPEN/index')\" = '$IDX_BEFORE' ]"
chk "r: only gone2 and solo are left as stale entries" "[ \"\$(git -C '$R/r' worktree list --porcelain | grep -c '^prunable')\" = 2 ]"
chk "no admin dir left for removed worktrees" "[ ! -e '$R/r/.git/worktrees/merged' ] && [ ! -e '$R/r/.git/worktrees/nopr' ]"
chk "S1 new files still on disk" "[ -e '$W/s/sqlwork/db/migrations/0042_add_index.sql' ] && [ -e '$W/s/sqlwork/AGENTS.md' ]"
chk "S2 nested wip.txt still on disk" "[ -e '$W/s/outer/.claude/worktrees/inner/wip.txt' ]"
chk "S2b nested clone edit still on disk" "grep -q patched '$W/s/outer2/vendor/lib/README'"
chk "S3 hidden edits still on disk" "grep -q 'local edit' '$W/s/skipwt/f-s3.txt' && grep -q 'local edit' '$W/s/assume/f-s3b.txt'"
chk "S4 renamed worktree still works" "git -C '$W/s/moved1-renamed' status --porcelain >/dev/null 2>&1"
chk "S4 staged file still staged" "git -C '$W/s/moved1-renamed' diff --cached --name-only | grep -qx staged.txt"
chk "S4b original and copy both still work" "git -C '$W/s/orig' status >/dev/null 2>&1 && git -C '$W/s/orig-copy' status >/dev/null 2>&1"
chk "S7 repo folder ~/worktrees/t2 kept" "[ -d '$W/t2' ]"
chk "S10 commit still reachable" "[ \"\$(reach '$DETREF')\" -ge 1 ]"
chk "S10b commit still reachable through the kept branch's reflog" "[ \"\$(reach '$RESETAWAY')\" -ge 1 ]"
chk "S10b branch kept" "git -C '$MS' rev-parse -q --verify refs/heads/worktree-resetaway >/dev/null"
chk "S1c seed worktree gone" "[ ! -e '$W/s/seeded' ]"
chk "the hook copied CLAUDE.md and CLAUDE.local.md in and recorded them" "[ '$HK_SEEDED' = yes ]"
chk "the hook's seed list went with the admin dir" "[ ! -e '$R/hk/.git/worktrees/hkstale' ] && [ ! -e '$R/hk/.git/worktrees/hksame' ]"
chk "HK3 and HK4 edits still on disk" "grep -q no-cov '$W/hk/hkedit/CLAUDE.md' && grep -q no-cov '$W/hk/hknotes/CLAUDE.md'"
TRASHED=$(find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -name 'merged *' | head -n 1)
chk "the merged clone is in the Trash, .git and all" "[ ! -e '$W/co/merged' ] && [ -n '$TRASHED' ] && git -C '$TRASHED' cat-file -e HEAD"
chk "only the three removable clones went to the Trash" "[ \"\$(find '$HOME/.Trash' -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')\" = 3 ] && [ \"\$(wc -l <'$T/trash-calls.log' | tr -d ' ')\" = 3 ]"
chk "the clone's repo folder ~/worktrees/co stays" "[ -d '$W/co' ]"
chk "CO3 and CO5 work still on disk" "grep -q more '$W/co/dirty/README' && git -C '$W/co/stashed' rev-parse -q --verify refs/stash >/dev/null"
chk "repository r passes fsck" "git -C '$R/r' fsck --no-dangling >/dev/null 2>&1"
chk "repository s passes fsck" "git -C '$MS' fsck --no-dangling >/dev/null 2>&1"
chk "repository rb passes fsck" "git -C '$MRB' fsck --no-dangling >/dev/null 2>&1"
chk "RB1, RB2, RB3, RB5, RB8, RB10 and RB11 commits still reachable" "(for c in $RB1 $RB2 $RB3 $RB5 $RB8 $RB10 $RB11; do [ \"\$(reachin '$MRB' \$c)\" -ge 1 ] || exit 1; done)"
chk "RB14, RB15, RB16 and RB19 commits still reachable" "(for c in $RB14 $RB15 $RB16 $RB19; do [ \"\$(reachin '$MRB' \$c)\" -ge 1 ] || exit 1; done)"
chk "RB4 commit still reachable through the kept branch's reflog" "[ \"\$(reachin '$MRB' '$RB4')\" -ge 1 ] && git -C '$MRB' rev-parse -q --verify refs/heads/worktree-abreset >/dev/null"
chk "RB12's .env and notes still on disk" "grep -q API_KEY=new '$W/rb/ignuse/.env' && grep -q hand-off '$W/rb/ignuse/notes/todo.md'"
chk "CO14 and CO15 commits still in their clones" "[ \"\$(reachin '$W/co/abortrl' '$CO14')\" -ge 1 ] && [ \"\$(reachin '$W/co/twobr' '$CO15')\" -ge 1 ]"
chk "TR1 commit still reachable through the kept branch's reflog" "[ \"\$(reachin '$MTR' '$TR1')\" -ge 1 ] && git -C '$MTR' rev-parse -q --verify refs/heads/worktree-teamreset >/dev/null"
chk "TR3 branch kept" "git -C '$MTR' rev-parse -q --verify refs/heads/worktree-pushedmerged >/dev/null"
chk "CO18 commit still in its clone" "[ \"\$(reachin '$W/co/teamreset' '$CO18')\" -ge 1 ]"
chk "RB24's tip and halfway commit, RB27's commit and RB28's stash still reachable" "[ -n '$RB24MID' ] && (for c in $RB24 $RB24MID $RB27 $RB28; do [ \"\$(reachin '$MRB' \$c)\" -ge 1 ] || exit 1; done)"
chk "RB21's merged branch deleted, RB22's pushed one kept" "! git -C '$MRB' rev-parse -q --verify refs/heads/worktree-sqmerged >/dev/null && git -C '$MRB' rev-parse -q --verify refs/heads/worktree-fixups >/dev/null"
chk "attention lists the broken folder" "grep -Fq '$W/r/broken | broken: its admin dir is gone' '$ATT'"
chk "attention says the husk's admin dir is there but unusable" "grep -Fq '$W/r/husk | broken: its admin dir $T/husk-admin is there, but git cannot use it' '$ATT'"
chk "attention lists the moved folder with a repair command" "grep -Fq '$W/s/moved1-renamed | moved here from' '$ATT' && grep -Fq 'worktree repair' '$ATT'"
chk "attention lists the copy" "grep -Fq '$W/s/orig-copy | shares the admin dir' '$ATT'"
chk "attention lists the worktree and the clone whose reflogs could not be read" "grep -Fq '$W/rb/unread | kept: detached HEAD, and its reflog could not be read' '$ATT' && grep -Fq '$W/co/unreadrl | kept: clone, could not read its reflogs' '$ATT' && grep -Fq '$W/rb/unlist | kept: detached HEAD, and its reflog could not be read' '$ATT'"
chk "attention lists the worktree kept only for an ignored file" "grep -F '$W/rb/ignuse | kept: its last use is ' '$ATT' | grep -Fq 'a file its .gitignore hides, which changed 0d ago, and nothing else shows use for 20d'"
chk "attention leaves out the worktree whose ignored caches changed" "! grep -Fq '$W/rb/igncache' '$ATT'"
chk "attention lists the worktree with an ignored folder it could not read" "grep -Fq '$W/rb/ignlocked | kept: could not read all of data/locked/' '$ATT'"
chk "RB20's unreadable folder is still there" "[ -d '$IGNLOCKED' ]"
chk "attention leaves out clones in use or young" "! grep -Fq '$W/r/fullclone' '$ATT' && ! grep -Fq '$W/co/fresh' '$ATT' && ! grep -Fq '$W/co/dirty' '$ATT'"
chk "attention lists the 40-day-old clone with an open PR" "grep -Fq '$W/co/openpr | kept, idle 40d: clone, PR test/co#62 (draft) open' '$ATT'"
chk "attention lists the 40-day-old draft PR worktree" "grep -Fq '$W/r/open | kept, idle 40d: PR test/r#12 (draft) open' '$ATT'"
chk "summary went to the logger shim" "grep -q 'removed=' '$T/logger.log'"

echo "== second run is a no-op for what is left"
/bin/bash "$JOB" >"$T/run2.out" 2>&1
chk "second run removes nothing" "grep -q 'DONE    removed=0 ' '$T/run2.out'"
age_admin "$ADMIN_B" 20
/bin/bash "$JOB" >"$T/run3.out" 2>&1
expect "$T/run3.out" REMOVED worktrees/t2/b "stale entry cleared"

echo "== S11: a later fetch with fetch.pruneTags drops the local-only tag"
git -C "$MS" fetch -q origin 2>&1
chk "tag gone after fetch" "! git -C '$MS' rev-parse -q --verify refs/tags/snapshot-s11 >/dev/null"
chk "S11 worktree kept, so its commit is still reachable" "[ -d '$W/s/tagged' ] && git -C '$W/s/tagged' cat-file -e HEAD"

echo "== S14b: a transcript folder whose name Claude Code cut at 200 characters"
# A run of its own: the cut name stands for every path that shares its
# first 200 characters, which under a long TMPDIR is every worktree in the
# sandbox, and the job counts it as use for each of them.
LONG=transcript-hashed-name-$(printf '%0200d' 0)
hookwt "$MS" s "$LONG"; work "$W/s/$LONG" s14b
pushwt "$W/s/$LONG"; age "$W/s/$LONG" 20
E=$(enc "$W/s/$LONG"); echo "S14b encoded length: ${#E}"
CUT="$HOME/.claude/projects/${E:0:200}-1a2b3c"
mkdir -p "$CUT"; echo '{}' >"$CUT/x.jsonl"
/bin/bash "$JOB" --dry-run >"$T/s14b.out" 2>&1
expect "$T/s14b.out" KEEP "worktrees/s/$LONG" "Claude Code transcript"
rm -r -- "$CUT"

echo "== commands the job ran"
FORBID='(^| )(gc|repack|prune|maintenance|fetch|push|pull|reset|clean|checkout|switch|repair|branch|tag|commit|merge|rebase|stash)( |$)'
if sed -E 's/^(-c [^ ]+ )+//' "$T/git-calls.log" | grep -Eiq "$FORBID"; then
  bad "forbidden git subcommand"; sed -E 's/^(-c [^ ]+ )+//' "$T/git-calls.log" | grep -Ei "$FORBID" | sort -u | head
else ok "no gc, repack, prune, maintenance, fetch, push, branch, tag or repair"; fi
if grep -Eq '(^| )(--force|-f|-ff|-D|-w)( |$)' "$T/git-calls.log"; then
  bad "force or write flag used"; grep -E '(^| )(--force|-f|-ff|-D|-w)( |$)' "$T/git-calls.log" | head
else ok "no --force, -f, -D, or hash-object -w"; fi
if grep -v 'maintenance.auto=false -c gc.auto=0 -c core.fsmonitor=false -c core.hooksPath=/dev/null' "$T/git-calls.log" | grep -vq '^--version$'; then
  bad "a git call without the guard settings"; grep -v 'maintenance.auto=false' "$T/git-calls.log" | sort -u | head -3
else ok "every git call carries the guard settings"; fi
grep -o 'worktree remove' "$T/git-calls.log" | wc -l | sed 's/^ */      worktree remove calls: /'
sed -E 's/^(-c [^ ]+ )+//' "$T/git-calls.log" | awk '{ for (i = 1; i <= NF; i++) if ($i !~ /^-/ && $(i-1) != "-C") { print $i; break } }' |
  sort | uniq -c | sort -rn | head -12 | sed 's/^/      /'
wc -l <"$T/gh-calls.log" | sed 's/^ */      gh calls: /'
if grep -Fq "worktree-recent" "$T/gh-calls.log"; then bad "gh called for a recent worktree"; else ok "gh only called for worktrees past the TTL"; fi
if grep -Fq "worktree-idle" "$T/gh-calls.log"; then bad "gh called for a tip already in the default branch"; else ok "gh not called when the tip is already in the default branch"; fi

echo "== gh failing on every run raises attention after three runs"
touch "$T/gh-fail-all"
for i in 1 2 3; do /bin/bash "$JOB" --dry-run >"$T/ghall$i.out" 2>&1; done
chk "three failed runs are flagged" "grep -q 'gh | every PR lookup failed on 3 runs in a row; last error: HTTP 401' '$ATT'"
rm "$T/gh-fail-all"
/bin/bash "$JOB" --dry-run >/dev/null 2>&1
chk "a good run resets the count" "[ \"\$(cat '$HOME/Library/Logs/worktree-ttl/gh-failed-runs')\" = 0 ]"

echo "== guards"
mkdir "$HOME/Library/Logs/worktree-ttl/run.lock" && echo $$ >"$HOME/Library/Logs/worktree-ttl/run.lock/pid"
/bin/bash "$JOB" >"$T/locked.out" 2>&1
chk "a second concurrent run exits" "grep -q 'another run (pid $$) is still going' '$T/locked.out'"
rm -- "$HOME/Library/Logs/worktree-ttl/run.lock/pid"; rmdir -- "$HOME/Library/Logs/worktree-ttl/run.lock"
mkdir "$HOME/Library/Logs/worktree-ttl/run.lock"; echo 99999 >"$HOME/Library/Logs/worktree-ttl/run.lock/pid"
/bin/bash "$JOB" --dry-run >"$T/stale.out" 2>&1
chk "a stale lock from a dead pid is taken over" "grep -q '^.* DONE ' '$T/stale.out'"
/bin/bash "$JOB" --ttl-days 0 >/dev/null 2>&1
chk "ttl 0 is rejected" "[ \$? -eq 2 ]"
/bin/bash "$JOB" --root "$T/nowhere" >"$T/noroot.out" 2>&1
chk "missing root is skipped" "grep -q 'DONE    no folder to sweep' '$T/noroot.out'"
env -i HOME="$HOME" TMPDIR="$TMPDIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
  WORKTREE_TTL_GH="$T/bin/gh" WORKTREE_TTL_PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  /bin/bash "$JOB" --dry-run >"$T/envi.out" 2>&1
chk "a run with an empty environment works and finds git itself" "grep -q 'DONE    removed=' '$T/envi.out' && grep -q 'git=2' '$T/envi.out'"

echo "== a repositories folder the job may not read"
RMODE=$(stat -f %Lp "$R")
chmod 000 "$R"
/bin/bash "$JOB" >"$T/denied.out" 2>"$T/denied.err"
echo "exit $?" >>"$T/denied.out"
chmod "$RMODE" "$R"
chk "the run stops with a nonzero exit" "grep -q '^exit 1$' '$T/denied.out'"
chk "stderr says the folder cannot be read and what to do" "grep -Fq 'worktree-ttl: cannot read $R: Permission denied; check its permissions' '$T/denied.err'"
chk "attention says so in one line" "grep -Fq '1 item(s) need a person' '$ATT' && grep -Fq '$R | cannot read the repositories folder (Permission denied), so no worktree was judged; check its permissions' '$ATT'"
chk "neither asks for a privacy grant" "! grep -Eq 'Privacy|Full Disk|/bin/bash access' '$T/denied.err' '$ATT'"
chk "no worktree was judged" "! grep -Eq '^[^ ]+ (KEEP|REMOVED|WOULD|FAILED) ' '$T/denied.out'"
chk "the log records the stop" "grep -Fq 'ABORT   cannot read $R: Permission denied' '$HOME/Library/Logs/worktree-ttl/worktree-ttl.log'"
# A main checkout outside the repos folder, in a folder the job may not read.
git clone -q git@github.com:test/r.git "$T/outside/x" 2>/dev/null
git -C "$T/outside/x" worktree add -q --no-track -b worktree-wt "$W/x/wt" origin/main 2>/dev/null
OMODE=$(stat -f %Lp "$T/outside")
chmod 000 "$T/outside"
/bin/bash "$JOB" --dry-run >"$T/outside.out" 2>&1
chmod "$OMODE" "$T/outside"
expect "$T/outside.out" KEEP worktrees/x/wt "cannot read $T/outside/x/.git/worktrees/wt: Permission denied"
chk "attention says it cannot read that worktree's admin dir, not that it is gone" "grep -Fq '$W/x/wt | cannot read $T/outside/x/.git/worktrees/wt: Permission denied; check its permissions' '$ATT' && ! grep -Fq '$W/x/wt | broken' '$ATT'"

echo "== real-world config: fsmonitor on, untracked files hidden"
git config --global core.fsmonitor true
git config --global status.showUntrackedFiles no
hookwt "$R/r" r fsm; work "$W/r/fsm" fs; pushwt "$W/r/fsm"
git -C "$W/r/fsm" status --porcelain >/dev/null 2>&1   # what an agent would do; may start a daemon
git -C "$W/r/fsm" fsmonitor--daemon stop >/dev/null 2>&1
echo hidden >"$W/r/fsm/hidden.txt"; age "$W/r/fsm" 20
if [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$W/r/fsm" -c core.fsmonitor=false status --porcelain)" ]; then ok "plain status hides the untracked file under this config"; else bad "plain status shows it"; fi
/bin/bash "$JOB" >"$T/run4.out" 2>&1
expect "$T/run4.out" KEEP worktrees/r/fsm "uncommitted or untracked changes"
DAEMONS=""
for p in $(pgrep -f 'fsmonitor--daemon' 2>/dev/null); do
  if lsof -p "$p" 2>/dev/null | grep -Fq "$T"; then DAEMONS="$DAEMONS $p"; fi
done
chk "the job started no fsmonitor daemon in the sandbox" "[ -z '$DAEMONS' ]"
for p in $DAEMONS; do kill "$p" 2>/dev/null; done
git config --global --unset core.fsmonitor
git config --global --unset status.showUntrackedFiles

echo "== the apply script reloads the LaunchAgent after a plist change"
# A launchctl whose bootout of a running job returns at once, while the job
# stays loaded for LEAVE more prints, as launchd does while it stops it.
LC="$T/launchctl"
mkdir -p "$LC/bin" "$LC/home/Library/LaunchAgents" "$LC/home/Library/Logs/worktree-ttl"
cat >"$LC/bin/launchctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$LC/calls"
st=\$(cat "$LC/state" 2>/dev/null)
case \$1 in
  print)
    case \$2 in
      */com.carlosetejada.worktree-ttl)
        case \$st in
          loaded) exit 0 ;;
          leaving*)
            n=\${st#leaving }
            if [ "\$n" -gt 0 ]; then echo "leaving \$((n - 1))" >"$LC/state"; exit 0; fi
            echo gone >"$LC/state"; exit 113 ;;
          *) exit 113 ;;
        esac ;;
      *) exit 0 ;;
    esac ;;
  bootout) [ "\$st" = loaded ] && echo "leaving \${LEAVE:-3}" >"$LC/state"; exit 0 ;;
  bootstrap)
    case \$st in loaded | leaving*) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;; esac
    echo loaded >"$LC/state" ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' >"$LC/bin/sleep"
chmod +x "$LC/bin/launchctl" "$LC/bin/sleep"
RA="$LC/run_after.sh"
if (. "$REPO/tests/lib.sh" && sandbox agent-mini >/dev/null 2>&1 &&
  cz execute-template <"$REPO/home/.chezmoiscripts/run_after_59-launch-agents.sh.tmpl" >"$RA"
  rc=$?; cleanup_sandbox; exit $rc) && [ -s "$RA" ]; then
  ok "the apply script renders for the agent-mini"
else
  bad "the apply script renders for the agent-mini"
fi
PL="$LC/home/Library/LaunchAgents/com.carlosetejada.worktree-ttl.plist"
MK="$LC/home/Library/Logs/worktree-ttl/.loaded"
echo '<plist/>' >"$PL"; touch -t 202001010000 "$MK"; echo loaded >"$LC/state"
HOME="$LC/home" PATH="$LC/bin:$PATH" bash "$RA" >"$LC/out1" 2>&1
chk "a reload while the job runs leaves it loaded" "[ \"\$(cat '$LC/state')\" = loaded ]"
chk "it says so and refreshes its marker" "grep -q 'loaded the worktree cleanup job' '$LC/out1' && [ ! '$PL' -nt '$MK' ]"
touch -t 202001010000 "$MK"; echo loaded >"$LC/state"; : >"$LC/calls"
HOME="$LC/home" PATH="$LC/bin:$PATH" LEAVE=1000 bash "$RA" >"$LC/out2" 2>&1
chk "when launchd never lets go, it gives up after 30 tries" "[ \"\$(grep -c '/com.carlosetejada.worktree-ttl\$' '$LC/calls')\" -le 33 ]"
chk "and says the cleanup job is not loaded" "grep -q 'worktree cleanup job is not loaded' '$LC/out2'"
chk "and leaves the marker for the next apply to retry" "[ '$PL' -nt '$MK' ]"

kill "$SLEEPER" 2>/dev/null
wait "$SLEEPER" 2>/dev/null
rm -f -- "$HOME/.claude/sessions/a-$$.json" "$HOME/.claude/sessions/b-$$.json" "$HOME/.claude/sessions/c-$$.json"

echo "== T3 threads, pending steps and the short limit for landed work"
# A home of its own, so each run judges only these cases. Nothing in them is
# in use, so a stand-in lsof saves each of these many runs the real one's scan.
mkdir "$T/noproc"
printf '#!/bin/bash\nexit 0\n' >"$T/noproc/lsof"
chmod +x "$T/noproc/lsof"
export WORKTREE_TTL_PATH="$T/noproc:$WORKTREE_TTL_PATH"
export HOME="$T/t3home"
R="$HOME/src" W="$HOME/worktrees" TW="$HOME/.t3/worktrees"
ATT="$HOME/Library/Logs/worktree-ttl/attention.txt"
DRAFTS="$HOME/agent-drafts" GATES="$HOME/.local/state/t3-pstack/orchestrate/run1"
mkdir -p "$R" "$W/co" "$TW/co" "$HOME/.claude/projects" "$HOME/.t3/scratch" "$HOME/.local/bin" "$DRAFTS" "$GATES" "$HOME/.Trash"
for n in own oth pla lon kl; do
  git init -q --bare "$T/remote/$n.git"
  git -C "$T/seed" push -q "git@github.com:test/$n.git" main
done
git clone -q git@github.com:test/own.git "$R/own"
git clone -q git@github.com:test/oth.git "$R/oth"
git clone -q git@github.com:test/pla.git "$R/pla"
git clone -q git@github.com:test/lon.git "$T/lone"
addwt() { git -C "$1" worktree add -q --no-track -b "$3" "$2" origin/main 2>/dev/null; } # main path branch
landed() { # main path branch repo pr-number days
  addwt "$1" "$2" "$3"; work "$2" "l$5"; pushwt "$2"
  pr "test/$4" "$3" "$5" MERGED "$(tip "$2")"; age "$2" "$6"
}
landed "$R/own" "$W/own/a" fix/a own 5 2
landed "$R/own" "$W/own/a-2" fix/a-2 own 50 2
landed "$R/own" "$W/own/a.3" fix/third own 53 2
landed "$R/own" "$W/own/plain" plainword own 54 2
landed "$R/own" "$W/own/young" fix/young own 55 0
landed "$R/own" "$TW/own/t3-land" t3/land own 56 2
landed "$R/oth" "$W/oth/b" fix/b oth 61 2
landed "$R/pla" "$W/pla/c" fix/c pla 62 2
landed "$T/lone" "$W/lon/d" fix/d lon 63 2
addwt "$R/own" "$W/own/pushed" fix/pushed; work "$W/own/pushed" p; pushwt "$W/own/pushed"; age "$W/own/pushed" 2
addwt "$R/own" "$W/own/old" fix/old; work "$W/own/old" o; pushwt "$W/own/old"; age "$W/own/old" 40
addwt "$R/own" "$W/own/closed" fix/closed; work "$W/own/closed" c; pushwt "$W/own/closed"
pr test/own fix/closed 57 CLOSED "$(tip "$W/own/closed")"; age "$W/own/closed" 2
git -C "$R/own" worktree add -q --detach "$W/own/det" origin/main 2>/dev/null; age "$W/own/det" 2
addwt "$R/own" "$W/own/local" fix/local; work "$W/own/local" lc; age "$W/own/local" 2
# As hurin's planner/slips: never pushed, and inside another branch's merged PR.
addwt "$R/own" "$W/own/slips" planner/slips; work "$W/own/slips" slips
git -C "$R/own" worktree add -q --no-track -b planner/all "$T/all" planner/slips 2>/dev/null
work "$T/all" all; pushwt "$T/all"
pr test/own planner/all 600 MERGED "$(tip "$T/all")"
git -C "$R/own" worktree remove "$T/all"
git --git-dir="$T/remote/own.git" branch -q -D planner/all
git -C "$R/own" fetch -q --prune; age "$W/own/slips" 2
# The same inside a PR that is still open.
addwt "$R/own" "$W/own/stacked" planner/stacked; work "$W/own/stacked" stacked
git -C "$R/own" worktree add -q --no-track -b planner/top "$T/top" planner/stacked 2>/dev/null
work "$T/top" top; pushwt "$T/top"
pr test/own planner/top 601 OPEN "$(tip "$T/top")"
git -C "$R/own" worktree remove "$T/top"; age "$W/own/stacked" 2
addwt "$R/own" "$W/own/gone" fix/gone; age "$W/own/gone" 20; rm -r -- "$W/own/gone"
# Merged with its own commit in main, so the tip is in the default branch.
addwt "$R/own" "$W/own/inmain" fix/inmain; work "$W/own/inmain" inmain; pushwt "$W/own/inmain"
git -C "$W/own/inmain" push -q origin HEAD:main 2>/dev/null
pr test/own fix/inmain 58 MERGED "$(tip "$W/own/inmain")"
git -C "$R/own" fetch -q; age "$W/own/inmain" 2
for c in "cl:20" "clnew:2"; do
  d="$W/co/${c%:*}"
  git clone -q git@github.com:test/kl.git "$d" 2>/dev/null
  git -C "$d" switch -q -c "kl-${c%:*}"; work "$d" "${c%:*}"; pushwt "$d"
  pr test/kl "kl-${c%:*}" "7${c#*:}" MERGED "$(tip "$d")"; age "$d" "${c#*:}"
done
git clone -q git@github.com:test/kl.git "$TW/co/tc" 2>/dev/null; age "$TW/co/tc" 20

# The fake t3: a project is a root folder, and a path inside it resolves to
# the nearest. t3-mode breaks one call at a time.
printf '%s\t%s\n' "$R" psrc "$R/own" pown "$R/oth" poth "$HOME/.t3/scratch" pscratch >"$T/projects.tsv"
cat >"$T/bin/t3" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$T/t3-calls.log"
mode=\$(cat "$T/t3-mode" 2>/dev/null)
case "\$1 \$2 \$mode" in
  *" down") echo "No running T3 Code server uses $HOME/.t3" >&2; exit 1 ;;
  "thread list slow" | "thread show slowshow") exec sleep 30 ;;
  "thread list badlist" | "thread show badshow") echo "[{"; exit 0 ;;
  "thread list empty" | "thread show empty") exit 0 ;;
  "thread list notarray") echo '{"threads":[]}'; exit 0 ;;
  "thread list nofield") echo '[{"threadId":"t","projectId":"pown","title":"x","createdAt":"2026-11-20T10:00:00.000Z"}]'; exit 0 ;;
  "thread list nodate") echo '[{"threadId":"t","projectId":"pown","title":"x","settled":false,"createdAt":"yesterday"}]'; exit 0 ;;
  "thread show showdown") echo "request failed" >&2; exit 1 ;;
  "thread show nomessages") echo '{"thread":{}}'; exit 0 ;;
  "thread show nulltext") echo '{"thread":{},"messages":[{"role":"user","runId":null,"text":null}]}'; exit 0 ;;
  "thread show numtext") echo '{"thread":{},"messages":[{"role":"user","runId":null,"text":5}]}'; exit 0 ;;
esac
case "\$1 \$2" in
  "thread list")
    [ "\$3" = --project ] && [ "\$5" = --json ] || exit 2
    id=\$(P="\$4/" awk -F '\t' 'index(ENVIRON["P"], \$1 "/") == 1 && length(\$1) > n { n = length(\$1); id = \$2 }
      END { print id }' "$T/projects.tsv")
    if [ -z "\$id" ]; then echo "No T3 Code project matches '\$4'. Pass a project id or a path inside a project." >&2; exit 1; fi
    /usr/bin/jq -s --arg p "\$id" '[.[] | select(.projectId == \$p) | del(.text)]' "$T/threads.jsonl" ;;
  "thread show")
    [ "\$4 \$5 \$6" = "--messages 100000 --json" ] || exit 2
    /usr/bin/jq -s --arg t "\$3" '.[] | select(.threadId == \$t) |
      {thread: del(.text), messages: [{role: "user", runId: null, text: "hello"}, {role: "assistant", runId: "r", text: .text}]}' "$T/threads.jsonl" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/bin/t3"
threads() { : >"$T/threads.jsonl"; }
thread() { # id project settled created-epoch title text [more-fields-json]
  /usr/bin/jq -n -c --arg id "$1" --arg p "$2" --argjson s "$3" --arg c "$(date -u -r "$4" +%Y-%m-%dT%H:%M:%S.123Z)" \
    --arg title "$5" --arg text "$6" --argjson x "${7:-null}" \
    '{threadId: $id, projectId: $p, settled: $s, createdAt: $c, title: $title, text: $text} + ($x // {})' >>"$T/threads.jsonl"
}
ago() { echo $(($(date +%s) - $1 * 86400)); }
sweep() { /bin/bash "$JOB" --dry-run --ttl-days 14 --landed-days 1 --keep-branches --root "$W" --root "$TW" >"$O" 2>&1; }
says() { # output action case...: the job's decision for each case
  local f=$1 act=$2 c
  shift 2
  for c in "$@"; do
    case $c in t3/*) expect "$f" "$act" ".t3/worktrees/${c#t3/}" "" ;; *) expect "$f" "$act" "worktrees/$c" "" ;; esac
  done
}
LANDED="own/a own/a-2 own/a.3 own/plain own/slips own/inmain oth/b pla/c lon/d t3/own/t3-land"
OWN="own/a own/a-2 own/a.3 own/plain own/slips own/inmain t3/own/t3-land"
threads

echo "-- no T3, and the short limit"
O="$T/t-none.out"; : >"$T/gh-calls.log"; sweep
says "$O" WOULD $LANDED own/old own/gone co/cl
expect "$O" WOULD worktrees/own/a "branch kept (--keep-branches)"
expect "$O" WOULD worktrees/own/slips "PR test/own#600 merged under another branch's name"
expect "$O" KEEP worktrees/own/young "used 0d ago"
expect "$O" KEEP worktrees/own/pushed "used 2d ago"
expect "$O" KEEP worktrees/own/pushed "TTL 14d"
expect "$O" KEEP worktrees/own/closed "used 2d ago"
expect "$O" KEEP worktrees/own/det "used 2d ago"
expect "$O" KEEP worktrees/co/clnew "used 2d ago"
expect "$O" KEEP worktrees/own/local "no merged PR contains this tip"
expect "$O" KEEP worktrees/own/stacked "PR test/own#601 open"
expect "$O" SKIP .t3/worktrees/co/tc "which the job never touches"
chk "no PR lookup for work used inside the short limit" "! grep -q 'fix/young' '$T/gh-calls.log'"
chk "a commit's PRs are asked for by its sha" "grep -q 'api repos/test/own/commits/$(tip "$W/own/slips")/pulls' '$T/gh-calls.log'"
/bin/bash "$JOB" --dry-run --ttl-days 14 --root "$W" --root "$TW" >"$T/t-today.out" 2>&1
says "$T/t-today.out" KEEP $LANDED
says "$T/t-today.out" WOULD own/old co/cl
/bin/bash "$JOB" --dry-run --landed-days 3 --root "$W" >"$T/t-three.out" 2>&1
says "$T/t-three.out" KEEP own/a
for v in 0 x 15; do
  /bin/bash "$JOB" --dry-run --ttl-days 14 --landed-days "$v" >/dev/null 2>&1
  chk "landed days $v is rejected" "[ $? -eq 2 ]"
done
for a in "--ttl-days 10000" "--ttl-days 99999999999999999999" "--landed-days 99999999999999999999" "--landed-days 00001"; do
  # shellcheck disable=SC2086  # an option and its value
  /bin/bash "$JOB" --dry-run --root "$W" $a >/dev/null 2>&1
  chk "$a, more than 4 digits, is rejected" "[ $? -eq 2 ]"
done
echo "gh: Not Found (HTTP 404)" >"$T/gh-commit-fail"
O="$T/t-404.out"; sweep
expect "$O" KEEP worktrees/own/local "no merged PR contains this tip"
chk "a 404 for a commit is no gh outage" "! grep -q 'PR state unknown' '$O'"
echo "gh: Server Error (HTTP 500)" >"$T/gh-commit-fail"
O="$T/t-500.out"; sweep
expect "$O" KEEP worktrees/own/slips "PR state unknown (gh: Server Error (HTTP 500))"
rm "$T/gh-commit-fail"

# A hold check that dies, or whose search fails, is no answer, so it keeps.
for how in 'kill -9 "$PPID"' 'exit 2'; do
  printf '#!/bin/bash\ncase "$*" in *hold.cd*) %s ;; esac\nexec /usr/bin/grep "$@"\n' "$how" >"$T/noproc/grep"
  chmod +x "$T/noproc/grep"
  O="$T/t-nocheck.out"
  /bin/bash "$JOB" --dry-run --landed-days 1 --root "$W/oth" >"$O" 2>&1
  expect "$O" KEEP worktrees/oth/b "could not check what holds it"
done
rm "$T/noproc/grep"

echo "-- which threads hold by date"
ln -s "$T/bin/t3" "$HOME/.local/bin/t3"
O="$T/t-up.out"; sweep
says "$O" WOULD $LANDED own/old own/gone co/cl
threads; thread s1 psrc true "$(ago 90)" Settled "$W/own/a fix/a-2 github.com/test/own/pull/600"
O="$T/t-settled.out"; sweep
says "$O" WOULD $LANDED own/old co/cl
threads; thread o1 pown false "$(ago 3)" "Plan Hurin Tool Rewrite" "nothing named"
O="$T/t-own.out"; sweep
says "$O" KEEP $OWN lon/d
says "$O" WOULD oth/b pla/c own/old own/gone co/cl
expect "$O" KEEP worktrees/own/a 'open T3 thread "Plan Hurin Tool Rewrite"'
threads; thread o2 pown false "$(ago 1)" Newer "nothing named"
O="$T/t-newer.out"; sweep
says "$O" WOULD $LANDED
threads; thread o3 pown false "$(stat -f %m "$(git -C "$W/own/a" rev-parse --path-format=absolute --git-dir)/index")" Same "nothing named"
O="$T/t-same.out"; sweep
says "$O" KEEP own/a
for p in psrc pscratch; do
  threads; thread "o4-$p" "$p" false "$(ago 3)" "No repo" "nothing named"
  O="$T/t-$p.out"; sweep
  says "$O" KEEP $LANDED
  says "$O" WOULD own/old co/cl
done
threads; thread o5 poth false "$(ago 90)" "Long one" "nothing named"
O="$T/t-long.out"; sweep
says "$O" KEEP oth/b lon/d co/cl
says "$O" WOULD own/a pla/c own/old
threads; thread o6 pown false "$(ago 90)" "Long own" "nothing named"
O="$T/t-longown.out"; sweep
says "$O" KEEP own/old own/gone
chk "a hold idle past twice the TTL is flagged" "grep -q 'own/old | kept, idle 40d: .*Long own' '$ATT'"

echo "-- which threads hold by name"
# named TEXT, then the case that text holds; "" for none.
named() {
  local c
  threads; thread n1 poth false "$(date +%s)" Namer "$1"
  O="$T/t-named.out"; sweep
  for c in $LANDED own/old own/gone co/cl; do
    case " $2 " in
      *" $c "*) says "$O" KEEP "$c" ;;
      *) says "$O" WOULD "$c" ;;
    esac
  done
}
named "Work in $W/own/a. Then ~/worktrees/co/cl/src/x.py" "own/a co/cl"
named "Look at \`~/worktrees/own/a-2\`, $TW/own/t3-land and ~/worktrees/own/gone" "own/a-2 own/gone t3/own/t3-land"
# shellcheck disable=SC2088  # a literal ~, as threads write it
named "~/worktrees/own/a/src and ~/worktrees/own/a.3, not ~/worktrees/own/old-notes or ~/worktrees/own/plainer" "own/a own/a.3"
named "Review fix/a, please" "own/a"
named "git log origin/main..fix/a; git diff origin/fix/b" "own/a oth/b"
named "on fix/a-2." "own/a-2"
named "branches planner/slips and kl-cl" "own/slips co/cl"
named "https://github.com/test/own/pull/5" "own/a"
named "https://github.com/test/own/pull/50/files, github.com/test/own/pull/600. github.com/test/own/pull/58 and https://github.com/test/kl/pull/720" "own/a-2 own/slips own/inmain co/cl"
named "prefix/a fix/a/b fix/a_1 plainword planner/slips-2 kl-clx ~/worktrees/own/a-22 github.com/test/own/pull/6000 github.com/test/oth/pull/5" ""

echo "-- pending cd steps"
threads
mkdir -p "$DRAFTS/own/x/node_modules/p" "$DRAFTS/own/x/.venv" "$DRAFTS/own/x/.git"
cat >"$DRAFTS/own/x/steps.md" <<EOF
Run \`cd ~/worktrees/own/a && make\`, then:
    cd "\$HOME/worktrees/oth/b/sub"
    cd \${HOME}/worktrees/pla/c
    cd '$W/lon/d'
    cd ~/worktrees/own/gone
    cd ~/worktrees/co/cl; true
    cd ~/worktrees/own/old-notes
    ls ~/worktrees/own/plain
EOF
echo "cd ~/worktrees/own/a.3" >"$DRAFTS/own/x/steps.txt"
for d in node_modules/p .venv .git; do echo "cd ~/worktrees/own/a.3" >"$DRAFTS/own/x/$d/skip.md"; done
echo "- [ ] cd ~/.t3/worktrees/own/t3-land" >"$GATES/gates.md"
echo "cd ~/worktrees/own/inmain" >"$GATES/notes.md"
O="$T/t-steps.out"; sweep
says "$O" KEEP own/a oth/b pla/c lon/d own/gone co/cl t3/own/t3-land
says "$O" WOULD own/a-2 own/a.3 own/plain own/old own/inmain
expect "$O" KEEP worktrees/own/a "$DRAFTS/own/x/steps.md"
expect "$O" KEEP .t3/worktrees/own/t3-land "$GATES/gates.md"
# A file or folder under agent-drafts the job may not read holds nothing,
# and the rest of the run goes on.
mkdir "$DRAFTS/locked"; echo "cd ~/worktrees/own/a-2" >"$DRAFTS/locked/s.md"
chmod 000 "$DRAFTS/own/x/steps.md" "$DRAFTS/locked"
O="$T/t-steps-unread.out"; sweep
says "$O" KEEP t3/own/t3-land
says "$O" WOULD own/a oth/b pla/c lon/d own/gone co/cl own/a-2 own/old
chk "steps that can't be read are flagged once" "[ \"\$(grep -c 'pending steps' '$ATT')\" = 1 ]"
chk "that line says how many were skipped" "grep -q 'pending steps in 2 path(s) under ~/agent-drafts' '$ATT'"
chmod 644 "$DRAFTS/own/x/steps.md"; chmod 700 "$DRAFTS/locked"; rm -r -- "$DRAFTS/locked"
# Any other step file that can't be read still keeps everything.
chmod 000 "$GATES/gates.md"
O="$T/t-gates-unread.out"; sweep
says "$O" KEEP $LANDED own/old own/gone co/cl
chk "and is flagged once" "[ \"\$(grep -c 'pending steps can.t be read' '$ATT')\" = 1 ]"
chmod 644 "$GATES/gates.md"
rm -r -- "$DRAFTS/own" "$GATES/gates.md"

echo "-- T3 that cannot answer"
thread f1 pown false "$(date +%s)" Failing "nothing named"
echo down >"$T/t3-mode"
O="$T/t-down.out"; sweep
says "$O" KEEP $LANDED own/old own/gone co/cl
chk "a T3 that is down is one attention line, however many it keeps" "[ \"\$(grep -c \"T3's state is unknown\" '$ATT')\" = 1 ] && ! grep -q '| kept, idle' '$ATT'"
# The decision is one; each way to fail needs only a worktree to keep.
for mode in badlist empty notarray nofield nodate slow showdown badshow nomessages slowshow; do
  echo "$mode" >"$T/t3-mode"
  O="$T/t-$mode.out"
  WORKTREE_TTL_T3_TIMEOUT=1 /bin/bash "$JOB" --dry-run --landed-days 1 --root "$W/oth" >"$O" 2>&1
  says "$O" KEEP oth/b
  chk "$mode: one attention line says T3's state is unknown" "[ \"\$(grep -c \"T3's state is unknown\" '$ATT')\" = 1 ]"
  case $mode in slow*) chk "$mode: it says t3 timed out" "grep -q 't3 timed out after 1s' '$ATT'" ;; esac
done
rm "$T/t3-mode"
rm "$HOME/.local/bin/t3"; mkdir "$HOME/.t3/userdata"; chmod 000 "$HOME/.t3/userdata"
O="$T/t-nocli.out"; sweep
chmod 700 "$HOME/.t3/userdata"; rmdir "$HOME/.t3/userdata"
says "$O" KEEP $LANDED
ln -s "$T/bin/t3" "$HOME/.local/bin/t3"
echo down >"$T/t3-mode"; : >"$T/t3-calls.log"
/bin/bash "$JOB" --check "$W/own/a" >/dev/null 2>&1
chk "--check is unchanged: exit 0, and T3 is not asked" "[ $? -eq 0 ] && [ ! -s '$T/t3-calls.log' ]"
rm "$T/t3-mode"

echo "-- a real run"
threads; thread r1 poth false "$(date +%s)" Holder "keep ~/worktrees/own/a-2"
/bin/bash "$JOB" --ttl-days 14 --landed-days 1 --keep-branches --root "$W" --root "$TW" >"$T/t-real.out" 2>&1
says "$T/t-real.out" REMOVED own/a own/slips own/inmain own/old own/gone co/cl t3/own/t3-land
says "$T/t-real.out" KEEP own/a-2 own/pushed
chk "the held worktree is still there" "[ -f '$W/own/a-2/.git' ]"
chk "T3's worktree is gone and the clone beside it stays" "[ ! -e '$TW/own/t3-land' ] && [ -d '$TW/co/tc/.git' ]"
for b in fix/a planner/slips fix/inmain t3/land fix/old; do
  chk "branch $b is kept" "git -C '$R/own' rev-parse -q --verify refs/heads/$b >/dev/null"
done
chk "a removed worktree's branch can be checked out again" "git -C '$R/own' worktree add -q '$TW/own/t3-land' t3/land 2>/dev/null"

echo "-- the LaunchAgent"
PL="$T/worktree-ttl.plist"
(. "$REPO/tests/lib.sh" && sandbox agent-mini >/dev/null 2>&1 &&
  cz execute-template <"$REPO/home/private_Library/LaunchAgents/com.carlosetejada.worktree-ttl.plist.tmpl" >"$PL"
  cleanup_sandbox)
args=$(plutil -extract ProgramArguments json -o - "$PL" 2>/dev/null | /usr/bin/jq -r '.[1:] | join(" ")')
chk "the plist passes both limits, keeps branches and sweeps both roots" "[ '$args' = '$HOME/.local/bin/worktree-ttl --ttl-days 14 --landed-days 1 --keep-branches --root $W --root $TW' ]"

echo "== what the reviews found"
# Cases of their own under ~/wx, swept alone.
X="$HOME/wx"
xs() { # output action case...
  local f=$1 act=$2 c
  shift 2
  for c in "$@"; do expect "$f" "$act" "wx/$c" ""; done
}
xsweep() { /bin/bash "$JOB" --dry-run --ttl-days 14 --landed-days 1 --keep-branches --root "$X" >"$O" 2>&1; }
ign() { # path branch pr-number days ignored-file...
  local p=$1 b=$2 n=$3 d=$4 f
  shift 4
  addwt "$R/own" "$p" "$b"
  printf 'notes/\nnode_modules/\n*.sqlite\n.env.local\n' >"$p/.gitignore"
  work "$p" "i$n"; pushwt "$p"; pr test/own "$b" "$n" MERGED "$(tip "$p")"
  for f in "$@"; do mkdir -p "$(dirname -- "$p/$f")"; echo x >"$p/$f"; done
  age "$p" "$d"
}
ign "$X/own/notes" fix/x-notes 801 2 notes/todo.md node_modules/p/i.js
ign "$X/own/dotenv" fix/x-env 802 2 .env.local
ign "$X/own/db" fix/x-db 803 2 data.sqlite
ign "$X/own/cache" fix/x-cache 804 2 node_modules/p/i.js .DS_Store
ign "$X/own/oldnotes" fix/x-oldnotes 805 20 notes/todo.md
# An unchanged copy of the main checkout's own CLAUDE.md, as the hook makes.
echo "notes for agents" >"$R/own/CLAUDE.md"
ign "$X/own/seeded" fix/x-seeded 806 2
cp "$R/own/CLAUDE.md" "$X/own/seeded/CLAUDE.md"; age "$X/own/seeded" 2
for c in bound bound-2 onbr near h1 h2 h3 s1 s2 s3 s4 late1; do landed "$R/own" "$X/own/$c" "fix/x-$c" own "8${#c}$RANDOM" 2; done
landed "$R/oth" "$X/oth/onbr" fix/x-onbr oth 814 2
landed "$R/oth" "$X/oth/late2" fix/x-late2 oth 815 2
landed "$R/own" "$X/own/sp ace" fix/x-space own 831 2
landed "$R/own" "$X/own/q uote" fix/x-quote own 832 2
landed "$T/lone" "$X/lon/e" fix/x-e lon 851 2
landed "$T/lone" "$X/lon/f" fix/x-f lon 852 2
# Never pushed, and inside two merged PRs of other branches.
addwt "$R/own" "$X/own/multi" planner/x-multi; work "$X/own/multi" multi
for n in 821 822; do
  git -C "$R/own" worktree add -q --no-track -b "planner/x-m$n" "$T/m$n" planner/x-multi 2>/dev/null
  work "$T/m$n" "m$n"; pushwt "$T/m$n"
  pr test/own "planner/x-m$n" "$n" MERGED "$(tip "$T/m$n")"
  git -C "$R/own" worktree remove "$T/m$n"
  git --git-dir="$T/remote/own.git" branch -q -D "planner/x-m$n"
done
git -C "$R/own" fetch -q --prune; age "$X/own/multi" 2
# Last, since it moves main: merged with its own commit in main.
addwt "$R/own" "$X/own/inmain" fix/x-inmain; work "$X/own/inmain" xinmain; pushwt "$X/own/inmain"
git -C "$X/own/inmain" push -q origin HEAD:main 2>/dev/null
pr test/own fix/x-inmain 841 MERGED "$(tip "$X/own/inmain")"
git -C "$R/own" fetch -q; age "$X/own/inmain" 2
now=$(date +%s)

echo "-- landed work keeps ignored files that are no cache to the TTL"
threads
O="$T/x-ignored.out"; xsweep
expect "$O" KEEP wx/own/notes "its work landed, but it holds notes/todo.md, an ignored file that is no cache, so it stays to the 14d TTL"
expect "$O" KEEP wx/own/dotenv "holds .env.local"
expect "$O" KEEP wx/own/db "holds data.sqlite"
xs "$O" WOULD own/cache own/oldnotes own/seeded

echo "-- a thread bound to a worktree or its branch holds it"
thread b1 poth false "$now" Bound "nothing named" "{\"worktreePath\": \"$X/own/../own/bound\", \"branch\": null}"
thread b2 pown false "$now" "On branch" "nothing named" '{"worktreePath": null, "branch": "fix/x-onbr"}'
thread b3 poth false "$now" Elsewhere "nothing named" '{"branch": "fix/x-near"}'
O="$T/x-bound.out"; xsweep
expect "$O" KEEP wx/own/bound 'open T3 thread "Bound" holds it (it runs there)'
expect "$O" KEEP wx/own/onbr 'open T3 thread "On branch" holds it (it is on its branch)'
xs "$O" WOULD own/bound-2 oth/onbr own/near own/cache
for bad in '{"worktreePath": 5}' '{"branch": ["fix/x-near"]}'; do
  threads; thread b4 pown false "$now" Odd "nothing named" "$bad"
  O="$T/x-badbound.out"; xsweep
  expect "$O" KEEP wx/own/cache "T3's state is unknown"
done

echo "-- message text that is null is empty text"
threads; thread m0 pown false "$now" Plain "nothing named"
for mode in nulltext numtext; do
  echo "$mode" >"$T/t3-mode"
  O="$T/x-$mode.out"; xsweep
  case $mode in
    nulltext) xs "$O" WOULD own/cache ;;
    numtext) expect "$O" KEEP wx/own/cache "T3's state is unknown" ;;
  esac
done
rm "$T/t3-mode"

echo "-- holds are read again right before a removal"
threads; thread l1 poth false "$now" Late "now see ~/wx/own/late1"
mv "$T/threads.jsonl" "$T/late.jsonl"; threads
mkdir -p "$DRAFTS/late"
printf 'cat %q >>%q\necho "cd ~/wx/oth/late2" >%q\n' "$T/late.jsonl" "$T/threads.jsonl" "$DRAFTS/late/steps.md" >"$T/gh-hook"
O="$T/x-late.out"; WORKTREE_TTL_HOLD_MAX_AGE=0 xsweep
chk "the thread and the step appeared during the PR lookups" "[ -e '$T/gh-hook.ran' ] && [ ! -e '$T/gh-hook' ]"
expect "$O" KEEP wx/own/late1 'open T3 thread "Late"'
expect "$O" KEEP wx/oth/late2 "$DRAFTS/late/steps.md"
: >"$T/t3-calls.log"; O="$T/x-once.out"; xsweep
chk "holds younger than 5 minutes are not read again" "[ \"\$(grep -c 'thread list --project $R/own --json' '$T/t3-calls.log')\" = 1 ]"
rm -r -- "$DRAFTS/late"

echo "-- every merged PR GitHub links to the tip counts"
threads; thread p2 poth false "$now" "Second PR" "see https://github.com/test/own/pull/822"
O="$T/x-multi.out"; xsweep
expect "$O" KEEP wx/own/multi 'open T3 thread "Second PR"'
threads; thread p3 poth false "$now" "No PR" "see https://github.com/test/own/pull/823"
O="$T/x-multi2.out"; xsweep
expect "$O" WOULD wx/own/multi "PR test/own#821 merged under another branch's name"

echo "-- cd steps with escaped or quoted spaces, and other Markdown names"
threads
mkdir -p "$DRAFTS/x"
# shellcheck disable=SC2016  # the steps say $HOME, as a person writes it
printf '%s\n' 'cd ~/wx/own/sp\ ace && make' 'cd "$HOME/wx/own/q uote"' >"$DRAFTS/x/steps.md"
echo "cd ~/wx/own/s1" >"$DRAFTS/x/UP.MD"
echo "cd ~/wx/own/s2" >"$DRAFTS/x/plan.markdown"
echo "cd ~/wx/own/s3" >"$DRAFTS/x/Notes.Markdown"
echo "cd ~/wx/own/s4" >"$DRAFTS/x/notes.txt"
O="$T/x-steps.out"; xsweep
expect "$O" KEEP "wx/own/sp ace" "$DRAFTS/x/steps.md"
expect "$O" KEEP "wx/own/q uote" "$DRAFTS/x/steps.md"
expect "$O" KEEP wx/own/s1 "$DRAFTS/x/UP.MD"
expect "$O" KEEP wx/own/s2 "$DRAFTS/x/plan.markdown"
expect "$O" KEEP wx/own/s3 "$DRAFTS/x/Notes.Markdown"
xs "$O" WOULD own/s4
rm -r -- "$DRAFTS/x"

echo "-- thread text that names \$HOME"
# shellcheck disable=SC2016  # literal, as threads write it
threads; thread h0 poth false "$now" Home 'cd $HOME/wx/own/h1, then ${HOME}/wx/own/h2'
O="$T/x-home.out"; xsweep
expect "$O" KEEP wx/own/h1 'open T3 thread "Home"'
expect "$O" KEEP wx/own/h2 'open T3 thread "Home"'
xs "$O" WOULD own/h3

echo "-- a 404 for a tip in the default branch is unknown"
threads; thread d1 poth false "$now" Asks "see github.com/test/own/pull/1"
echo "gh: Not Found (HTTP 404)" >"$T/gh-commit-fail"
O="$T/x-404.out"; xsweep
rm "$T/gh-commit-fail"
expect "$O" KEEP wx/own/inmain "PR state unknown (gh: Not Found (HTTP 404))"

echo "-- the label for a repo in no T3 project"
threads
thread o1 poth false "$(ago 3)" Old "nothing named"
thread o2 poth false "$(ago 3)" Namer2 "see ~/wx/lon/e"
O="$T/x-nohome.out"; xsweep
expect "$O" KEEP wx/lon/e 'open T3 thread "Namer2" holds it (it names its path, branch or PR)'
expect "$O" KEEP wx/lon/f 'its repo is in no T3 project, and open thread "Old" started before its last use'

echo
echo "passed=$PASS failed=$FAILS"
[ "$FAILS" -eq 0 ]
