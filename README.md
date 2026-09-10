# claude-top

**Which Claude Code session is eating your Mac.**

Activity Monitor lists processes. When you are running a dozen Claude Code sessions, the
unit of work is a session, and nothing on the machine can tell you that *this* session is
the one holding 291% CPU through nine vitest workers, or that a worktree you abandoned
yesterday still has a vite watcher and a Postgres container running.

```
load 55.6 (10 cores, 5.6x oversubscribed)   mem 10.0/16.0 GB

CLAUDE SESSIONS                                         CPU     RAM  PROC  DOCKER
  reader-app::terms-page                                291%    281M     7       0
  tradebot::device-identify                             118%    489M    13       3
  ~ "draft the release notes for 2.4"                     4%     26M     1       0

ORPHANED (worktrees with no live session)                12%    225M    20       1
  reader-app::help-desk                                   3%     32M     4       0    1h
  feed-service::ui-improvements                           3%     30M     6       2   17h
  platform::qa-testing                                    0%     20M     5       1   21h

EVERYTHING ELSE
  Docker                                                271%    2.3G    10       0
  Chrome                                                 31%    1.5G    47       0
  Claude desktop app                                     21%    952M    38       0
  Unattributed                                            0%      0M     0       1

171 processes belong to other users and cannot be inspected
```

Then take the machine back:

```bash
claude-top --reap --dry-run
```

## How it knows

Claude Code already stamps every process it spawns with
`CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<session-pid>.sock`. On macOS the environment
of any process you own is readable, so that stamp turns attribution into a lookup instead
of a guess. Nothing needs wrapping, no shim is installed, and the thing being measured
does not have to cooperate.

Better still, the stamp survives the session dying. On the machine this was built from, 27
processes were still running under sessions that had exited hours earlier, one of them for
22 hours, each still naming the session that started it.

Four tiers, first hit wins:

1. **Env stamp.** The socket path names the spawning session. Survives reparenting and
   survives the session exiting.
2. **Process tree.** A parent walk from live session roots, which catches anything
   re-exec'd through a shim.
3. **Worktree path.** The working directory under `.claude/worktrees/<name>`, which
   catches watchers that lost their environment but never left the directory.
4. **Container labels.** Docker Compose `working_dir`, and Testcontainers clustered with
   the reaper that will clean them up.

Anything resolving to a worktree with no live session is an orphan. Anything resolving to
nothing is reported as unattributed.

That last part is the design rule the rest follows from: **a number that is confidently
wrong is worse than no number**, because the whole point is deciding what to stop. Nothing
is widened a tier to make the output look tidier.

## Install

Requires macOS 14 or later. No dependencies beyond the system frameworks.

```bash
git clone https://github.com/mbrummerstedt/claude-top
cd claude-top
swift build -c release
cp .build/release/claude-top /usr/local/bin/
```

Optionally install the sampler so history accumulates and the statusline has something to
read. It runs for a fraction of a second every 15 seconds and keeps a rolling 24 hours.

```bash
Scripts/install-agent.sh /usr/local/bin/claude-top
```

It writes one file, `~/Library/LaunchAgents/com.claudetop.sampler.plist`.
`Scripts/uninstall-agent.sh` removes it and leaves your data alone.

## Use

| Command | What it does |
|---|---|
| `claude-top` | Two samples 700ms apart, then the table |
| `claude-top --json` | The same snapshot as JSON, for hooks and agents |
| `claude-top --watch 5` | Re-run every 5 seconds |
| `claude-top --since 20m` | History from the rolling 24h store |
| `claude-top --sample` | One sampler tick; what the LaunchAgent runs |
| `claude-top --statusline` | One line for a shell prompt |
| `claude-top --reap` | Stop the leftovers of sessions that are gone |
| `claude-top --hook <event>` | Guardrail hooks; see [docs/HOOKS.md](docs/HOOKS.md) |

There is no full-screen auto-refreshing TUI, deliberately. At load 55 the thing you open to
diagnose the problem should not be competing for the cores you are trying to free, and
`top` already exists.

### For agents

`--json` is a versioned contract, and it is built to be acted on rather than only read.
Every group says whether it can safely be stopped and which PIDs that would mean:

```json
{
  "key": "orphan:feed-service::ui-improvements-053b29",
  "kind": "orphan",
  "label": "feed-service::ui-improvements",
  "tier": "envStamp",
  "cpuPercent": 3.1,
  "rssBytes": 31457280,
  "processCount": 6,
  "containerCount": 2,
  "ageSeconds": 62400,
  "reapable": true,
  "pids": [46341, 46352, 46390]
}
```

### Statusline

```
~/git_repositories/stable  main  load 4.2/10  self 12%
~/git_repositories/stable  main  ⚠ load 55.6/10  self 291%
```

It reads the newest stored row rather than sampling, so it costs one indexed query and
runs in about 10ms. This is the part Activity Monitor structurally cannot provide, because
it has no concept of "this session".

## Guardrails

Two optional hooks, in [docs/HOOKS.md](docs/HOOKS.md). One warns when a session opens on a
machine that is already oversubscribed. The other caps test-runner workers while load is
above twice the core count, because a single `vitest` run defaults to one worker per core
and can saturate a machine by itself.

Both are narrow and both announce themselves. Neither is installed for you.

## Reaping is narrow on purpose

Stopping the wrong thing kills work that was still running, so selection is deliberately
too narrow rather than nearly right:

- Processes are selected **only** by their own env stamp. Never by path, never by parent.
- Containers are selected **only** by a Compose `working_dir` matching that worktree.
- Testcontainers clusters are never selected. Their own reaper handles them.
- Unattributed containers are never selected by anything.
- `SIGTERM`, wait 5 seconds, then escalate. Never `SIGKILL` as an opening move.
- A `.claude-top-keep` file in a worktree exempts it entirely.
- Every signal is appended to `~/.claude/state/reap.log` with the reason it was selected.
- `--reap` confirms interactively and defaults to no.

The test suite's most important case is that a reap of one session selects zero processes
belonging to another.

## What it does not do

Token or cost tracking, which [claude-view](https://github.com/tombelieber/claude-view)
already does well and is a different axis. Cross-machine aggregation. Worktree lifecycle
management. Hard limits through cgroups.

It also cannot see processes you do not own. macOS grants task info only for your own
processes, so roughly a third of a Mac's process table is invisible here. Claude spawns
nothing as root and a session could not stop a root daemon anyway, so nothing useful is
lost, but the output tells you the count rather than quietly leaving a gap.

## Privacy

This tool reads other processes' environments, which routinely hold API keys and database
passwords. Four variables are extracted and nothing else is copied out of the buffer:
`CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_HOST_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`
and `PWD`.

Your opening prompt is shown in the terminal table for sessions that have no worktree to
be named after, because otherwise they are indistinguishable. It is never written to the
database, never in `--json`, never in the reap log, and never in a fixture.
`Tests/ClaudeTopKitTests/PromptBoundaryTests.swift` is what keeps that true.

Nothing leaves your machine. There is no telemetry and no network code.

## Development

```bash
swift test          # 191 tests, most against a committed capture
swift build -c release
```

The engine is a pure function over listings, so every attribution rule is tested against
`Tests/Fixtures/load55-2026-09-10/` without touching the live machine. That capture is a
real one taken while a laptop was struggling: 662 processes, 44 carrying session stamps, 5
dead sessions with 27 surviving children, and 13 containers spanning every container tier.
That combination is hard to reproduce on demand, which is why it was captured while the
machine was actually on fire.

Fixtures are anonymized before their first commit by `Scripts/anonymize-fixture.sh`, and
CI fails the build if an un-rewritten home directory, a secret-shaped string, or a session
prompt ever reaches one.

See [CONTRIBUTING.md](CONTRIBUTING.md) to work on it, and
[`docs/superpowers/specs/2026-09-10-claude-top-design.md`](docs/superpowers/specs/2026-09-10-claude-top-design.md)
for why each structural choice was made.

## Status

The engine, the CLI and the guardrail hooks work. The menu bar app is not built yet.

## License

MIT. See [LICENSE](LICENSE).
