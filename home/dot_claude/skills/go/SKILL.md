---
name: go
description: Run one coding task on the mini from worktree to draft PR, calling the installed plugin skills at fixed steps and paying for poteto-mode's subagents only when the task is big. Use only when Carlos types /go.
disable-model-invocation: true
argument-hint: "<task, issue URL or PR URL>"
---

# go

Task: $ARGUMENTS

With no task, print the Steps and the Tool per job table below for Carlos and stop.

`~/.codex/AGENTS.md` is already loaded and wins over this file and over every skill named here: Git, stops, worktrees, the PR body and the final message all come from it.

Each "call" below is a Skill tool call, made at that point. A step that does not apply stays in your todo list with `skip: <reason>`.

## 1. Pick the path

Calling a skill only loads its instructions. Subagents are what cost: each one re-reads the code in its own context, and poteto-mode starts several per task (explorers, design runners, a code delegate, two reviewers per review round). So:

- **Big path** when the task touches more than one file, changes a signature other files call, needs a design choice, or is a bug with an unknown cause or a perf issue: call `t3-pstack:poteto-mode` with the task and follow its playbook, keeping the Overrides. Then finish with steps 5 and 6.
- **Small path** for everything else: steps 2 to 6 below, in this thread, with no subagents.
- If the task says which path, take it. If a small task grows (a second file, a cause you cannot find), stop and call `t3-pstack:poteto-mode` with what you know so far.

## Small path

2. **Ground it.** Make the worktree AGENTS.md's "Where work happens" names and read the repo's AGENTS.md or CLAUDE.md. Read only the files the change touches, and list every place it must reach. State your assumption and the success check in one line each.
3. **Test first.** For a bug, call `superpowers:systematic-debugging` and reproduce it. For a feature or behavior change, call `superpowers:test-driven-development` and write the failing test. Then make the smallest change that passes; Ponytail's rules are always on.
4. **Prove it.** Call `superpowers:verification-before-completion`: targeted tests, then the repo's full suite, lint and type-check.

## Both paths

5. **Clean and review.** Call `t3-pstack:deslop` over the diff, then call `code-review` with level `low` on the small path or `medium` on the big path, never higher unless Carlos asks. Fix what holds up and rerun the tests.
6. **Ship it.** Commit in the repo's style, push, open a draft PR, call T3's `link_pull_request`, answer Copilot's review where the repo has it, and write the final message as AGENTS.md says.

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
| Big task (step 1) | `t3-pstack:poteto-mode` |
| Bug, flaky or order-dependent test | `superpowers:systematic-debugging` |
| Feature or behavior change | `superpowers:test-driven-development` |
| Before saying done | `superpowers:verification-before-completion` |
| Before commit | `t3-pstack:deslop` |
| Review a diff | `code-review` (`low` or `medium`) |
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
