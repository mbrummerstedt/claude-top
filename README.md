# claude-top

**Which Claude Code session is eating your Mac.**

[![CI](https://github.com/mbrummerstedt/claude-top/actions/workflows/ci.yml/badge.svg)](https://github.com/mbrummerstedt/claude-top/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)](#install)
[![Swift 6](https://img.shields.io/badge/swift-6-orange.svg)](Package.swift)

Activity Monitor lists processes. When you are running a dozen Claude Code sessions, the
unit of work is a session, and nothing on the machine can tell you that *this* session is
the one holding 291% CPU through nine vitest workers, or that a worktree you abandoned
yesterday still has a watcher and a Postgres container running.

```
CPU 95%   9.5 of 10 cores busy
memory 12.4 / 16.0 GB
19 threads queued for 10 cores, so everything waits
6.5 of those cores are accounted for below; 3.0 unaccounted
that is kernel time plus 264 processes macOS hides from unprivileged tools
rows below are per-core, as in Activity Monitor: 100% is one core

CLAUDE SESSIONS                                CPU    RAM PROC DOCKER DOCKER CPU
  reader-app::terms-page                      291%   281M    7      0          —
    └ 9x vitest           260%   190M
    └ claude               22%    71M
    └ node                  9%    20M
  tradebot::device-identification             118%   489M   13      3        47%
  feed-service::search-ranking                 36%   232M    5      0          —
  ~ "draft the release notes"                   4%    26M    1      0          —
  TOTAL                                       449%   1.0G   26      3        47%

ORPHANED (worktrees with no live session)      CPU    RAM PROC DOCKER DOCKER CPU   AGE
  tradebot::odds-cache-spike-investigation      6%   143M    5      0          —    2d
  feed-service::ui-improvements                 3%    30M    6      2        34%   17h
  reader-app::help-desk                         3%    32M    4      0          —    1h
  platform::qa-testing                          0%     0M    0      1        18%   21h
  TOTAL                                        12%   205M   15      3        52%

EVERYTHING ELSE                                CPU    RAM PROC DOCKER DOCKER CPU
  Docker                                      120%   2.3G   10      0          —
  Other processes                              30%   1.9G  212      0          —
  Chrome                                       25%   1.5G   47      0          —
  Claude desktop app                           14%   952M   38      0          —
  Unattributed                                  0%     0M    0      1         2%
  TOTAL                                       189%   6.6G  307      1         2%

264 of 612 processes belong to other users and cannot be inspected: their CPU and
memory are missing from every row above
RAM is resident size: pages shared between processes are counted once in each
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

Requires macOS 14 or later and a Swift 6 toolchain, which you get with Xcode or the
Command Line Tools. Nothing else: no packages are fetched, because the project has no
third-party dependencies.

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

There are no prebuilt downloads. You build it yourself, so what runs on your machine is
what you just read. macOS also leaves it alone: quarantine is applied to things that
arrive from the internet, and this one arrives from your own compiler.

Optionally install the sampler so history accumulates and the statusline has something to
read. It runs for a fraction of a second every 15 seconds and keeps a rolling 24 hours.

```bash
Scripts/install-agent.sh /usr/local/bin/claude-top
```

It writes one file, `~/Library/LaunchAgents/com.claudetop.sampler.plist`.

### Uninstall

Every part comes out on its own, and nothing removes your data unless you do:

```bash
Scripts/uninstall-agent.sh                     # the sampler
Scripts/uninstall-autoreap.sh                  # the unattended reaper, if installed
rm -f /usr/local/bin/claude-top                # the binary
rm -rf /Applications/ClaudeTop.app             # the menu bar app, if installed
rm -f ~/.claude/state/resources.db             # the rolling 24h of history
```

## Use

| Command | What it does |
|---|---|
| `claude-top` | Two samples 700ms apart, then the table |
| `claude-top --watch [seconds]` | Live view, redrawn in place, default every 5s |
| `claude-top --json` | The same snapshot as JSON, for hooks and agents |
| `claude-top --since 20m` | History from the rolling 24h store |
| `claude-top --sample` | One sampler tick; what the LaunchAgent runs |
| `claude-top --statusline` | One line for a shell prompt |
| `claude-top --reap` | Stop the leftovers of sessions that are gone |
| `claude-top --auto-reap` | Unattended; only worktrees orphaned past a quarantine |
| `claude-top --hook <event>` | Guardrail hooks; see [docs/HOOKS.md](docs/HOOKS.md) |

`--dry-run` shows what a reap would stop and stops nothing. `--yes` skips the confirmation
for a script that has already decided.

### The live view

`--watch` redraws in place, `q` quits, and `r` offers to stop the orphaned worktrees. The
footer says what the tool itself is costing while you watch it:

```
claude-top 2% cpu, 14M, every 5s  ·  185 processes not inspectable
q quit  ·  r stop the orphaned ones
```

That line is there because the objection to a live view on a machine at load 55 is a real
one, and the answer should be measurable rather than asserted. A redraw re-reads only the
process table. Environments are read once per process and kept, since a process cannot
change them after exec, and the expensive calls to `docker` and the session roster run on
their own slower cycle. Piped or redirected, it prints one table and exits, so
`claude-top --watch | tee` does not fill a file with escape sequences.

### Containers

Compose projects are grouped by the worktree their `working_dir` label points at, so a
container is charged to the work that started it rather than to Docker:

```
DOCKER (7 containers)
  container CPU is measured inside the VM, and is already part of the Docker row
  in EVERYTHING ELSE, not extra to it
  tradebot_devices         tradebot::device-identification                22%    410M     3
  feed_ui_improvements     feed-service::ui-improvements  (stoppable)      4%    180M     2
  platform_qa              platform::qa-testing  (stoppable)               1%     90M     1
  testcontainers 9db46124  unattributed                                    2%    120M     1
  3 containers in 2 orphaned projects can be stopped
```

Container CPU is measured inside the VM and the host sees the VM's own total, which is why
the two are never added together. When `docker stats` does not answer in time, the column
reads `?` rather than `0`.

### For agents

`--json` is a versioned contract, and it is built to be acted on rather than only read.
Every group carries the PIDs behind it and what the tool may do with them:

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
  "containerCpuPercent": 34.0,
  "ageSeconds": 62400,
  "reapable": true,
  "pids": [46341, 46352, 46390]
}
```

The `machine` block carries the headline figures, so a consumer can say what share of the
machine a total represents rather than summing rows and hoping:

```json
{
  "cpuCount": 10,
  "busyPercent": 95.0,
  "busyCores": 9.5,
  "unaccountedCores": 3.0,
  "unreadableProcessCount": 264,
  "processCount": 612
}
```

Every group's `cpuPercent` is per-core, where a process on two cores reads `200`.
`busyPercent` is a share of the whole machine and `busyCores` is the bridge between the
two. `unaccountedCores` is how far the rows fall short of the machine, which is the
measure of how much of it this snapshot actually describes: it holds kernel time,
processes owned by other users, and whatever the sampling window missed, and an
unprivileged tool cannot separate them.

`containerCpuPercent` is measured inside the VM and is never added to `cpuPercent`.

`kind` is the field that says whether anyone is still behind a group: `orphan` means the
session that started it is gone. `reapable` is narrower than it sounds and says only
whether this tool may ever address the group at all, which is true for sessions and their
leftovers and false for system families and unattributed containers. A live session is
`"kind": "session", "reapable": true`, and stopping it would take work that is still
running with it.

`version` is bumped only when a field is removed or changes meaning, so a consumer written
today keeps working when fields are added.

### Statusline

```
load 4.2/10  self 0.1 cores
⚠ load 55.6/10  self 2.9 cores
```

`self` is the session whose shell invoked it, identified by that process's own stamp, so
it works from a Claude Code `statusLine` command and from a shell prompt inside a session.
It reads the newest stored row rather than sampling, so the whole command is one indexed
query and returns in a few hundredths of a second on a machine at load 27. It needs the
sampler or the menu bar app to be running for there to be a row to read. This is the part
Activity Monitor structurally cannot provide, because it has no concept of "this session".

## The menu bar app

```bash
Scripts/install-app.sh
```

Puts `ClaudeTop.app` in `/Applications`. The menu bar shows CPU percent, coloured as the
machine fills up. Clicking gives orphaned worktrees first, each with what it is holding,
what it is made of, and its own Stop; then sessions, Docker by project, and everything
else. A toggle at the bottom starts it with the machine, registered through `SMAppService`
so it appears in System Settings under Login Items and can be revoked there.

Stopping happens in place: a spinner appears where that row's button was and the panel
does not change. Several can be asked for at once, each showing its spinner from the click
rather than from its turn. They are carried out one at a time behind the panel, because
each stop signals a set of processes and waits five seconds for them to go, and a machine
that needs this is not one to run several of those on at once. The row already names the
worktree, how long it has been orphaned, what it is holding and what it is made of, so
the scope is on screen before the button is pressed. Stopping everything keeps its
confirmation, because there the scope is not all visible at once.

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
[SECURITY.md](SECURITY.md) has the full account of what is read, what is written, and how
to report a problem privately.

## Development

```bash
swift test          # 311 tests, most against a committed capture
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

## Contributing

Bug reports and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers the
setup and how the tests are laid out, and it lists the changes that will be sent back with
a reason. Attribution bugs are the most valuable thing you can report, and
`claude-top --json` is usually the fastest way to show what the engine concluded.

[`docs/superpowers/specs/2026-09-10-claude-top-design.md`](docs/superpowers/specs/2026-09-10-claude-top-design.md)
records why each structural choice was made, including the ones that were rejected.
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies to everyone taking part.

## Status

In daily use: the engine, the CLI, the live view, the guardrail hooks, the menu bar app,
and the unattended reaper.

## License

MIT. See [LICENSE](LICENSE).
