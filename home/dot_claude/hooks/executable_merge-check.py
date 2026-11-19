#!/usr/bin/python3
"""Whether the PR on the checked-out branch is safe for an agent to ready or
merge, on the mini only. guard-git.py runs it before gh pr ready or gh pr
merge under Carlos's grant:

    merge-check.py <cwd> <ready|merge> <sha, or ""> [PR numbers the grant names]

It exits 0 when every check passes and 2 otherwise, with one reason per
failed check on stderr. The PR must be the branch's own, from this repo, into
the default branch, on the local HEAD, and one of the grant's PRs when it names
some; a merge's --match-head-commit SHA must be that head. Every check on
GitHub is green, no review requests changes, no review thread is unresolved,
and the base has no merge queue. No changed file is on the wait list in
merge-wait.json beside this file. The cross-family reviewer's verdict in
~/agent-drafts/<repo>/<branch>/merge-verdict.txt opens with MERGE and the
PR's full head SHA. Anything gh or git can't answer counts as a failure.
"""

import fnmatch
import json
import os
import re
import subprocess
import sys

TIMEOUT = 15
GREEN = ("SUCCESS", "NEUTRAL", "SKIPPED")
QUERY = """query($owner: String!, $name: String!, $base: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    mergeQueue(branch: $base) { id }
    pullRequest(number: $number) { reviewThreads(first: 100) { nodes { isResolved } pageInfo { hasNextPage } } }
  }
}"""


class Unanswered(Exception):
    pass


def run(cwd, *args):
    name = " ".join(args[:3])
    try:
        result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Unanswered(f"`{name}` timed out after {TIMEOUT} seconds.")
    except OSError as error:
        raise Unanswered(f"`{name}` couldn't run: {error}.")
    if result.returncode:
        raise Unanswered(f"`{name}` failed: {(result.stderr or result.stdout).strip()[:300]}")
    return result.stdout.strip()


def run_json(cwd, *args):
    out = run(cwd, *args)
    try:
        return json.loads(out)
    except ValueError:
        raise Unanswered(f"`{' '.join(args[:3])}` printed no JSON: {out[:200]}")


def checks_failing(rollup):
    """The names of the checks and statuses that aren't green, pending ones included."""
    bad = []
    for item in rollup or []:
        if item.get("__typename") == "StatusContext":
            if item.get("state") != "SUCCESS":
                bad.append(f"{item.get('context')} ({item.get('state')})")
        elif item.get("status") != "COMPLETED" or item.get("conclusion") not in GREEN:
            bad.append(f"{item.get('name')} ({item.get('status')}, {item.get('conclusion') or 'no conclusion'})")
    return bad


def waits(repo, paths):
    """The changed paths that the wait list holds for Carlos, in any repo or in this one."""
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "merge-wait.json"), encoding="utf-8") as f:
        table = {key.lower(): value for key, value in json.load(f).items()}
    globs = table.get("*", []) + table.get(repo.lower(), [])
    return [p for p in paths if any(fnmatch.fnmatchcase(p, g) for g in globs)]


def problems(cwd, action, sha, allowed):
    found = []

    def ask(what, *args):
        try:
            return what(cwd, *args)
        except Unanswered as error:
            found.append(str(error))
            return None

    try:
        defaults = {run(cwd, "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD").split("/", 1)[-1]}
    except Unanswered:
        defaults = {"main", "master"}
    try:
        branch = run(cwd, "git", "symbolic-ref", "--short", "-q", "HEAD")
    except Unanswered:
        branch = ""
        found.append("The checkout has a detached HEAD, or git can't read it. Run this from the PR's branch.")
    if branch in defaults:
        found.append(f"{branch} is the default branch. Run this from the PR's own branch.")
    local = ask(run, "git", "rev-parse", "HEAD")
    pr = ask(run_json, "gh", "pr", "view", "--json",
             "number,url,headRefName,headRefOid,baseRefName,isCrossRepository,files,changedFiles,"
             "statusCheckRollup,reviewDecision")
    if not isinstance(pr, dict):
        if pr is not None:
            found.append("`gh pr view` printed something other than a PR.")
        return found

    number, head = pr.get("number"), str(pr.get("headRefOid") or "")
    url = re.match(r"https://github\.com/([^/]+)/([^/]+)/pull/", str(pr.get("url") or ""))
    if not url:
        found.append(f"The PR's URL, {pr.get('url')}, is not a GitHub PR's.")
        return found
    owner, name = url.groups()
    if branch and pr.get("headRefName") != branch:
        found.append(f"The PR is for {pr.get('headRefName')}, not the checked-out {branch}.")
    if pr.get("isCrossRepository") is not False:
        found.append("The PR comes from a fork or another repo.")
    if pr.get("baseRefName") not in defaults:
        found.append(f"The PR goes into {pr.get('baseRefName')}, not the default branch.")
    if allowed is not None and number not in allowed:
        found.append(f"Carlos's grant names {', '.join(f'#{n}' for n in sorted(allowed))}, not #{number}.")
    if local is not None and local != head:
        found.append(f"GitHub's head {head[:12]} is not the local HEAD {local[:12]}. Push, or pull, and check again.")
    if action == "merge" and not (re.fullmatch(r"[0-9a-fA-F]{7,40}", sha) and head.lower().startswith(sha.lower())):
        found.append(f"--match-head-commit {sha or '(none)'} is not the PR's head, {head[:12]}.")
    bad = checks_failing(pr.get("statusCheckRollup"))
    if bad:
        found.append(f"Not every check is green: {', '.join(bad)}.")
    if pr.get("reviewDecision") == "CHANGES_REQUESTED":
        found.append("A review requests changes.")

    graph = ask(run_json, "gh", "api", "graphql", "-f", f"query={QUERY}", "-f", f"owner={owner}",
                "-f", f"name={name}", "-f", f"base={pr.get('baseRefName')}", "-F", f"number={number}")
    if graph is not None:
        try:
            repository = graph["data"]["repository"]
            threads = repository["pullRequest"]["reviewThreads"]
            if repository["mergeQueue"] is not None:
                found.append(f"{pr.get('baseRefName')} has a merge queue, so a merge there is deferred. Wait for Carlos.")
            open_threads = sum(1 for t in threads["nodes"] if not t["isResolved"])
            if open_threads:
                found.append(f"{open_threads} review thread(s) are unresolved.")
            if threads["pageInfo"]["hasNextPage"]:
                found.append("The PR has more than 100 review threads, more than this checks.")
        except (KeyError, TypeError):
            found.append(f"`gh api graphql` gave no answer: {json.dumps(graph.get('errors', graph))[:300]}")

    files = [str(f.get("path")) for f in pr.get("files") or [] if isinstance(f, dict)]
    if len(files) < (pr.get("changedFiles") or 0):
        found.append(f"The PR changes {pr.get('changedFiles')} files and gh lists only {len(files)}, so the wait list can't be checked.")
    try:
        held = waits(f"{owner}/{name}", files)
    except (OSError, ValueError, AttributeError, TypeError) as error:
        found.append(f"merge-wait.json can't be read: {error}.")
    else:
        if held:
            found.append(f"These files wait for Carlos (merge-wait.json): {', '.join(held)}.")

    path = os.path.expanduser(f"~/agent-drafts/{name}/{pr.get('headRefName')}/merge-verdict.txt")
    try:
        with open(path, encoding="utf-8") as f:
            first = f.readline().rstrip("\n")
    except OSError:
        first = ""
    if first != f"MERGE {head}":
        found.append(f"The cross-family reviewer's verdict on this head is required: {path} must open with "
                     f"`MERGE {head}`, and has {first!r}.")
    return found


def main(argv):
    if len(argv) < 3 or argv[1] not in ("ready", "merge") or not all(n.isdigit() for n in argv[3:]):
        print("usage: merge-check.py <cwd> <ready|merge> <sha, or \"\"> [PR numbers]", file=sys.stderr)
        return 2
    cwd, action, sha = argv[:3]
    allowed = {int(n) for n in argv[3:]} or None
    found = problems(cwd, action, sha, allowed)
    for reason in found:
        print(reason, file=sys.stderr)
    return 2 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
