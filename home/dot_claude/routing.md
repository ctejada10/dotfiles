<!-- route-card:start -->
Routing for this message. Classify it before any tool call, and make the first line of your reply:

Route: DEEP|TRIVIAL|QUESTION|SKIP, then a dash and the reason in a few words.

- DEEP, the default: any request to build, change, fix, refactor, debug, speed up or design code, config or infrastructure.
- TRIVIAL: one file, about ten changed lines or fewer, no new behavior, no signature other files call, a known cause. When unsure, pick DEEP.
- QUESTION: an explanation, an opinion, a status or a chat, with no change asked for. Answer it, with no edits and no skills.
- SKIP: the message starts with `--`. Do exactly what it says, with no skills.
- Budget: at most 4 children at once, every child a leaf, 3 review rounds, 4 handoffs without Carlos. TRIVIAL and QUESTION start no children.
- Before the first edit or delegate_task in this thread, read ~/.claude/routing.md in full: the steps, the roster and the brief format are there.
<!-- route-card:end -->

# Routing

The card above is what `~/.claude/hooks/route-reminder.sh` adds to every message Carlos sends. This file is the rest. AGENTS.md and `~/.claude/claude-rules.md` win over it where they conflict.

## DEEP

1. Call `t3-pstack:poteto-mode` with the task and follow its playbook under AGENTS.md's rules.
2. Second opinion on the plan. When the work needs a design choice, send the plan to one review child on Neon (see the roster) before any builder starts. Fold in what holds up, and note in the PR body what you set aside and why.
3. Build within the budget, with each seat from the roster.
4. The adversarial pass, below, when it applies.
5. `t3-pstack:deslop` over the diff, unless poteto-mode already ran it on this diff.
6. `ponytail:ponytail-review` once on the final diff. Apply what holds up.
7. The cross-family review: one Codex Sol child on the final diff, with a brief that names the diff and its risks. This is AGENTS.md's one cross-family review per PR. Fix what holds up and rerun the tests.
8. Push, open the draft PR and call T3's `link_pull_request`. Answer Copilot's review if Carlos requested one.

DEEP runs no separate `code-review`: step 7 is its independent review.

## TRIVIAL

In this thread, with no children:

1. Make the worktree AGENTS.md's "Where work happens" names, and read the repo's AGENTS.md or CLAUDE.md. Read only the files the change touches. State your assumption and the success check in one line each.
2. For a bug, call `superpowers:systematic-debugging` and reproduce it. For a behavior change, call `superpowers:test-driven-development` and write the failing test. Then make the smallest change that passes.
3. Call `superpowers:verification-before-completion`: targeted tests, then the repo's full suite, lint and type-check.
4. Call `t3-pstack:deslop` over the diff, then `code-review` at level `low`. Fix what holds up and rerun the tests.
5. Commit in the repo's style, push, open the draft PR and call T3's `link_pull_request`.

If TRIVIAL work grows (a second file, a cause you cannot find, a design choice), say so in one line and switch to DEEP.

## Budget

- At most 4 `delegate_task` children run at once per parent.
- Every child is a leaf. A child starts no subagent unless its brief names exactly one.
- At most 3 review rounds per change. After the third, put the open non-blocking findings in the PR body; a blocking one is a stop.
- At most 4 agent-to-agent handoffs without a message from Carlos.
- Launch parallel children with `mode: "async"` before you wait on any of them.
- Each review round is a new `delegate_task` that carries the original brief, the prior findings and the open objections. Never reopen a completed child.
- TRIVIAL and QUESTION start no children.

## Roster

Each job goes to one seat. The t3-pstack model sheet (`~/.config/t3-pstack/models.md`, kept in the dotfiles repo) sets the seats poteto-mode reads; this table adds the seats it has no role for.

| Job | Seat | Limits |
| --- | --- | --- |
| Conductor, builders, judgment and prose | `claudeAgent/claude-opus-5-5 effort=high` (the sheet) | |
| Swarm workers, verification, the adversarial pass | `claudeAgent/claude-sonnet-5-5 effort=high` | |
| Chores: read-only lookups, CI and log triage, summaries, mechanical edits in the child's own worktree | `codex/gpt-6-luna reasoningEffort=medium` | Up to 4 per DEEP task. Never a review verdict, security work or a design choice. |
| Fast spec work: a first spec or research draft, returned in the reply | `codex/gpt-6.2-sol reasoningEffort=medium` | One per DEEP task. You check it against the code and write it to `~/agent-drafts/<repo>/<branch>/`. |
| Cross-family review of the final diff | `codex/gpt-6.2-sol reasoningEffort=medium` | One per PR (DEEP step 7). |
| Second opinion: the plan check, interrogate, arena judging | `antigravity/gemini-4-neon thinking_level=high` | As a child only. |
| Deep thinker | `claudeAgent/claude-fable-5-2 effort=high` | See Fable below. |

Codex shares one 5-hour ChatGPT Plus window with every Codex session on this Mac. Per DEEP task, Codex gets at most one Sol spec draft, the one Sol review, and four Luna chores, plus the arena judge and why investigator that claude-rules.md allows. If Codex reports a usage limit, move that work to Claude (Sonnet for chores, Opus for a spec or a review), never wait for the window to reset, and say so in the PR body.

Take every model ID from `orchestrator_capabilities`. If one listed here is missing, use the ID it lists for the same model and say so in the PR body; if Luna is missing, chores go to Sonnet.

### Fable

Fable 5.2 runs only as a child, at `effort=high`, for one of these triggers:

- a bug or flaky test whose cause one full Opus attempt did not find;
- a perf or hillclimb task where an Opus attempt stalled;
- the first build of work with hard concurrency, safety or money design;
- the arena's second runner, which the model sheet seats.

At most one Fable child per DEEP task, unless Carlos typed more. Never use Fable for reviews, fix rounds, merges, mechanical edits or chores. Name the trigger in the brief's GOAL and in the PR body. This replaces poteto-mode's own Fable rule.

Fable may use at most half of the Claude plan's weekly limit and spends it fastest; past that, it bills usage credits. If a Fable child reports a usage limit, or says it would draw on usage credits, use no Fable for the rest of the run, redo its step on Opus at high, and say so in the PR body.

## Briefs

A child gets only its brief, never this thread. When poteto-mode starts the child, t3-pstack's worker.md pointer is the first line. Then these seven fields, each on a line of its own:

```
BRIEF FOR: <providerInstanceId/model and its options, from the roster>
ROLE: <implementation | research | review | design | test | general>, the role you also pass to delegate_task
GOAL: <the outcome in one sentence; for Fable, its trigger>
CONTEXT: <absolute paths, the base and head sha, decisions made, the spec's path>
DONE WHEN: <a command that returns 0, a test that passes, or a checklist that is true>
DO NOT: start no subagents; <for ROLE: review, also: edit no files>; <files and commands to leave alone>
RETURN: <what to report>, always including the provider and model that actually ran
```

Naming a model in a brief is not proof it ran: read the child's report for it. A review child that reports a usage limit, or ends with no findings and no verdict, has failed; for Neon, drop that seat for the rest of the run and say so in the PR body.

## The adversarial pass

DEEP only. It applies when the diff touches credentials or secrets, parsing of outside input, network endpoints or clients, CI workflows, or permissions. Start one child, after t3-pstack's worker.md pointer:

```
BRIEF FOR: claudeAgent/claude-sonnet-5-5 effort=high
ROLE: review
GOAL: Read ~/.claude/agents/adversarial-reviewer.md in full and act as it says on this change.
CONTEXT: <base sha>, <head sha>, the task, and the packs that apply: pack-gha-security-dast for workflows, pack-python-untrusted-input for parsing outside input, pack-threat-model for a new trust boundary or integration, pack-linux-platform for system services, permissions or shell.
DONE WHEN: every finding has a reproduction, and the reply ends with VERDICT: and MODEL: lines.
DO NOT: start no subagents; edit no files.
RETURN: the findings with their reproductions, VERDICT:, and MODEL: with the provider and model that actually ran.
```

Fix every blocking finding, keep each reproduction as a test, and send the diff back for one more pass. Stop after two fix rounds on the same kind of finding and write it up in the PR body instead. A reply with no `VERDICT:` line, or one that reports a usage limit, is a failure: say so in the PR body.

## Children you are done with

When you have read a child's result and need nothing more from it, settle its thread with the T3 tool `orchestrator_capabilities` lists for settling or archiving a thread, if there is one. For a child you abandon, call `task_cancel`, read `task_status` until the task is terminal with no `hasPendingChildRuns`, then settle it.

## Tool per job

Call the matching skill when its job comes up.

| Job | Call |
| --- | --- |
| Bug, flaky or order-dependent test | `superpowers:systematic-debugging` |
| Feature or behavior change | `superpowers:test-driven-development` |
| Before saying done | `superpowers:verification-before-completion` |
| Before commit | `t3-pstack:deslop` |
| Review a TRIVIAL diff | `code-review` at `low` |
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
| A child on another provider or in its own worktree | T3's `delegate_task`, with a brief as above |
