---
name: Something is attributed wrongly
about: A process or container is charged to the wrong session, or not charged at all
title: ''
labels: attribution
---

**What you expected to be charged where, and what happened instead.**

**Output of `claude-top --json`**, or the part of it covering the group in question.

Please read it before pasting. It contains worktree names and command lines, and command
lines sometimes contain secrets passed as arguments. It does not contain your prompts.

```json

```

**Which tier you think should have caught it.** Skip this if you are not sure.

- [ ] env stamp (`CLAUDE_CODE_MESSAGING_SOCKET`)
- [ ] process tree (parent walk from a live session)
- [ ] worktree path (`PWD` under `.claude/worktrees/`)
- [ ] container label (Compose `working_dir`, or Testcontainers)

**How the process or container was started**, if you know. A shim, a re-exec, a bare
`docker run`, or a Compose file somewhere unusual all land in different tiers.

**Versions**

- `claude-top --version`:
- `claude --version`:
- macOS:
