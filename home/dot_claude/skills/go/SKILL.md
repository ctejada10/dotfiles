---
name: go
description: Run one coding task on the mini through poteto-mode and the installed plugin skills, in a fixed order from worktree to draft PR. Use only when Carlos types /go.
disable-model-invocation: true
argument-hint: "<task, issue URL or PR URL>"
---

# go

Task: $ARGUMENTS

With no task, print the Steps and the Tool per job table below for Carlos and stop.

`~/.codex/AGENTS.md` is already loaded and wins over this file and over every skill named here: Git, stops, worktrees, the PR body and the final message all come from it.

## Steps

Each "call" below is a Skill tool call, made at that point, even when the task looks small. A step that does not apply stays in your todo list with `skip: <reason>`.

1. **Enter poteto-mode.** Call `t3-pstack:poteto-mode` with the task. It picks the playbook and opens the todo list. Add steps 2 to 7 below to that list, and keep the Overrides.
2. **Ground it.** Make the worktree AGENTS.md's "Where work happens" names, read the repo's AGENTS.md or CLAUDE.md, then call `andrej-karpathy-skills:karpathy-guidelines` and state your assumptions and success check in one line each.
3. **Test first.** For a bug, call `superpowers:systematic-debugging` and reproduce it. For a feature or behavior change, call `superpowers:test-driven-development` and write the failing test. Then let the poteto-mode playbook build the change. Ponytail's rules are always on and need no call.
4. **Prove it.** Call `superpowers:verification-before-completion`, and run the repo's full suite, lint and type-check.
5. **Clean it.** Call `t3-pstack:deslop` over the diff before you commit.
6. **Review it.** Call `code-review` on the diff, plus the matching row of the Tool per job table when the diff touches that kind of file. Fix what holds up and redo step 4. poteto-mode's `interrogate` panel still runs where its playbook says.
7. **Ship it.** Commit in the repo's style, push, open a draft PR, call T3's `link_pull_request`, answer Copilot's review where the repo has it, and write the final message as AGENTS.md says.

## Overrides

Where an installed skill says otherwise, these win:

- PRs open as drafts and are never marked ready, merged or force-pushed, whatever poteto-mode's Opening a PR or Shipping says.
- Commit and PR titles follow the repo's `git log`, not poteto-mode's Conventional Commits rule.
- The PR body is AGENTS.md's list of changes, not poteto-mode's Why / Scope / Verification sections.
- superpowers specs and plans go in `~/agent-drafts/<repo>/<branch>/`. Never call `superpowers:using-superpowers` or the finishing-a-development-branch menu.
- Ponytail's `shortcut:` comments and closing skipped-work list are not written; the final message covers them.

## Tool per job

Call the matching skill when its job comes up.

| Job | Call |
| --- | --- |
| Any task (step 1) | `t3-pstack:poteto-mode` |
| Assumptions and success check (step 2) | `andrej-karpathy-skills:karpathy-guidelines` |
| Feature or behavior change | `superpowers:test-driven-development` |
| Bug, flaky or order-dependent test | `superpowers:systematic-debugging` |
| Before saying done | `superpowers:verification-before-completion` |
| Before commit | `t3-pstack:deslop` |
| Review a diff | `code-review` |
| Review for less code | `ponytail:ponytail-review` |
| Security-sensitive diff | `security-review` |
| Failing CI | `t3-pstack:fix-ci` |
| Merge conflicts | `t3-pstack:fix-merge-conflicts` |
| Read PR review comments | `t3-pstack:get-pr-comments` |
| GitHub Actions workflow | `github-actions-hardening` |
| Claude Code config | `agnix:agnix` |
| `uv.lock` or dependencies | `supply-chain-risk-auditor:supply-chain-risk-auditor` |
| Parsers, encoders, invariants | `property-based-testing:property-based-testing` |
| 3D model | `openscad-bosl2` |
| Chart or diagram | T3's `html_preview`, then `html_render` |
| Subagent on another provider or in its own worktree | T3's `delegate_task` |
