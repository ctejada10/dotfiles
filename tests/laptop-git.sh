#!/usr/bin/env bash
# The laptop's git in the repos the mini's agents own: the wrapper in
# ~/.local/bin lets reads through and refuses writes before Git starts, the
# config behind it stops the real git from fetching or pushing, and nothing a
# read does changes the .git that Dropbox shares with the mini. Repos that
# aren't the mini's are left alone. HOME is a throwaway folder.
#
#   bash tests/laptop-git.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

if [ "$(uname)" != Darwin ]; then
  echo "laptop-git: the laptop is a Mac; nothing to check here"
  exit 0
fi

real=
for candidate in /opt/homebrew/bin/git /usr/bin/git; do
  if [ -x "$candidate" ]; then real=$candidate; break; fi
done
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OPTIONAL_LOCKS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
# Git with no config at all, for making and inspecting the stand-in repos.
bare() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real" "$@"; }

# A stand-in Dropbox folder with one repo the mini owns and one it doesn't.
# Real paths, because Git matches includeIf against the resolved .git path.
box="$(cd "$(mktemp -d)" && pwd -P)"
bare -C "$box" init -q -b main agentrepo
bare -C "$box" init -q -b main laptoprepo
(
  cd "$box/agentrepo" || exit 1
  # other has no a.txt, so a switch to it would delete the file. b.txt stays
  # unchanged when a test changes a.txt.
  bare -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  bare branch other
  echo a > a.txt
  echo b > b.txt
  bare add a.txt b.txt
  bare -c user.name=t -c user.email=t@t commit -q -m a
  bare tag v1
  bare -c user.name=t -c user.email=t@t notes add -m note HEAD
  bare remote add origin https://github.com/x/agentrepo.git
  echo u > untracked.txt
)
bare -C "$box/laptoprepo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
bare -C "$box/laptoprepo" remote add origin https://github.com/x/laptoprepo.git
# A repo of the mini's with a submodule, as rivendell has arwen.
bare init -q -b main "$box/subseed"
bare -C "$box/subseed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
bare init -q -b main "$box/agentsuper"
bare -C "$box/agentsuper" -c protocol.file.allow=always submodule add -q "$box/subseed" sub 2>/dev/null
bare -C "$box/agentsuper" -c user.name=t -c user.email=t@t commit -q -m sub
# A repo of the mini's with a Git LFS file it hasn't pulled, whose own config
# holds the version the mini's git-lfs writes there the first time it runs.
bare init -q -b main "$box/agentlfs"
(
  cd "$box/agentlfs" || exit 1
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 4\n' "$(printf data | shasum -a 256 | cut -d' ' -f1)" > model.bin
  echo m > notes.txt
  bare add .gitattributes model.bin notes.txt
  bare -c user.name=t -c user.email=t@t commit -q -m lfs
  bare config lfs.repositoryformatversion 0
)
override="{\"dropboxRepositories\": \"$box\", \"repos\": {\"laptop\": {}, \"agent-mini\": {\"agentrepo\": \"x/agentrepo\", \"agentsuper\": \"x/agentsuper\", \"agentlfs\": \"x/agentlfs\"}}}"
sandbox laptop arnor arnor >/dev/null 2>&1
cz --override-data "$override" apply --exclude=scripts,externals >/dev/null 2>&1
cp -Rp "$box/agentrepo" "$SANDBOX/agentrepo.pristine"
cp -Rp "$box/agentsuper" "$SANDBOX/agentsuper.pristine"
cp -Rp "$box/agentlfs" "$SANDBOX/agentlfs.pristine"
mkdir -p "$SANDBOX/tmp"
export HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1 TMPDIR="$SANDBOX/tmp"
export PATH="$HOME/.local/bin:$PATH"
wrapper="$HOME/.local/bin/git"
repo="$box/agentrepo"

# fresh: the mini's repo as Dropbox brings it down: same contents and mtimes,
# new inodes, so Git sees every tracked file as possibly changed.
fresh() { rm -rf "$repo"; cp -Rp "$SANDBOX/agentrepo.pristine" "$repo"; }
# state: everything in the mini's .git and the names in its working tree.
state() { (cd "$repo" && { ls -A; find .git -type f | sort | xargs md5 -r; } | md5 -q); }
# The wrapper's refusal. The hook's says "read-only on this Mac" instead.
refused="so this Mac only reads it"

section "the wrapper"
if [ -x "$wrapper" ] && head -n 1 "$wrapper" | grep -qx '#!/bin/bash'; then pass "is rendered for the laptop"; else fail "is rendered for the laptop"; fi
if out=$(/bin/bash -n "$wrapper" 2>&1); then pass "parses with /bin/bash"; else fail "parses with /bin/bash" "$out"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if out=$(shellcheck -S warning -s bash "$wrapper" 2>&1); then pass "is shellcheck-clean"; else fail "is shellcheck-clean" "$out"; fi
fi

section "reads in the mini's repo go through"
fresh
before=$(state)
for cmd in "status --short" "status --porcelain" "rev-parse --abbrev-ref HEAD" "log --oneline -1" "show --stat" \
           "diff" "diff --stat" "diff --name-only" "branch" "branch -a" "branch -av" "branch --contains HEAD" \
           "branch --merged main" "branch --list ma*" "branch --sort=-committerdate" "tag" "tag -l v*" \
           "tag --points-at HEAD" "describe --tags" "describe --tags --dirty" "symbolic-ref --quiet HEAD" \
           "symbolic-ref --short HEAD" "config --get core.fsmonitor" "config get user.name" "config list" \
           "config core.bare" "config --get-regexp ^remote\." "config --type=bool core.bare" "remote" "remote -v" \
           "remote --verbose" "remote get-url origin" "remote -v show -n origin" "stash list" "worktree list" \
           "reflog" "reflog show -1" "ls-files" "grep -n a" "blame a.txt" \
           "stat" "last" "graph -1" "cached" "difftool -y -x true" \
           "diff-tree --no-commit-id --name-only -r HEAD" "diff-index --cached --quiet HEAD" "diff-files --name-only" \
           "diff-files --quiet" "diff-index --quiet HEAD --" "diff-index --name-only HEAD" \
           "branch -va" "branch -vr" "branch -ar" "branch -vva" "branch -la" "branch -al ma*" "branch -i" \
           "tag -ln" "tag -ln5" "tag -n5 -l" "tag -li v*" "tag -n" \
           "fsck --no-progress" "fsck" "notes" "notes list" "notes show HEAD" "notes --ref=commits show HEAD" \
           "submodule" "submodule status" "submodule --quiet summary"; do
  # shellcheck disable=SC2086
  out=$(cd "$repo" && git $cmd 2>&1) && pass "git $cmd" || fail "git $cmd" "$out"
done
after=$(state)
[ "$before" = "$after" ] && pass "and none of them changed the .git or the working tree" || fail "and none of them changed the .git or the working tree"

section "writes in the mini's repo are refused before Git starts"
for cmd in "switch -q other" "reset --hard" "rebase other" "stash" "fetch" "pull" "push" "checkout -b x" \
           "branch -D other" "branch newname" "branch -v newname" "branch --sort=x newname" "tag v2" \
           "branch -vD other" "branch -avm other renamed" "branch -af newname" "branch -lc other copy" \
           "tag -a -m x v2" "tag -ld v1" "tag -nl v1" "tag -ln5a v2" "tag -fa -m x v2" \
           "add ." "restore ." "clean -fq" "commit --allow-empty -m x" \
           "remote add evil https://example.com/x.git" "remote -v add evil https://example.com/x.git" \
           "remote -v set-url origin file:///tmp/x" "remote --verbose remove origin" "remote -v rename origin upstream" \
           "config test.key v" "config --null test.key v" "config -z test.key v" "config --includes test.key v" \
           "config --show-scope test.key v" "config --show-origin test.key v" "config --type=path core.hooksPath /dev/null" \
           "config set test.key v" "config --add test.key v" "config --remove-s remote.origin" \
           "config --unset-a remote.origin.url" "config --get core.bare --unset core.bare" "config edit" \
           "reflog expire --expire=now --all" "reflog delete HEAD@{0}" "reflog drop --all" "reflog write HEAD x y z" \
           "symbolic-ref HEAD refs/heads/other" "symbolic-ref -d HEAD" "symbolic-ref --del HEAD" \
           "symbolic-ref -m x HEAD refs/heads/other" "unstage a.txt" "cleanup" "stauts" \
           "fsck --lost-found" "fsck --lost" "submodule update --init" "submodule foreach true" \
           "submodule sync" "notes add -f -m x HEAD" "notes --ref=x add -m y HEAD" "notes remove HEAD" \
           "lfs pull" "lfs install" "lfs status"; do
  fresh
  before=$(state)
  # shellcheck disable=SC2086
  out=$(cd "$repo" && git $cmd 2>&1); rc=$?
  after=$(state)
  [ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ "$before" = "$after" ] \
    && pass "git $cmd" || fail "git $cmd" "rc=$rc; $out"
done

section "an alias is checked as what it runs"
fresh
before=$(state)
expect_alias() {
  local want="$1" name="$2"; shift 2
  out=$(cd "$repo" && git "$@" 2>&1); rc=$?
  case "$want" in
    allowed) [ $rc -eq 0 ] && pass "$name" || fail "$name" "$out" ;;
    refused) [ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && pass "$name" || fail "$name" "rc=$rc; $out" ;;
  esac
}
expect_alias allowed "an alias for a read" -c 'alias.st=status -s' st
expect_alias allowed "an alias for an alias for a read" -c 'alias.st=status -s' -c 'alias.s2=st' s2
expect_alias refused "an alias for a write" -c 'alias.rx=reflog expire --expire=now --all' rx
expect_alias refused "a quoted write" -c 'alias.rx=reflog "expire" --expire=now --all' rx
expect_alias refused "an alias that starts with an option" -c 'alias.dx=-c diff.autoRefreshIndex=true diff' dx
expect_alias refused "an alias that runs a shell command" -c 'alias.sh=!rm a.txt' sh
expect_alias refused "an alias named after a command, which Git runs instead" -c 'alias.commit=status' commit --allow-empty -m x
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\ntouch a.txt.new\n' > "$SANDBOX/bin/git-zz"
chmod +x "$SANDBOX/bin/git-zz"
out=$(cd "$repo" && PATH="$SANDBOX/bin:$PATH" git -c 'alias.zz=status' zz 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && pass "an alias a git-zz on PATH shadows" || fail "an alias a git-zz on PATH shadows" "rc=$rc; $out"
expect_alias refused "a loop of aliases" -c 'alias.l1=l2' -c 'alias.l2=l1' l1
after=$(state)
[ "$before" = "$after" ] && pass "and none of them changed the .git or the working tree" || fail "and none of them changed the .git or the working tree"

section "reads leave the shared index as it is"
# A checkout Dropbox brought down: every file looks changed to Git until it
# compares contents, and the reads that do that would write the index back.
for cmd in "diff" "diff --name-only" "describe --tags --dirty" "describe --tags --di" "describe --tags --b" \
           "cached" "difftool -y -x true" "status --porcelain" "diff-files --quiet" "diff-index --quiet HEAD --"; do
  fresh
  index=$(md5 -q "$repo/.git/index")
  # shellcheck disable=SC2086
  out=$(cd "$repo" && git $cmd 2>&1); rc=$?
  [ $rc -eq 0 ] && [ "$(md5 -q "$repo/.git/index")" = "$index" ] && pass "git $cmd" || fail "git $cmd" "rc=$rc; $out"
done
fresh
out=$(cd "$repo" && git diff --name-only 2>&1)
[ -z "$out" ] && pass "git diff --name-only lists nothing for an unchanged checkout" || fail "git diff --name-only lists nothing for an unchanged checkout" "$out"
out=$(cd "$repo" && git describe --tags --dirty 2>&1)
[ "$out" = v1 ] && pass "git describe --dirty still answers" || fail "git describe --dirty still answers" "$out"
# The diff- plumbing never refreshes the index, so it gets a refreshed copy.
for cmd in "diff-files --name-only" "diff-index --name-only HEAD"; do
  # shellcheck disable=SC2086
  out=$(cd "$repo" && git $cmd 2>&1)
  [ -z "$out" ] && pass "git $cmd lists nothing for an unchanged checkout" || fail "git $cmd lists nothing for an unchanged checkout" "$out"
done
out=$(cd "$repo" && git diff-index --quiet HEAD -- 2>&1) && pass "git diff-index --quiet HEAD -- calls it clean" || fail "git diff-index --quiet HEAD -- calls it clean" "$out"
out=$(cd "$HOME" && git -C "$repo" diff-files --name-only 2>&1)
[ -z "$out" ] && pass "and through -C" || fail "and through -C" "$out"
echo b >> "$repo/a.txt"
mkdir "$repo/sub"
for place in "$repo" "$repo/sub"; do
  out=$(cd "$place" && git diff --name-only 2>&1)
  [ "$out" = a.txt ] && pass "git diff still sees a real change, from ${place#"$box"/}" || fail "git diff still sees a real change, from ${place#"$box"/}" "$out"
done
out=$(cd "$HOME" && git -C "$repo/sub" diff --name-only 2>&1)
[ "$out" = a.txt ] && pass "and through -C" || fail "and through -C" "$out"
out=$(cd "$repo/sub" && git describe --tags --dirty 2>&1)
[ "$out" = v1-dirty ] && pass "and so does git describe --dirty" || fail "and so does git describe --dirty" "$out"
for cmd in "diff-files --name-only" "diff-index --name-only HEAD"; do
  # shellcheck disable=SC2086
  out=$(cd "$repo/sub" && git $cmd 2>&1)
  [ "$out" = a.txt ] && pass "and so does git $cmd" || fail "and so does git $cmd" "$out"
done
out=$(cd "$repo" && git diff-index --quiet HEAD -- 2>&1); rc=$?
[ $rc -eq 1 ] && pass "and git diff-index --quiet HEAD -- calls it dirty" || fail "and git diff-index --quiet HEAD -- calls it dirty" "rc=$rc; $out"
[ -z "$(ls -A "$TMPDIR")" ] && pass "the index copies are cleaned up" || fail "the index copies are cleaned up" "$(ls -A "$TMPDIR")"
for cmd in "diff" "difftool -y -x true"; do
  fresh
  index=$(md5 -q "$repo/.git/index")
  # shellcheck disable=SC2086
  out=$(cd "$repo" && "$real" $cmd 2>&1); rc=$?
  [ $rc -eq 0 ] && [ "$(md5 -q "$repo/.git/index")" = "$index" ] && pass "the real git: $cmd" || fail "the real git: $cmd" "rc=$rc; $out"
done

section "listing a submodule leaves the mini's repo as it is"
super="$box/agentsuper"
super_state() { (cd "$super" && { ls -A . sub; find .git -type f | sort | xargs md5 -r; } | md5 -q); }
for cmd in "submodule" "submodule status" "submodule status --recursive" "submodule summary"; do
  rm -rf "$super"; cp -Rp "$SANDBOX/agentsuper.pristine" "$super"
  before=$(super_state)
  # shellcheck disable=SC2086
  out=$(cd "$super" && git $cmd 2>&1); rc=$?
  [ $rc -eq 0 ] && [ "$before" = "$(super_state)" ] && pass "git $cmd" || fail "git $cmd" "rc=$rc; $out"
done
for cmd in "submodule update --init" "submodule deinit -f sub" "submodule absorbgitdirs"; do
  rm -rf "$super"; cp -Rp "$SANDBOX/agentsuper.pristine" "$super"
  before=$(super_state)
  # shellcheck disable=SC2086
  out=$(cd "$super" && git $cmd 2>&1); rc=$?
  [ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ "$before" = "$(super_state)" ] \
    && pass "git $cmd is refused" || fail "git $cmd is refused" "rc=$rc; $out"
done
if "$real" lfs version >/dev/null 2>&1; then
  # Brought down by Dropbox, every file looks changed, so a status hashes the
  # LFS file through git-lfs, which writes into its storage folder. Folders
  # count too: git-lfs makes .git/lfs and .git/lfs/tmp.
  lfs="$box/agentlfs"
  lfs_state() { (cd "$lfs" && { ls -A; find .git | sort; find .git -type f | sort | xargs md5 -r; } | md5 -q); }
  for cmd in "lfs ls-files" "status" "status --porcelain" "diff" "diff --stat" "describe --always --dirty"; do
    rm -rf "$lfs"; cp -Rp "$SANDBOX/agentlfs.pristine" "$lfs"
    before=$(lfs_state)
    # shellcheck disable=SC2086
    out=$(cd "$lfs" && git $cmd 2>&1); rc=$?
    [ $rc -eq 0 ] && [ "$before" = "$(lfs_state)" ] && pass "git $cmd in a repo with an LFS file changes nothing in it" \
      || fail "git $cmd in a repo with an LFS file changes nothing in it" "rc=$rc; $out; $(cd "$lfs" && find .git/lfs 2>/dev/null | tr "\n" " ")"
  done
  rm -rf "$lfs"; cp -Rp "$SANDBOX/agentlfs.pristine" "$lfs"
  out=$(cd "$lfs" && git status --porcelain 2>&1)
  [ -z "$out" ] && pass "and git status sees the unpulled LFS file as unchanged" || fail "and git status sees the unpulled LFS file as unchanged" "$out"
  out=$(cd "$lfs" && git lfs ls-files 2>&1)
  grep -q 'model.bin' <<< "$out" && pass "git lfs ls-files lists the LFS file" || fail "git lfs ls-files lists the LFS file" "$out"
  # Where the mini's git-lfs never ran, git-lfs would write its version into
  # the repo's .git/config, so ls-files waits for the mini there.
  fresh
  before=$(state)
  out=$(cd "$repo" && git lfs ls-files 2>&1); rc=$?
  [ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ "$before" = "$(state)" ] \
    && pass "git lfs ls-files is refused where git-lfs would write .git/config" || fail "git lfs ls-files is refused where git-lfs would write .git/config" "rc=$rc; $out"
else
  printf '  skip  %s\n' "git lfs ls-files: Git LFS is not installed"
fi

section "--git-dir, --work-tree and Git's environment"
fresh
out=$(cd "$HOME" && git --git-dir="$repo/.git" --work-tree="$repo" switch -q other 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ -f "$repo/a.txt" ] && pass "git --git-dir=... --work-tree=... switch is refused" || fail "git --git-dir=... --work-tree=... switch is refused" "$out"
out=$(cd "$HOME" && git --git-dir "$repo/.git" --work-tree "$repo" switch -q other 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ -f "$repo/a.txt" ] && pass "and with the values as separate words" || fail "and with the values as separate words" "$out"
out=$(cd "$box" && git --git-dir=agentrepo/.git --work-tree=agentrepo switch -q other 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ -f "$repo/a.txt" ] && pass "and with relative paths" || fail "and with relative paths" "$out"
out=$(cd "$HOME" && GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" git clean -fq 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ -f "$repo/untracked.txt" ] && pass "GIT_DIR=... GIT_WORK_TREE=... git clean is refused" || fail "GIT_DIR=... GIT_WORK_TREE=... git clean is refused" "$out"
out=$(cd "$HOME" && GIT_DIR="$repo/.git" git log --oneline -1 2>&1) && pass "GIT_DIR=... git log goes through" || fail "GIT_DIR=... git log goes through" "$out"
out=$(cd "$HOME" && git --git-dir="$repo/.git" log --oneline -1 2>&1) && pass "git --git-dir=... log goes through" || fail "git --git-dir=... log goes through" "$out"
out=$(cd "$HOME" && git --git-dir="$box/laptoprepo/.git" --work-tree="$box/laptoprepo" -c commit.gpgsign=false commit -q --allow-empty -m test 2>&1) \
  && pass "git --git-dir=... commit in the laptop's own repo goes through" || fail "git --git-dir=... commit in the laptop's own repo goes through" "$out"

section "a differently cased path into the mini's repo"
upper="${box%/*}/$(basename "$box" | tr '[:lower:]' '[:upper:]')/AgentRepo"
if [ -d "$upper" ]; then
  for place in "$upper" "$HOME/SRC/AgentRepo"; do
    fresh
    out=$(cd "$place" && git switch -q other 2>&1); rc=$?
    case "$place" in "$HOME"/*) name="the home folder's ${place#"$HOME"/}" ;; *) name="the Dropbox folder, cased differently" ;; esac
    [ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ -f "$repo/a.txt" ] \
      && pass "git switch from $name is refused" || fail "git switch from $name is refused" "$out"
  done
  fresh
  out=$(git -C "$upper" switch -q other 2>&1); rc=$?
  [ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ -f "$repo/a.txt" ] && pass "git -C <mis-cased path> switch is refused" || fail "git -C <mis-cased path> switch is refused" "$out"
  before=$(state)
  out=$(cd "$HOME" && git --git-dir="$upper/.git" --work-tree="$upper" -c commit.gpgsign=false commit -q --allow-empty -m test 2>&1); rc=$?
  [ $rc -ne 0 ] && grep -q "$refused" <<< "$out" && [ "$before" = "$(state)" ] \
    && pass "git --git-dir=<mis-cased path> commit is refused" || fail "git --git-dir=<mis-cased path> commit is refused" "$out"
  hook="$HOME/.claude/hooks/guard-paths.sh"
  printf '{"tool_input":{"file_path":"%s/a.txt"}}' "$upper" | "$hook" >/dev/null 2>&1
  [ $? -eq 2 ] && pass "Claude Code can't edit it through a mis-cased path" || fail "Claude Code can't edit it through a mis-cased path"
else
  printf '  skip  %s\n' "this volume is case-sensitive"
fi

section "gh finds the mini's repo on GitHub"
if command -v gh >/dev/null 2>&1; then
  # No network: every API call goes to a dead proxy, so reaching it means gh
  # found the repo and the current branch.
  ghrun() {
    (cd "$repo" && env -u GH_HOST -u GH_REPO -u GH_ENTERPRISE_TOKEN -u NO_PROXY -u no_proxy GH_TOKEN=dummy \
      GH_CONFIG_DIR="$SANDBOX/gh" HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
      GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 gh "$@" 2>&1)
  }
  fresh
  before=$(state)
  for cmd in "pr list" "pr view" "pr view 1" "pr checks" "pr status"; do
    # shellcheck disable=SC2086
    out=$(ghrun $cmd)
    grep -q '127.0.0.1:9' <<< "$out" && pass "gh $cmd gets as far as GitHub's API" || fail "gh $cmd gets as far as GitHub's API" "$out"
  done
  [ "$before" = "$(state)" ] && pass "and changes nothing in the .git" || fail "and changes nothing in the .git"
else
  printf '  skip  %s\n' "gh is not installed"
fi

section "the real git can't fetch or push in the mini's repo"
url=$(cd "$repo" && "$real" remote get-url origin)
[ "$url" = https://github.com/x/agentrepo.git ] && pass "the remote URL stays readable" || fail "the remote URL stays readable" "$url"
for cmd in "fetch origin" "pull origin main" "push origin main" "fetch $box/laptoprepo" "fetch file://$box/laptoprepo" "ls-remote origin"; do
  name=${cmd//$box/<Dropbox>}
  fresh
  objects=$(find "$repo/.git/objects" -type f | sort | xargs md5 -r | md5 -q)
  refs=$(bare -C "$repo" for-each-ref)
  # shellcheck disable=SC2086
  out=$(cd "$repo" && "$real" $cmd 2>&1); rc=$?
  [ $rc -ne 0 ] && grep -q "not allowed" <<< "$out" \
    && [ "$objects" = "$(find "$repo/.git/objects" -type f | sort | xargs md5 -r | md5 -q)" ] && [ "$refs" = "$(bare -C "$repo" for-each-ref)" ] \
    && pass "git $name stops before it connects" || fail "git $name stops before it connects" "rc=$rc; $out"
done
[ "$(cd "$repo" && "$real" config --get lfs.url)" = agent-repo-read-only-on-this-mac:// ] \
  && pass "Git LFS gets a URL it can't use" || fail "Git LFS gets a URL it can't use"

section "repos that aren't the mini's are plain git"
cd "$box/laptoprepo" || exit 1
out=$(git -c commit.gpgsign=false commit -q --allow-empty -m test 2>&1) && pass "git commit" || fail "git commit" "$out"
out=$(git branch topic 2>&1) && pass "git branch topic" || fail "git branch topic" "$out"
out=$(git config test.key v 2>&1) && pass "git config test.key v" || fail "git config test.key v" "$out"
out=$(git ls-remote "$box/laptoprepo" 2>&1) && pass "git ls-remote over a local path" || fail "git ls-remote over a local path" "$out"
[ -z "$("$real" config --get protocol.allow)" ] && pass "no protocol limit" || fail "no protocol limit"
[ -z "$("$real" config --get diff.autoRefreshIndex)" ] && pass "the index refreshes as usual" || fail "the index refreshes as usual"
elsewhere="$SANDBOX/elsewhere"
bare init -q "$elsewhere"
out=$(git -C "$elsewhere" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q --allow-empty -m test 2>&1) \
  && pass "git commit outside Dropbox" || fail "git commit outside Dropbox" "$out"
cd / || exit 1

cleanup_sandbox
rm -rf "$box"
summary
