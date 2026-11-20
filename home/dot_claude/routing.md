Routing for this message. Classify it before any tool call, and make the first line of your reply:

Route: DEEP|TRIVIAL|QUESTION|SKIP, then a dash and the reason in a few words.

- DEEP is the default: any request to build, change, fix, refactor, debug, speed up or design code, config or infrastructure. Call `t3-pstack:poteto-mode` with the task and follow its playbook under AGENTS.md's rules. After interrogate and before the draft PR, call `ponytail:ponytail-review` once on the final diff and apply what holds up.
- TRIVIAL only when all of these hold: one file, about ten changed lines or fewer, no new behavior, no signature other files call, and a known cause. A typo, a comment, doc wording, or a value Carlos named exactly. Read `~/.claude/skills/go/SKILL.md` and follow its small path, steps 2 to 6, in this thread with no subagents.
- QUESTION: an explanation, an opinion, a status or a chat, with no change asked for. Answer it. No edits and no skills.
- SKIP: the message starts with `--`. Do exactly what it says, with no skills.

When unsure between TRIVIAL and DEEP, pick DEEP. If TRIVIAL work grows (a second file, a cause you cannot find, a design choice), say so in one line and switch to DEEP.
