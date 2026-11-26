# pstack model configuration (T3). One line per role. Delete a line to fall back to the skill default.
# `inherit-parent` or `auto` as a value: the role runs on the parent chat's model (`delegate_task` omits `target`). Alias entries in a panel list still count toward its fan-out.
# Kept in the dotfiles repo (home/dot_local/share/dotfiles/t3-pstack/models.md) and linked from ~/.config/t3-pstack/models.md. Change it there, never with /t3-pstack:setup-pstack. tests/check-model-sheet.sh checks it.
# defaults: 3
# budget: medium (high)
feature, refactoring: claudeAgent/claude-opus-5-5 effort=high
bug-fix: claudeAgent/claude-opus-5-5 effort=high
perf-issue: claudeAgent/claude-opus-5-5 effort=high
hillclimb: claudeAgent/claude-opus-5-5 effort=high
judgment and prose: claudeAgent/claude-opus-5-5 effort=high
arena runners: claudeAgent/claude-opus-5-5 effort=high, claudeAgent/claude-fable-5-2 effort=high
arena cross-judge pool: codex/gpt-6.2-sol reasoningEffort=medium, antigravity/gemini-4-neon thinking_level=high, claudeAgent/claude-opus-5-5 effort=high
swarm workers: claudeAgent/claude-sonnet-5-5 effort=high
interrogate reviewers: claudeAgent/claude-opus-5-5 effort=high, antigravity/gemini-4-neon thinking_level=high
session hook: on
