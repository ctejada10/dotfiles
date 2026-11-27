#!/usr/bin/python3
"""PreToolUse guard for T3 Code's pull-request tools, on the mini only.

T3 gives every thread MCP tools that do on GitHub what guard-git.py stops gh
from doing: pull_request_merge merges (with auto, it turns on auto-merge),
pull_request_update marks a PR ready or requests reviewers, pull_request_create
opens a PR that need not be a draft, pull_request_respond comments on the PR
and pull_request_review submits a review. Nothing in guard-git.py sees them,
since it reads Bash commands. So this blocks (exit 2):

- pull_request_merge, always. A merge goes through gh pr merge from the PR's
  branch, where guard-git.py reads Carlos's grant and merge-check.py checks
  the PR, and merge-notify.py tells him.
- pull_request_review, always. Reviews here are cross-family review threads,
  and their findings go in the PR body.
- pull_request_update that sets ready to true or requests reviewers. ready
  false, which puts a PR back to draft, is fine, as are title, body, labels
  and closing.
- pull_request_create without draft set to true.
- pull_request_respond with no reviewThreadId, which comments on the PR itself
  rather than replying in a review thread.
- Any title or body that credits an AI, as guard-git.py's AI_CREDIT reads it.

Other servers' tools, and T3's other tools, pass. A payload it can't read
blocks, since a crash would let the call through.
"""

import importlib.util
import json
import os
import re
import sys

SERVER = re.compile(r"^mcp__t3[-_]?code(?:[-_]direct)?__(.+)$", re.I)


def block(reason):
    print(f"BLOCKED by guard-t3.py: {reason}", file=sys.stderr)
    sys.exit(2)


def ai_credit():
    """guard-git.py's AI_CREDIT, from beside this file; its source name is
    executable_guard-git.py."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = next((p for p in (os.path.join(here, "guard-git.py"), os.path.join(here, "executable_guard-git.py"))
                 if os.path.isfile(p)), "")
    if not path:
        block(f"guard-git.py is missing from {here}, so nothing can check this PR's text for AI credit.")
    # No __pycache__ beside the deployed hooks.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("guard_git", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.AI_CREDIT


def check(tool, args):
    if tool == "pull_request_merge":
        block("T3's pull_request_merge. Merge with `gh pr merge --match-head-commit <sha>` from the PR's own "
              "branch, where Carlos's grant and merge-check.py are checked, or leave the PR for Carlos.")
    if tool == "pull_request_review":
        block("T3's pull_request_review. Reviews here run as review threads; put their findings in the PR body.")
    if tool == "pull_request_update":
        if args.get("ready") is True:
            block("T3's pull_request_update with ready. Mark a PR ready with `gh pr ready` under Carlos's grant, "
                  "or leave it a draft.")
        if args.get("requestReviewers"):
            block("T3's pull_request_update requesting reviewers. Only Carlos requests a review, Copilot's too.")
    if tool == "pull_request_create" and args.get("draft") is not True:
        block("T3's pull_request_create without draft: true. Open it again as a draft, even where a playbook "
              "says to open it ready.")
    if tool == "pull_request_respond" and not args.get("reviewThreadId"):
        block("T3's pull_request_respond with no reviewThreadId, which comments on the PR. Write to the PR body; "
              "only a reply in a Copilot review thread on your own PR goes in a thread.")
    if tool in ("pull_request_create", "pull_request_update", "pull_request_respond"):
        text = "\n".join(str(args.get(k) or "") for k in ("title", "body"))
        if text.strip() and ai_credit().search(text):
            block("this PR text credits an AI. Nothing here is credited to an AI agent: drop the line and try again.")


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        block("couldn't read the tool call.")
    try:
        match = SERVER.match(str(payload.get("tool_name") or ""))
        if not match:
            return
        args = payload.get("tool_input") or {}
        if not isinstance(args, dict):
            block("the tool call's input isn't an object.")
        check(match.group(1), args)
    except SystemExit:
        raise
    except Exception as error:
        block(f"couldn't check this call ({type(error).__name__}: {error}).")


if __name__ == "__main__":
    main()
