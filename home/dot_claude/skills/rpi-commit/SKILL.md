---
name: rpi-commit
description: Create git commits with user approval and no Claude attribution
disable-model-invocation: true
---
<!-- From humanlayer/humanlayer at 99abe67, Apache-2.0. Modified: converted the commit command to the rpi-commit skill, added a hard stop for approval before git add or git commit, git add only the named files, follow the repo's own commit style, never push, no attribution trailer of any kind. -->

# Commit Changes

You are tasked with creating git commits for the changes made during this session.

## Process:

1. **Think about what changed:**
   - Review the conversation history and understand what was accomplished
   - Run `git status` to see current changes
   - Run `git diff` to understand the modifications
   - Consider whether changes should be one commit or multiple logical commits

2. **Plan your commit(s):**
   - Identify which files belong together
   - Draft clear, descriptive commit messages
   - Follow the repo's own commit style first: read recent `git log` messages and any commit conventions the repo documents (CLAUDE.md, CONTRIBUTING), and match their format, prefixes and body
   - Use imperative mood in commit messages
   - Focus on why the changes were made, not just what

3. **Present your plan to the user:**
   - List the files you plan to add for each commit
   - Show the commit message(s) you'll use
   - Ask: "I plan to create [N] commit(s) with these changes. Shall I proceed?"
   - Then stop. Do not run `git add` or `git commit` until Carlos approves in a reply.

4. **Execute upon confirmation:**
   - Use `git add` with only the specific files named in the approved plan (never use `-A`, `.` or a directory)
   - Create commits with your planned messages
   - Show the result with `git log --oneline -n [number]`

## Important:
- **NEVER add co-author information or Claude attribution**
- Commits should be authored solely by the user
- Do not include any "Generated with Claude" messages
- Do not add "Co-Authored-By" lines or any other attribution trailer
- Never push
- Write commit messages as if the user wrote them

## Remember:
- You have the full context of what was done in this session
- Group related changes together
- Keep commits focused and atomic when possible
- The user trusts your judgment - they asked you to commit