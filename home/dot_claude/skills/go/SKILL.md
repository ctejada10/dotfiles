---
name: go
description: Run one coding task on the mini in a fixed order, from worktree to draft PR, naming the one installed skill or tool to use at each step. Use only when Carlos types /go.
disable-model-invocation: true
argument-hint: "<task, issue URL or PR URL>"
---

# go

Task: $ARGUMENTS

With no task, print the Steps and the Tool per job table below for Carlos and stop.

`~/.codex/AGENTS.md` is already loaded and wins over this file and over every skill named here: Git, stops, worktrees, the PR body and the final message all come from it. This file only fixes the order and picks one tool per job.

## Steps

1. **Size it.** If the task touches more than one file, changes a signature other files call, needs a design choice, or is a bug with an unknown cause or a perf issue, invoke `t3-pstack:poteto-mode` with the task and follow its playbook. Keep the Overrides below and finish with steps 7 and 8. Otherwise carry on here.
2. **Place it.** Make the worktree AGENTS.md's "Where work happens" names. Read the repo's own AGENTS.md or CLAUDE.md and its section under Repos.
3. **Read before writing.** Read the code the task touches and list every place the change must reach: callers, tests, fixtures, config, docs. When something is unclear, look it up (code, `git log`, the issue, the PR), then take the reading that is cheaper to undo and state it in one line.
4. **Name the check.** Write the failing test first with `superpowers:test-driven-development`. For a bug, reproduce it first with `superpowers:systematic-debugging`. With no test path, name the command whose output will prove the change.
5. **Make the smallest complete change.** Ponytail's rules apply: reuse what the repo has, no unrequested features, match the surrounding style, touch only what the task needs.
6. **Prove it.** Run `superpowers:verification-before-completion`: targeted tests, then the repo's full suite, lint and type-check. Check the real artifact too: run the CLI, or open a web UI with T3's `preview_*` tools.
7. **Review it.** Run `t3-pstack:deslop` over the diff, then `/code-review`. Fix what holds up and rerun step 6.
8. **Ship it.** Commit in the repo's style, push, open a draft PR, call `link_pull_request`, answer Copilot's review where the repo has it, and write the final message as AGENTS.md says.

## Overrides

Where an installed skill says otherwise, these win:

- PRs open as drafts and are never marked ready, merged or force-pushed, whatever poteto-mode's Opening a PR or Shipping says.
- Commit and PR titles follow the repo's `git log`, not poteto-mode's Conventional Commits rule.
- The PR body is AGENTS.md's list of changes, not poteto-mode's Why / Scope / Verification sections.
- superpowers specs and plans go in `~/agent-drafts/<repo>/<branch>/`. Never run `superpowers:using-superpowers` or the finishing-a-development-branch menu.
- Ponytail's `shortcut:` comments and closing skipped-work list are not written; the final message covers them.

## Tool per job

| Job | Use |
| --- | --- |
| Multi-file change, design choice, unknown bug, perf | `t3-pstack:poteto-mode` |
| Feature or behavior change | `superpowers:test-driven-development` |
| Bug, flaky or order-dependent test | `superpowers:systematic-debugging` |
| Before saying done | `superpowers:verification-before-completion` |
| Review a diff | `/code-review` |
| Review for less code | `/ponytail-review` |
| Security review | `/security-review` |
| Clean up AI slop | `t3-pstack:deslop` |
| Failing CI | `t3-pstack:fix-ci` |
| Merge conflicts | `t3-pstack:fix-merge-conflicts` |
| Read PR review comments | `t3-pstack:get-pr-comments` |
| GitHub Actions workflow | `github-actions-hardening` |
| Claude Code config | `agnix:agnix` |
| `uv.lock` or dependencies | `supply-chain-risk-auditor:supply-chain-risk-auditor` |
| Parsers, encoders, invariants | `property-based-testing:property-based-testing` |
| Chart or diagram | T3's `html_preview`, then `html_render` |
| Subagent on another provider or in its own worktree | T3's `delegate_task` |
| 3D model | `openscad-bosl2` |
