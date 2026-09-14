# claude-top: instructions for agents working in this repo

`claude-top` attributes CPU, memory, processes and containers to the Claude Code session
that caused them, and stops what is left behind when a session is gone. macOS only, Swift
6, no third-party packages.

## Read first

1. [CONTRIBUTING.md](CONTRIBUTING.md) for the setup, the test layout, the changes that
   get sent back, and the map of what each source file is.
2. `docs/superpowers/specs/2026-09-10-claude-top-design.md` for the design, the
   measurements it is based on, and why each structural choice was made. Do not
   re-litigate decisions recorded there without saying so explicitly.
3. `docs/IMPLEMENTATION-PLAN.md` for how the work was broken down, kept as the record
   of what was built in what order.

Everything the plan describes is built and in daily use: the engine, the CLI and its live
view, the menu bar app, the guardrail hooks, and the unattended reaper. One question from
the spec is still open and is the maintainer's to answer, not yours to pick: whether to
buy a Developer ID certificate. Until it is answered the app is ad-hoc signed, which runs
on the machine that built it and hits Gatekeeper anywhere else.

## The one thing that matters

The value of this tool is **correct attribution**. Everything else is presentation.

A number that is confidently wrong is worse than no number, because the whole point is
deciding what to kill. If a process or container cannot be attributed, it goes in the
`unattributed` bucket and is shown as such. Never guess to make the output look tidier.

The same rule applies to what you say about your own work. "The tests pass" is a claim you
make after running them and reading the output.

## Testing

TDD. Write the failing test first, then the code.

The seam is `AttributionEngine.attribute(...)`, a pure function over listings with no I/O.
Every attribution rule is testable against `Tests/Fixtures/load55-2026-09-10/` without
touching the live machine.

```bash
swift test                        # 311 tests, about 20 seconds
swift test --filter ReapSafety    # the filter matches the type name, not the @Suite name
```

Fixture facts you can assert against, measured at capture time:

- 662 processes, 44 carrying a `CLAUDE_CODE_MESSAGING_SOCKET` stamp, across 10 session PIDs
- 6 more processes carry no stamp but sit in a worktree, which is why tier 3 exists
- 5 stamped session PIDs are absent from `agents.json`, with 27 surviving child
  processes between them. Those must resolve to `orphan:`, not to `system:`
- those children plus their own unstamped descendants make 41 processes in 4 orphan groups
- 13 containers: 7 with a Compose `working_dir` label, 5 Testcontainers (3 Postgres
  carrying distinct `org.testcontainers.session-id` values plus 2 ryuk reapers), and 1
  with no labels at all (`sp-chatroom-pg`) which must land in `unattributed`
- `account-deletion-d7fb2e-db-1` embeds a worktree hash in its container name;
  attribution must still come from the label, not from parsing the name

The most important test in the repo is reap safety: given two live sessions, the reaper for
session A must select zero processes belonging to session B.

## Hard rules

**Never `SIGKILL` as an opening move.** `SIGTERM`, wait 5s, then escalate.

**Unattended reaping is narrow by construction.** Whatever runs without a person watching
it, which is `--auto-reap` and the SessionEnd hook, selects only processes carrying the
reaping session's own env stamp. Never path matches, never ppid matches, never another
session's stamp. `ReapScope.stamped` is that rule and it is the default, so reaching wider
is always something a caller asked for by name.

**A row's Stop button stops that row.** The attended paths, which are the app's rows and
bulk button, `--reap`, and `--watch`, pass `ReapScope.attributed` and select every process
the cascade placed in that group, at whichever tier placed it. The row names the worktree
and lists what it holds before anything is pressed, so the row is the scope a person
agreed to, and a button that signals two thirds of what its row lists is a button nobody
can read.

**Neither scope widens membership.** A process is selected only if the cascade placed it
in the target group, so no scope can reach into another session, a system family, or the
unattributed bucket. Containers are compose `working_dir` only in both, never a
Testcontainers cluster and never a tier-C unattributed one. Every kill is logged to
`~/.claude/state/reap.log` with the reason it was selected. A `.claude-top-keep` file in a
worktree exempts it entirely.

**Do not run destructive commands on the machine you are developing on.** No `rm -rf`, no
`git clean`, no `git branch -D`, no `kill`. Print the full absolute-path command in a bash
code block and let a person run it. This applies to testing the reaper most of all: test
it against the fixtures, never against live sessions, which on a development machine are
the other agents' work and yours.

**Never rewrite git history.** No rebase, no force-push, no `reset --hard`. If something
needs changing after the fact, put it in a new commit or a new PR on top.

**No third-party dependencies.** System frameworks only: `libproc`, `sysctl`, `libsqlite3`,
SwiftUI, Charts. If you think you need a package, raise it first.

**Anything shelling out needs a timeout.** `docker stats` returned `--` for every column
during the load-55 capture. A sampler tick must degrade to "container CPU unknown", never
hang.

**Nothing persists a prompt.** The `name` from `claude agents --json` is the user's own
words. It reaches the terminal table and stops there, not the store, not `--json`, not the
reap log, not a fixture. `Tests/ClaudeTopKitTests/PromptBoundaryTests.swift` holds that
line.

## Working on the app

The SwiftUI target is the one part you cannot check by running it and reading the output.
Compiling is not evidence that it works, and a screenshot of a menu bar is not something
you can take. Put the logic in `ClaudeTopKit` where a test can reach it, keep the view
thin, and say plainly which parts of a change you verified and which a person still has to
look at.

## Style

Match the surrounding code. Comments explain why, not what.

Prose in this repo, including commit messages and docs, should read as though a person
wrote it: no em dashes, no three-item lists for rhythm, no promotional filler, no
"comprehensive" or "robust" or "seamlessly".

Documentation describes what is true now. Git holds the history, so nothing here says
"used to be" or narrates what changed.

## Commits

Conventional Commits, subject under 50 chars, body only when the why is not obvious.

End commit messages with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```
