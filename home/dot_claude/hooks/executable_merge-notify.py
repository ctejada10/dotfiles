#!/usr/bin/python3
"""PostToolUse hook for Bash, on the mini only: after an agent's gh pr merge,
tells Carlos what merged.

It acts only on a merge guard-git.py let through, which recorded the folder
it ran in as ~/.local/state/agent-merge-pending/<tool_use_id>.json, and
removes that file whatever happens. When the PR in that folder is merged, it
sends a Telegram message through hermes send: the PR, its merge commit, its
link and the reasons from the cross-family reviewer's verdict. Then it
appends a line to ~/.local/state/agent-merges.log (UTC time, repo, PR number,
merge commit, title, session, and sent or notify-failed with the reason,
tab-separated). A merge already logged as sent isn't sent again, and the log
stays locked from that check to the append. It never blocks anything and
always exits 0.
"""

import datetime
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys

LOG = os.path.expanduser("~/.local/state/agent-merges.log")
PENDING = os.path.expanduser("~/.local/state/agent-merge-pending")
TIMEOUT = 6


def pending(payload):
    """The merge guard-git.py recorded for this tool call, which it removes."""
    tool = payload.get("tool_use_id")
    if not isinstance(tool, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", tool):
        return None
    path = os.path.join(PENDING, f"{tool}.json")
    try:
        with open(path, encoding="utf-8") as f:
            record = json.load(f)
    except (OSError, ValueError):
        record = None
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    return record if isinstance(record, dict) and isinstance(record.get("cwd"), str) else None


def verdict_reasons(repo, branch, cwd):
    """The lines after the verdict's first, from its folder named after the
    GitHub repo or the main checkout's folder, as merge-check.py reads it."""
    folders = [repo.split("/")[-1]]
    try:
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=cwd,
                                capture_output=True, text=True, timeout=TIMEOUT).stdout.strip()
        if common:
            folders.append(os.path.basename(os.path.dirname(common)))
    except (OSError, subprocess.SubprocessError):
        pass
    for folder in folders:
        try:
            with open(os.path.expanduser(f"~/agent-drafts/{folder}/{branch}/merge-verdict.txt"),
                      encoding="utf-8", errors="replace") as f:
                return [line.rstrip("\n") for line in f.readlines()[1:]]
        except OSError:
            continue
    return []


def send(message):
    """hermes send's outcome: "" when it worked, else why not."""
    local = os.path.expanduser("~/.local/bin/hermes")
    hermes = local if os.access(local, os.X_OK) else shutil.which("hermes")
    if not hermes:
        return "hermes not found"
    try:
        sent = subprocess.run([hermes, "send", "--to", "telegram", "-q"], input=message,
                              capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError) as failure:
        return type(failure).__name__
    return f"hermes exited {sent.returncode}" if sent.returncode else ""


def notify(payload):
    record = pending(payload)
    if record is None:
        return
    cwd = record["cwd"]
    try:
        result = subprocess.run(["gh", "pr", "view", "--json", "number,title,url,state,mergeCommit,headRefName"],
                                cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT)
        pr = json.loads(result.stdout) if result.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return
    if not isinstance(pr, dict) or pr.get("state") != "MERGED":
        return
    url = str(pr.get("url") or "")
    match = re.match(r"https://github\.com/([^/]+/[^/]+)/pull/", url)
    repo = match.group(1) if match else url
    number, title = str(pr.get("number")), str(pr.get("title") or "")
    oid = str((pr.get("mergeCommit") or {}).get("oid") or "")
    lines = [f"Agent merged {repo}#{number}: {title}", oid[:12], url]
    lines += verdict_reasons(repo, pr.get("headRefName"), cwd)
    message = "\n".join(lines).strip()[:800]

    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a+", encoding="utf-8") as log:
        fcntl.flock(log, fcntl.LOCK_EX)
        log.seek(0)
        if any(line.rstrip("\n").split("\t")[1:3] == [repo, number] and line.rstrip("\n").split("\t")[6:7] == ["sent"]
               for line in log):
            return
        error = send(message)
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        fields = [repo, number, oid, title, payload.get("session_id") or "", "notify-failed" if error else "sent"]
        log.write("\t".join([stamp, *(re.sub(r"\s+", " ", str(x)) for x in fields + ([error] if error else []))]) + "\n")


def main():
    try:
        notify(json.load(sys.stdin))
    except Exception:
        # A notice that fails must never get in the agent's way.
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
