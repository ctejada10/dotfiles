Licences for third-party code in this repo. Each modified file says how at its
top.

- home/dot_zsh/prompt.zsh comes from subnixr/minimal, under the GNU General
  Public License, version 3, whose text is GPL-3.0.txt here.
- home/dot_zsh/lib.zsh adapts parts of oh-my-zsh, under the MIT licence; the
  notice is at the top of that file.
- The skills grill-me, grilling, grill-with-docs, domain-modeling,
  improve-codebase-architecture, codebase-design, writing-for-agents and
  to-spec under home/dot_claude/skills come from mattpocock/skills at commit
  5beb35b040e3de97e54fa9e386d7e42d15c295c2, under the MIT licence (Copyright
  (c) 2026 Matt Pocock), whose text is mattpocock-skills-MIT.txt here. The
  SKILL.md files of grilling, to-spec, domain-modeling,
  improve-codebase-architecture and writing-for-agents, plus
  improve-codebase-architecture/HTML-REPORT.md and
  codebase-design/DESIGN-IT-TWICE.md, were modified.
- The agents rpi-codebase-locator, rpi-codebase-analyzer,
  rpi-codebase-pattern-finder and rpi-web-search-researcher under
  home/dot_claude/agents, and the skills rpi-research-codebase,
  rpi-create-plan, rpi-iterate-plan, rpi-implement-plan, rpi-validate-plan,
  rpi-create-handoff, rpi-resume-handoff, rpi-commit and rpi-describe-pr under
  home/dot_claude/skills, are modified versions of files in .claude/agents and
  .claude/commands of humanlayer/humanlayer at commit
  99abe673498cf8bdcd5f989aebe9406a27185b3b, under the Apache License, version
  2.0. humanlayer-Apache-2.0.txt here holds that text with the humanlayer
  copyright line.
- The skills rpi-create-research-questions, rpi-create-research,
  rpi-create-design-discussion and rpi-create-structure-outline are modified
  versions of files in apps/riptide-rpi-claude-plugin/skills of
  humanlayer/humanlayer at commit 3a8dd2d3c1ed01d4fd2282b6dee2075199dffffb,
  under the Apache License, version 2.0. They also inline the show-me guidance
  from apps/riptide-humanlayer-claude-plugin at the same commit.
  humanlayer-NOTICE.txt here is an unmodified copy of that commit's root NOTICE
  file, which Apache-2.0 section 4(d) requires.
- The agents ecc-python-reviewer, ecc-build-error-resolver,
  ecc-silent-failure-hunter and ecc-security-reviewer under
  home/dot_claude/agents are modified copies of agents from affaan-m/ECC at
  commit c05b2d6614f62f6db0047669aa4eefb223d478f9 (tag v2.2.3), under the MIT
  licence (Copyright (c) 2026 Affaan Mustafa), whose text is ecc-MIT.txt here.
- home/dot_claude/skills/github-actions-hardening (SKILL.md and the five files
  in references/) comes from github/awesome-copilot at commit
  df566343b3a685e821f8ebe8ea70a2a8eb8b857b, modified to remove em dashes and
  emoji, under the MIT licence (Copyright GitHub, Inc.), whose text is
  awesome-copilot-MIT.txt here.
- home/dot_claude/skills/i-have-adhd/SKILL.md comes from ayghri/i-have-adhd at
  commit 1ecea19 (tag v0.4.1), under the MIT licence, whose text is
  i-have-adhd-MIT.txt here. It was modified to add one sentence saying the
  correspondence and style rules win over the skill's own steps.

Not copied here, because they carry no licence to copy them under: the
OpenSCAD skill (swh/openscad-skill) and two of George Wang's skills
(georgewangyu/georgeskills). The mini downloads them at pinned commits; see
home/.chezmoidata/pins.yaml.
