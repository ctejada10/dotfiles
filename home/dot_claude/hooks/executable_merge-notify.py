#!/usr/bin/python3
"""PostToolUse hook for Bash, on the mini only: after an agent's gh pr merge,
tells Carlos what merged.

When the PR on the command's checkout is merged, it appends a line to
~/.local/state/agent-merges.log (UTC time, repo, PR number, merge commit,
title and session, tab-separated) and sends a Telegram message through
hermes send: the PR, its merge commit, its link and the reasons from the
cross-family reviewer's verdict. A merge already logged isn't sent again. A
send that fails is logged as notify-failed. It never blocks anything and
always exits 0.
"""

import datetime
import json
import os
import re
import shutil
import subprocess
import sys

LOG = os.path.expanduser("~/.local/state/agent-merges.log")
TIMEOUT = 15


def logged(*fields):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    with open(LOG, "a", encoding="utf-8") as f:
        f.write("\t".join([stamp, *(re.sub(r"\s+", " ", str(x)) for x in fields)]) + "\n")


def already(repo, number, oid):
    try:
        with open(LOG, encoding="utf-8") as f:
            return any(line.split("\t")[1:4] == [repo, str(number), oid] for line in f)
    except OSError:
        return False


def notify(payload):
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not isinstance(command, str) or not re.search(r"\bgh\b.*\bpr\s+merge\b", command):
        return
    try:
        result = subprocess.run(["gh", "pr", "view", "--json", "number,title,url,state,mergeCommit,headRefName"],
                                cwd=payload.get("cwd") or None, capture_output=True, text=True, timeout=TIMEOUT)
        pr = json.loads(result.stdout) if result.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return
    if not isinstance(pr, dict) or pr.get("state") != "MERGED":
        return
    url = str(pr.get("url") or "")
    match = re.match(r"https://github\.com/([^/]+/[^/]+)/pull/", url)
    repo = match.group(1) if match else url
    number, title = pr.get("number"), str(pr.get("title") or "")
    oid = str((pr.get("mergeCommit") or {}).get("oid") or "")
    if already(repo, number, oid):
        return
    logged(repo, number, oid, title, payload.get("session_id") or "")

    lines = [f"Agent merged {repo}#{number}: {title}", oid[:12], url]
    verdict = os.path.expanduser(f"~/agent-drafts/{repo.split('/')[-1]}/{pr.get('headRefName')}/merge-verdict.txt")
    try:
        with open(verdict, encoding="utf-8", errors="replace") as f:
            lines += [line.rstrip("\n") for line in f.readlines()[1:]]
    except OSError:
        pass
    message = "\n".join(lines).strip()[:800]

    local = os.path.expanduser("~/.local/bin/hermes")
    hermes = local if os.access(local, os.X_OK) else shutil.which("hermes")
    if not hermes:
        logged("notify-failed", repo, number, oid, "hermes not found")
        return
    try:
        sent = subprocess.run([hermes, "send", "--to", "telegram", "-q"], input=message,
                              capture_output=True, text=True, timeout=TIMEOUT)
        error = f"hermes exited {sent.returncode}" if sent.returncode else ""
    except (OSError, subprocess.SubprocessError) as failure:
        error = type(failure).__name__
    if error:
        logged("notify-failed", repo, number, oid, error)


def main():
    try:
        notify(json.load(sys.stdin))
    except Exception:
        # A notice that fails must never get in the agent's way.
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
