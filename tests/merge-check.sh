#!/usr/bin/env bash
# The mini's merge check: runs it against a throwaway repo, a stand-in gh that
# serves canned JSON, and a throwaway home for the verdict file, and checks
# which PRs it calls safe.
#
#   bash tests/merge-check.sh

set -uo pipefail
. "$(dirname "$0")/lib.sh"

script="$REPO/home/dot_claude/hooks/executable_merge-check.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/merge-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fake="$work/fake"
mkdir -p "$work/bin" "$fake" "$work/home"

git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/repo" 2>/dev/null
git -C "$work/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$work/repo" push -q origin main
git -C "$work/repo" remote set-head origin main
git -C "$work/repo" switch -q -c feature
git -C "$work/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m work
head=$(git -C "$work/repo" rev-parse HEAD)
# wf: a branch whose head has a CI workflow.
git -C "$work/repo" switch -q -c wf
mkdir -p "$work/repo/.github/workflows" && echo 'on: push' > "$work/repo/.github/workflows/ci.yml"
git -C "$work/repo" add .github && git -C "$work/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m ci
wfhead=$(git -C "$work/repo" rev-parse HEAD)
git -C "$work/repo" switch -q feature

# The stand-in gh: pr view and api graphql print $fake/<name>.json, exit with
# $fake/<name>.status if it exists, and first sleep $fake/<name>.sleep seconds.
cat > "$work/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pr view") name=pr ;;
  "api graphql") name=graphql ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
[ -f "$FAKE_GH/$name.sleep" ] && sleep "$(cat "$FAKE_GH/$name.sleep")"
cat "$FAKE_GH/$name.json"
[ -f "$FAKE_GH/$name.status" ] && exit "$(cat "$FAKE_GH/$name.status")"
exit 0
EOF
chmod +x "$work/bin/gh"

verdict="$work/home/agent-drafts/scripts/feature/merge-verdict.txt"
# reset: a PR every check calls safe.
reset() {
  rm -f "$fake"/*.status "$fake"/*.sleep
  jq -n --arg h "$head" '{number: 12, url: "https://github.com/ctejada10/scripts/pull/12",
      headRefName: "feature", headRefOid: $h, baseRefName: "main", isCrossRepository: false,
      state: "OPEN", isDraft: false,
      files: [{path: "src/app.py"}], changedFiles: 1, reviewDecision: "APPROVED",
      statusCheckRollup: [{__typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "SUCCESS"},
                          {__typename: "StatusContext", context: "ci/legacy", state: "SUCCESS"}]}' > "$fake/pr.json"
  jq -n '{data: {repository: {mergeQueue: null,
      pullRequest: {reviewThreads: {nodes: [{isResolved: true}], pageInfo: {hasNextPage: false}}}}}}' > "$fake/graphql.json"
  mkdir -p "$(dirname "$verdict")"
  printf 'MERGE %s\nThe diff only renames a helper.\n' "$head" > "$verdict"
  git -C "$work/repo" switch -q feature 2>/dev/null
}
# pr <jq filter> and gql <jq filter>: change what gh serves.
pr() { jq "$1" "$fake/pr.json" > "$fake/t" && mv "$fake/t" "$fake/pr.json"; }
gql() { jq "$1" "$fake/graphql.json" > "$fake/t" && mv "$fake/t" "$fake/graphql.json"; }

# check <safe|unsafe> <label> <text the reasons include, or ""> [arguments after cwd]
check() {
  local want="$1" label="$2" says="${3:-}" out status got
  shift 2; [ $# -gt 0 ] && shift
  [ $# -gt 0 ] || set -- merge "$head"
  out=$(HOME="$work/home" PATH="$work/bin:$PATH" FAKE_GH="$fake" \
        /usr/bin/python3 -B "$script" "$work/repo" "$@" 2>&1)
  status=$?
  case "$status" in 0) got=safe ;; 2) got=unsafe ;; *) got="exit $status" ;; esac
  if [ "$got" != "$want" ]; then
    fail "$want: $label" "got $got: $out"
  elif [ -n "$says" ] && ! grep -qF -- "$says" <<< "$out"; then
    fail "$want: $label: says $says" "$out"
  else
    pass "$want: $label"
  fi
}

section "a PR that passes every check"
reset; check safe "checks green, threads resolved, verdict on this head"
reset; check safe "the head named by a short SHA" "" merge "${head:0:7}"
reset; check safe "readying it, which names no SHA" "" ready ""
reset; check safe "a PR the grant names" "" merge "$head" 9 12

section "the branch"
reset; git -C "$work/repo" switch -q main
check unsafe "on the default branch" "default branch"
reset; git -C "$work/repo" switch -q --detach feature
check unsafe "a detached HEAD" "detached"
reset; pr '.headRefName = "other"'; check unsafe "a PR for another branch" "other"
reset; pr '.headRefName = "other"'; check unsafe "a PR for another branch says the names must match" "same name as the PR's branch"
reset; pr '.isCrossRepository = true'; check unsafe "a PR from a fork" "fork"
reset; pr '.baseRefName = "release"'; check unsafe "a PR into another base" "release"
git init -q -b master "$work/plain"
git -C "$work/plain" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$work/plain" switch -q -c feature
plainhead=$(git -C "$work/plain" rev-parse HEAD)
reset; pr ".headRefOid = \"$plainhead\" | .baseRefName = \"master\""
printf 'MERGE %s\n' "$plainhead" > "$verdict"
out=$(HOME="$work/home" PATH="$work/bin:$PATH" FAKE_GH="$fake" /usr/bin/python3 -B "$script" "$work/plain" merge "$plainhead" 2>&1) \
  && pass "safe: no origin, so main or master is the default" || fail "safe: no origin, so main or master is the default" "$out"

section "the PR's state"
reset; pr '.state = "MERGED"'; check unsafe "a PR already merged" "MERGED"
reset; pr '.state = "CLOSED"'; check unsafe "a closed PR" "CLOSED"
reset; pr '.isDraft = true'; check unsafe "merging a draft" "Mark it ready with gh pr ready in an earlier command first"
reset; pr '.isDraft = true'; check safe "readying a draft" "" ready ""
reset; pr 'del(.isDraft)'; check unsafe "merging a PR gh says nothing about drafts for" "draft"

section "the grant's PR numbers"
reset; check unsafe "a PR the grant doesn't name" "#12" merge "$head" 9 13

section "the head"
reset; pr '.headRefOid = "0000000000000000000000000000000000000000"'
check unsafe "GitHub's head isn't the local HEAD" "local HEAD"
reset; check unsafe "--match-head-commit names another SHA" "match-head-commit" merge 1234567
reset; check unsafe "--match-head-commit names no SHA" "match-head-commit" merge ""
reset; check unsafe "--match-head-commit names too short a SHA" "match-head-commit" merge "${head:0:6}"

section "checks"
reset; pr '.statusCheckRollup = []'; check safe "no checks at all on a head with no workflows"
reset; git -C "$work/repo" switch -q wf
pr ".headRefName = \"wf\" | .headRefOid = \"$wfhead\" | .statusCheckRollup = []"
mkdir -p "$work/home/agent-drafts/scripts/wf"; printf 'MERGE %s\n' "$wfhead" > "$work/home/agent-drafts/scripts/wf/merge-verdict.txt"
check unsafe "no checks yet on a head with workflows" "No checks have reported on this head yet" merge "$wfhead"
reset; git -C "$work/repo" switch -q wf
pr ".headRefName = \"wf\" | .headRefOid = \"$wfhead\""
check safe "green checks on a head with workflows" "" merge "$wfhead"
reset; pr '.statusCheckRollup[0].conclusion = "NEUTRAL" | .statusCheckRollup += [{__typename: "CheckRun", name: "docs", status: "COMPLETED", conclusion: "SKIPPED"}]'
check safe "neutral and skipped checks"
reset; pr '.statusCheckRollup[0].conclusion = "FAILURE"'; check unsafe "a failed check" "test"
reset; pr '.statusCheckRollup[0] |= (.status = "IN_PROGRESS" | .conclusion = "")'; check unsafe "a pending check" "test"
reset; pr '.statusCheckRollup[1].state = "PENDING"'; check unsafe "a pending status" "ci/legacy"
reset; pr '.statusCheckRollup[1].state = "ERROR"'; check unsafe "a failed status" "ci/legacy"

section "reviews"
reset; pr '.reviewDecision = "REVIEW_REQUIRED"'; check safe "no review decision yet"
reset; pr '.reviewDecision = "CHANGES_REQUESTED"'; check unsafe "a review requests changes" "changes"
reset; gql '.data.repository.pullRequest.reviewThreads.nodes += [{isResolved: false}]'; check unsafe "an unresolved thread" "unresolved"
reset; gql '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage = true'; check unsafe "more threads than one page" "100"
reset; gql '.data.repository.mergeQueue = {id: "MQ_1"}'; check unsafe "a merge queue" "merge queue"
reset; gql '{errors: [{message: "Could not resolve"}]}'; check unsafe "a GraphQL error" "Could not resolve"

section "the wait list"
reset; pr '.files = [{path: "src/app.py"}, {path: ".github/workflows/ci.yml"}]'; check unsafe "a CI workflow, in any repo" ".github/workflows/ci.yml"
reset; pr '.files = [{path: "uv.lock"}]'; check unsafe "a lockfile, in any repo" "uv.lock"
reset; pr '.files = [{path: "db/migrations/0002_add.py"}]'; check unsafe "a migration, in any repo" "db/migrations/0002_add.py"
reset; pr '.files = [{path: "config/settings.py"}]'; check safe "a config folder, outside hurin"
reset; pr '.url = "https://github.com/ctejada10/hurin/pull/12" | .files = [{path: "config/jobs/x.yaml"}]'
mkdir -p "$work/home/agent-drafts/hurin/feature"; printf 'MERGE %s\n' "$head" > "$work/home/agent-drafts/hurin/feature/merge-verdict.txt"
check unsafe "hurin's jobs config" "config/jobs/x.yaml"
reset; pr '.url = "https://github.com/ctejada10/hurin/pull/12" | .files = [{path: "src/hurin/web/app.py"}]'
check safe "hurin's web app"
reset; pr '.url = "https://github.com/ctejada10/rivendell/pull/12" | .files = [{path: "docker-compose.tpl"}]'
mkdir -p "$work/home/agent-drafts/rivendell/feature"; printf 'MERGE %s\n' "$head" > "$work/home/agent-drafts/rivendell/feature/merge-verdict.txt"
check unsafe "rivendell's compose template" "docker-compose.tpl"
reset; pr '.url = "https://github.com/ctejada10/dotfiles/pull/12" | .files = [{path: "README.md"}]'
mkdir -p "$work/home/agent-drafts/dotfiles/feature"; printf 'MERGE %s\n' "$head" > "$work/home/agent-drafts/dotfiles/feature/merge-verdict.txt"
check unsafe "any dotfiles change" "README.md"
reset; pr '.changedFiles = 300'; check unsafe "more files than gh lists" "300"
for path in sub/pyproject.toml config/.env.prod Secrets.md docs/SECRET_NOTES.txt web/package.json \
            environment.yml conda/environment.yaml bun.lockb go.mod go.sum Cargo.toml setup.py setup.cfg Pipfile Pipfile.lock; do
  reset; pr ".files = [{path: \"$path\"}]"; check unsafe "$path, by its full path or its name, in any case" "$path"
done

section "the verdict"
reset; rm "$verdict"; check unsafe "no verdict" "cross-family reviewer"
reset; printf 'WAIT the diff touches auth\n' > "$verdict"; check unsafe "a WAIT verdict" "cross-family reviewer"
reset; printf 'MERGE 0000000000000000000000000000000000000000\n' > "$verdict"; check unsafe "a verdict on another head" "cross-family reviewer"
reset; printf 'MERGE %s\n' "${head:0:12}" > "$verdict"; check unsafe "a verdict naming a short SHA" "cross-family reviewer"
reset; rm "$verdict"; check unsafe "no verdict names both paths it tried" "agent-drafts/repo/feature/merge-verdict.txt"
reset; rm "$verdict"; check unsafe "no verdict names the repo's path too" "agent-drafts/scripts/feature/merge-verdict.txt"
reset; rm "$verdict"; mkdir -p "$work/home/agent-drafts/repo/feature"
printf 'MERGE %s\n' "$head" > "$work/home/agent-drafts/repo/feature/merge-verdict.txt"
check safe "a verdict under the main checkout's folder name"
git -C "$work/repo" worktree add -q "$work/wt" -b wt2 feature
reset; pr '.headRefName = "wt2"'; rm "$verdict"; mkdir -p "$work/home/agent-drafts/repo/wt2"
printf 'MERGE %s\n' "$head" > "$work/home/agent-drafts/repo/wt2/merge-verdict.txt"
out=$(HOME="$work/home" PATH="$work/bin:$PATH" FAKE_GH="$fake" /usr/bin/python3 -B "$script" "$work/wt" merge "$head" 2>&1) \
  && pass "safe: in a worktree, a verdict under the main checkout's folder name" \
  || fail "safe: in a worktree, a verdict under the main checkout's folder name" "$out"
rm -rf "$work/home/agent-drafts/repo"

section "gh failing"
reset; printf '1' > "$fake/pr.status"; check unsafe "gh pr view fails" "gh pr view"
reset; printf '1' > "$fake/graphql.status"; check unsafe "gh api graphql fails" "gh api"
reset; printf 'not json' > "$fake/pr.json"; check unsafe "gh pr view prints no JSON" "gh pr view"
reset; printf '20' > "$fake/graphql.sleep"; check unsafe "gh api graphql hangs" "timed out"

section "every failure is named"
reset; pr '.statusCheckRollup[0].conclusion = "FAILURE"'; gql '.data.repository.pullRequest.reviewThreads.nodes = [{isResolved: false}]'; rm "$verdict"
out=$(HOME="$work/home" PATH="$work/bin:$PATH" FAKE_GH="$fake" /usr/bin/python3 -B "$script" "$work/repo" merge "$head" 2>&1)
lines=$(grep -c . <<< "$out")
[ "$lines" -eq 3 ] && pass "a red check, a thread and no verdict give three reasons" || fail "a red check, a thread and no verdict give three reasons" "$out"

section "bad arguments"
check unsafe "an unknown action" "" approve "$head"
check unsafe "a PR number that isn't one" "" merge "$head" twelve

summary
