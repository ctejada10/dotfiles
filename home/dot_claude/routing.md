Routing for this message. Classify it before any tool call, and make the first line of your reply:

Route: DEEP|TRIVIAL|QUESTION|SKIP, then a dash and the reason in a few words.

- DEEP is the default: any request to build, change, fix, refactor, debug, speed up or design code, config or infrastructure. Call `t3-pstack:poteto-mode` with the task and follow its playbook under AGENTS.md's rules. After interrogate, run the adversarial pass below when it applies. Then, before the draft PR, call `ponytail:ponytail-review` once on the final diff and apply what holds up.
- TRIVIAL only when all of these hold: one file, about ten changed lines or fewer, no new behavior, no signature other files call, and a known cause. A typo, a comment, doc wording, or a value Carlos named exactly. Read `~/.claude/skills/go/SKILL.md` and follow its small path, steps 2 to 6, in this thread with no subagents.
- QUESTION: an explanation, an opinion, a status or a chat, with no change asked for. Answer it. No edits and no skills.
- SKIP: the message starts with `--`. Do exactly what it says, with no skills.

When unsure between TRIVIAL and DEEP, pick DEEP. If TRIVIAL work grows (a second file, a cause you cannot find, a design choice), say so in one line and switch to DEEP.

Adversarial pass, DEEP only. It applies when the diff touches credentials or secrets, parsing of outside input, network endpoints or clients, CI workflows, or permissions. Start one `delegate_task` child on `claudeAgent/claude-sonnet-5-5` with `effort=high`. Its brief opens with t3-pstack's worker.md pointer, then "Read `~/.claude/agents/adversarial-reviewer.md` in full and act as it says", then the base sha, the head sha, the task, and the packs that apply: `pack-gha-security-dast` for workflows, `pack-python-untrusted-input` for parsing outside input, `pack-threat-model` for a new trust boundary or integration, `pack-linux-platform` for system services, permissions or shell. Fix every blocking finding, keep each reproduction as a test, and send the diff back for one more pass. Stop after two fix rounds on the same kind of finding and write it up in the PR body instead. A reply with no `VERDICT:` line, or one that reports a usage limit, is a failure: say so in the PR body.

Every child you start names, near the top of its report, the provider and model that actually ran (the adversarial reviewer's `MODEL:` line does this). Naming a model in a brief is not proof it ran.
