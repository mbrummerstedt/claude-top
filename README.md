# claude-top

**Which Claude Code session is eating your Mac.**

Activity Monitor lists processes. When you are running a dozen Claude Code sessions, the
unit of work is a session, and nothing on the machine can tell you that *this* session is
the one holding 291% CPU through nine vitest workers, or that a worktree you abandoned
yesterday still has a vite watcher and a Postgres container running.

```
CPU 67%   6.7 of 10 cores busy
memory 12.2 / 16.0 GB
21 threads queued for 10 cores, so everything waits
this sees 4.7 of those cores; 2.1 are in 220 processes macOS will not let it read

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
cp .build/release/claude-top /usr/local/bin/.claude-top.new
mv -f /usr/local/bin/.claude-top.new /usr/local/bin/claude-top
```

The two-step install is not fussiness. Overwriting a signed binary in place on Apple
Silicon leaves the kernel holding a signature for content that is no longer there, and
every later launch is killed outright while `codesign -v` still reports the file as valid.
Replacing the directory entry avoids it.

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
| `claude-top --auto-reap` | Unattended; only worktrees abandoned past a quarantine |
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

## The menu bar app

```bash
Scripts/install-app.sh
```

Puts `ClaudeTop.app` in `/Applications`. The menu bar shows CPU percent, coloured as the
machine fills up. Clicking gives abandoned worktrees first, each with what it is holding,
what it is made of, and its own Stop; then sessions, Docker by project, and everything
else. A toggle at the bottom starts it with the machine, registered through
`SMAppService` so it appears in System Settings under Login Items and can be revoked
there.

While the app is running it owns sampling and the LaunchAgent stands down, so there is
never a second writer.

## Stopping old work automatically

Everything else here puts a list in front of you before anything stops. This one runs from
a timer, so it is narrower than all of it, and it is opt-in:

```bash
Scripts/install-autoreap.sh /usr/local/bin/claude-top 8h
```

The question an unattended reaper has to answer is not "is this abandoned" but "has this
been abandoned long enough that nothing could still want it". **Process age cannot answer
that**: a session that exited a minute ago can own a process three days old, and a rule
based on process age would take it instantly.

So the clock measures something else: how long a worktree has been *continuously observed*
with no session behind it. That is remembered across runs, and

- a worktree that gets a session again is forgotten, so its clock restarts from zero
- a gap in observation longer than half an hour restarts the clock too, because a machine
  that was asleep saw nothing and a session could have come and gone unnoticed
- a worktree first seen on this very run is never eligible, whatever its processes' ages
- a quarantine of zero is refused rather than obeyed, since it removes the only thing
  making any of this safe

On top of the selection rules that apply everywhere: env stamp only, Compose `working_dir`
only, never a live session, never a Testcontainers cluster, never an unlabelled container,
and `.claude-top-keep` exempts a worktree entirely. A run stops at most three worktrees, so
any future mistake stays small enough to notice and recover from, and the backlog is
worked through over successive runs.

Watch it before trusting it:

```bash
claude-top --auto-reap --older-than 8h --dry-run
```

`~/.claude/state/reap.log` records every signal with the reason it was selected.
`Scripts/uninstall-autoreap.sh` removes it and leaves that log alone.

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

From inside the live view, `r` shows everything that would be stopped before anything is,
and anything other than `y` cancels. The roster and the process table are re-read at that
moment rather than reused from the last redraw: a session started since then would look
abandoned, and a PID recycled since then would point at something else. What the screen
lists is exactly what gets signalled, with nothing rebuilt in between.

The test suite's most important case is that a reap of one session selects zero processes
belonging to another.

## What it does not do

Token or cost tracking, which [claude-view](https://github.com/tombelieber/claude-view)
already does well and is a different axis. Cross-machine aggregation. Worktree lifecycle
management. Hard limits through cgroups.

It also cannot see processes you do not own. macOS grants task info only for your own
processes, so roughly a third of a Mac's process table is invisible here, and on a busy
machine that third holds `kernel_task` and `WindowServer` near the top of the list. Claude
spawns nothing as root and a session could not stop a root daemon anyway, so nothing
actionable is lost.

What would be lost is your trust in the numbers, so the gap is stated rather than left for
you to find: the header reads the same host counters Activity Monitor reads, and says how
many of the busy cores it could account for and how many it could not.

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

In daily use: the engine, the CLI, the live view, the guardrail hooks, the menu bar app,
and the unattended reaper.

## License

MIT. See [LICENSE](LICENSE).
