# claude-top — instructions for agents working in this repo

## Read first

1. `docs/superpowers/specs/2026-09-10-claude-top-design.md` — the design, the measurements
   it is based on, and why each structural choice was made. Do not re-litigate decisions
   recorded there without saying so explicitly.
2. `docs/IMPLEMENTATION-PLAN.md` — the task breakdown and the order to do it in.

The design was reached through a brainstorming session with Martin and is approved in
outline. Three questions were left open; they are listed at the bottom of the spec. If your
work runs into one of them, ask rather than picking.

## The one thing that matters

The value of this tool is **correct attribution**. Everything else is presentation.

A number that is confidently wrong is worse than no number, because the whole point is
deciding what to kill. If a process or container cannot be attributed, it goes in the
`unattributed` bucket and is shown as such. Never guess to make the output look tidier.

## Build order, and don't skip ahead

1. `ClaudeTopKit` — engine, store, sampler. Fully tested against fixtures.
2. `ClaudeTopCLI` — the `claude-top` binary.
3. `ClaudeTopApp` — SwiftUI MenuBarExtra and the DMG.
4. Hooks and guardrails.

The engine comes first because it is the only part you can verify by yourself. You can run
the CLI, read its output, and check it against `ps`. You cannot see a menu bar. Do not
start phase 3 while phase 1 has failing or missing tests, and do not report a SwiftUI
target as working on the basis that it compiled.

## Testing

TDD. Write the failing test first, then the code.

The seam is `Snapshot.from(procTable:procEnv:containers:agents:machine:)` — pure inputs,
no I/O. Every attribution rule is testable against `Tests/Fixtures/load55-2026-09-10/`
without touching the live machine.

Fixture facts you can assert against, measured at capture time:

- 648 processes, 44 carrying a `CLAUDE_CODE_MESSAGING_SOCKET` stamp, across 10 session PIDs
- 6 more processes carry no stamp but sit in a worktree, which is why tier 3 exists
- 5 stamped session PIDs are absent from `agents.json`, with 27 surviving child
  processes between them. Those must resolve to `orphan:`, not to `system:`
- 13 containers: 7 with a Compose `working_dir` label, 5 Testcontainers: 3 Postgres carrying distinct
  `org.testcontainers.session-id` values, plus 2 ryuk reapers, 1 with no labels at all
  (`sp-chatroom-pg`) which must land in `unattributed`
- `account-deletion-d7fb2e-db-1` embeds a worktree hash in its container name;
  attribution must still come from the label, not from parsing the name

The most important test in the repo is reap safety: given two live sessions, the reaper for
session A must select zero processes belonging to session B.

## Hard rules

**Never `SIGKILL` as an opening move.** `SIGTERM`, wait 5s, then escalate.

**Reaping is narrow by construction.** Only processes carrying the reaping session's own
env stamp, only compose projects whose `working_dir` label is that session's own worktree.
Never path matches, never ppid matches, never another session's stamp, never a tier-C
unattributed container. Every kill is logged to `~/.claude/state/reap.log` with the reason
it was selected. A `.claude-top-keep` file in a worktree exempts it entirely.

**Do not run destructive commands while developing.** Martin's standing rule across all
repos: the agent does not run `rm -rf`, `git clean`, `git branch -D`, or `kill` on his
machine. Print the full absolute-path command in a bash code block and let him run it. This
applies to testing the reaper too — test it against fixtures, not against his live sessions.

**Never rewrite git history.** No rebase, no force-push, no `reset --hard`. If something
needs changing after the fact, put it in a new commit or a new PR on top.

**No third-party dependencies.** System frameworks only: `libproc`, `sysctl`, `libsqlite3`,
SwiftUI, Charts. If you think you need a package, raise it first.

**Anything shelling out needs a timeout.** `docker stats` returned `--` for every column
during the load-55 capture. A sampler tick must degrade to "container CPU unknown", never
hang.

## Style

Match the surrounding code. Comments explain why, not what.

Prose in this repo, including commit messages and docs, should read as though a person
wrote it: no em dashes, no three-item lists for rhythm, no promotional filler, no
"comprehensive" or "robust" or "seamlessly".

## Commits

Conventional Commits, subject under 50 chars, body only when the why is not obvious.

End commit messages with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```
