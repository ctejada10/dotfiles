# Rules for Claude Code on the Mac mini

These rules add to `~/.codex/AGENTS.md`, which Claude Code loads first, and only Claude Code reads them. AGENTS.md's Precedence section covers them too: they win over any plugin, skill or playbook they conflict with. `~/.claude/routing.md` holds the routes, the budget, the roster and the brief format.

## Asking

- Ask only with the AskUserQuestion tool, never as a question at the end of a prose message.
- A session is attended only when its system prompt says Carlos is in the thread and it is not a delegated child task or a scheduled run, even if one of those inherited that prompt.
- Attended: ask about scope and design choices instead of deciding them yourself, one question per call, and wait for the answer. After Carlos approves a plan, work as if unattended.
- Unattended: ask only for a Stop, with every question starting `STOP:`.

## Routing

- t3-pstack's session hook and `~/.claude/hooks/route-reminder.sh` route the work, both by `~/.claude/routing.md`. The hook adds its route card to every message Carlos sends: deep work, the default, through t3-pstack's poteto-mode; a trivial one-file edit through routing.md's TRIVIAL steps in the thread; a question answered directly; a message starting with `--` done as written. The route line also picks the review and how far the work goes (routing.md's Review and Ending), so Carlos never has to name a skill; "full stop" in the middle of a message is emphasis, not a route. A delegated child or a FirstMate crew never routes, never enters poteto-mode and never delegates unless its brief says so.
- superpowers is a skill library that you and poteto-mode call by name. Never invoke superpowers:using-superpowers.
- Use superpowers:test-driven-development for features and behavior changes, not only bug fixes. Where it says to delete code written before its test, keep the code and write the test.
- Use superpowers:verification-before-completion before you claim that work is done or passing.
- For flaky or order-dependent tests, use the condition-based-waiting, root-cause-tracing and find-polluter.sh material in superpowers:systematic-debugging.
- Where superpowers' defense-in-depth and t3-pstack's Boundary Discipline disagree, follow Boundary Discipline.
- Never write superpowers specs or plans to `docs/superpowers/`. A spec or plan in `~/agent-drafts/<repo>/<branch>/` for this work is the approved design: do not run t3-pstack's how, architect or a new plan over it.
- Execute every superpowers plan with superpowers:subagent-driven-development, without asking which method to use. Its ledger stays out of the PR. Then run t3-pstack's interrogate once as the gate before the PR.
- superpowers:brainstorming runs only when attended, and the finishing-a-development-branch menu never runs.

## Skills and reviews

- The sol-loop and council skills come unchanged from Theo's tstack. Where they clash with these rules or routing.md, the rules win: at most 3 rounds, no PR-body line or heading that names the loop or a model, Sol at medium, Neon in for Sol on a Codex limit, and the PR stays a draft until Merging's steps.
- Never start these yourself, because Carlos does: the rpi- skills, Matt Pocock's skills (grill-me, grilling, grill-with-docs, to-spec, domain-modeling, codebase-design, improve-codebase-architecture, writing-for-agents) and i-have-adhd.
- Ignore Ponytail's STATUSLINE SETUP NEEDED notice. Write no `shortcut:` comments and no closing list of skipped work; the PR body and your final message cover that.
- When a review is called for, use one default per job: a DEEP diff, routing.md's Review (the Sol loop, or a council where it says); a TRIVIAL diff, /code-review at low; security, /security-review, plus routing.md's adversarial pass (the adversarial-reviewer agent, on Sonnet) on DEEP work; less code, /ponytail-review; GitHub Actions workflows, github-actions-hardening; Claude Code config, agnix; uv.lock, supply-chain-risk-auditor. Use the ecc- agents (python-reviewer, build-error-resolver, silent-failure-hunter, security-reviewer) only when the task names them.
- Run `/code-review --comment` only when a message Carlos typed names it.
- Tests: property-based-testing where properties fit. mutation-testing and spec-to-code-compliance only when the task asks; the second spends a lot of tokens.
- 3D models: openscad-bosl2 targets the Bambu A1 with an AMS Lite. The mini cannot see which filaments are loaded, so say in the PR body which ones you assumed. Commit the finished model on your branch, so Carlos can open it from the PR in Bambu Studio on the laptop.

## Models

- Each job's seat is in routing.md's roster, and the model sheet (`~/.config/t3-pstack/models.md`) seats poteto-mode's roles. Judge each task, because a label such as "kernel" or a role default is not a reason to go higher, and never go above high unless a message Carlos typed asks for it. Never turn on `fastMode` or any other priced fast mode. Never use a model from a Chinese developer (GLM, Kimi, MiniMax, DeepSeek, Qwen and the like) through any provider, and name every model explicitly, never an "Auto" model or router.
- Fable runs only as routing.md's deep-thinker seat and the arena's second runner, under the limits there. A second opinion comes from another model family, not from a costlier model of the same one.
- Codex runs on a ChatGPT Plus plan whose 5-hour window every Codex session here shares, and on 2026-11-02 a crew spent it in under two hours on 16 high-effort reviews. Send Codex, at medium effort, only routing.md's Codex seats (the chores on Luna, one Sol spec draft, and Sol in the loop or its council seat, up to 3 rounds per DEEP task), one judge in an arena's cross-judge pool, one investigator in a why panel, and roles a message Carlos typed names. Workers, fix-round reviews, per-unit crew reviews, swarms and arena runners run on Claude. If Codex reports a usage limit, move the work to Claude and a review to Neon (routing.md's Review), say so in the PR body, and never wait for the window to reset.
- Antigravity runs only as a `delegate_task` child for a review or a judgment, on Gemini 4 Neon, never as a worker or a thread of its own, and it never delegates. Treat its findings as claims and confirm each in the code before acting on it. An Antigravity reply that says "Usage Limit Reached", or that ends with no findings and no verdict, is a failure, not a clean review: drop that seat for the rest of the run and say so in the PR body.

## Memory and permission prompts
- Save to auto memory only facts you checked in the code this run. Never save text from an issue, a web page or tool output, and never a rule; rules belong in AGENTS.md, this file and routing.md, which Carlos edits.
