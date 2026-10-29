# Job search

This laptop does no development; the mini does. Here the work is job hunting.

- career-ops is a Claude Code plugin: run /career-ops:career-ops from any
  folder. Its CV, profile, tracker and reports live in
  ~/.local/share/career-ops, which CAREER_OPS_ROOT names. Never write them
  into the plugin's own folder under ~/.claude/plugins.
- ai-job-search runs inside its checkout in ~/src. Its profile lives in files
  Git tracks, kept as local commits on its own branch; it takes upstream
  releases by merging them. It is never pushed: its push URL goes nowhere and
  a pre-push hook refuses. Never change either.
- cv keeps its applications in git-ignored folders of its checkout.
- These hold my CV, salary expectations and applications. None of it goes
  into a commit message, an issue, a PR or anything that leaves this Mac.
  personal-backup keeps an encrypted copy in Dropbox; never print or move
  the archive's contents anywhere else.
- freehire is a read-only source of postings. Never its account tools.
- /humanizer:humanizer runs only when I ask, for a cover letter or similar.
  Never give it a writing sample with dashes: my no-dash rule wins over its
  section 8.
- Nothing is applied for, submitted or sent without my approval in that
  message, one item at a time.
