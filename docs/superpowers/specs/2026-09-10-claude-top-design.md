# claude-top: per-session resource attribution for Claude Code

Date: 2026-09-10
Status: design, awaiting review
Author: brainstormed with Martin, implementation handed to a fresh agent

## Problem

Running ~14 concurrent Claude Code sessions on a 16 GB / 10-core MacBook takes the machine
to a load average of 55, roughly 5.5x oversubscribed. Activity Monitor cannot say which
session is responsible, because it lists processes and the unit of work here is a session.

Measured on this machine on 2026-09-10 at load 55.6, 608 processes, 9.95 GB total RSS:

| Bucket | RSS | Notes |
|---|---|---|
| Docker (13 containers, 6 of them Postgres) | 2.3 GB | `com.docker.krun` at 188-271% CPU. Two containers up ~47h. |
| Claude Code CLI (14 sessions) | 1.6 GB | The part that visibly reads as "Claude". |
| Chrome (47 procs) | 1.5 GB | |
| Claude desktop app (38 procs) | 952 MB | |
| python/uv (28 procs) | 618 MB | |
| node (14 procs) | 457 MB | Includes 9 vitest workers at ~25-30% CPU each. |
| Orphaned worktree processes (20 procs) | 225 MB | vite, tsx watch, uvicorn. Uptimes 16-22h, no live parent session. |

Two conclusions drive the design. Memory is not the binding constraint, 10 of 16 GB. CPU
is, and the largest consumers are not the `claude` processes but the things sessions start:
container databases, test-runner worker pools, and file watchers that outlive the session
that spawned them.

## Why not use something that exists

| Tool | What it is | Gap |
|---|---|---|
| [claude-view](https://github.com/tombelieber/claude-view) | Rust + React dashboard over `~/.claude/projects/` JSONL. Tokens, cost, sub-agents, hooks. | Transcript-based. CPU/RAM gauges are machine-level with no per-session attribution. |
| [ClaudeCodeMonitor](https://github.com/Aura-Technologies-llc/ClaudeCodeMonitor) | Python + rumps menu bar, psutil. Per-instance CPU/mem. 44 stars. | Measures the `claude` processes only. No subprocess rollup, no Docker, no orphans, which is 75% of the load here. |
| [claude-resource-limiter](https://github.com/kmshdev/claude-resource-limiter) | `nice`/QoS wrapper plus a killer daemon at 150% CPU / 4 GB. 0 stars. | Per-process limits with no child tracking. Killing a `claude` process leaves its 9 vitest workers running. |
| [Docktree](https://docktree.dev/), [DevTree](https://github.com/pwrmind/DevTree) | Worktree-scoped Compose, `docktree clean` reclaims orphaned containers. | Solves containers, knows nothing about Claude sessions, and would require restructuring how every repo does compose. |

The monitoring tools stop at the `claude` process. The worktree tools stop at containers.
Nothing joins the two, which is where the load actually lives.

Native Claude Code CLI, verified against 2.1.260, offers `claude agents`, `stop`, `rm` for
background sessions. There is no `claude ps` and no resource reporting of any kind.

## Key finding: sessions already stamp their children

Claude Code exports `CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<session-pid>.sock` and
`CLAUDE_CODE_HOST_SESSION_ID=local_<uuid>` into the environment of every process it spawns.
On macOS the environment of any same-uid process is readable, via `ps eww` from a shell or
`sysctl KERN_PROCARGS2` natively.

Verified across every process on this machine. In the committed fixture, 44 processes
carry a session stamp across 10 distinct session PIDs, and 5 of those PIDs no longer
exist. Between them those dead sessions had 27 children still running, some for 22 hours,
each still naming the session that spawned it.

The stamp survives reparenting and survives the session dying. That turns attribution into
a lookup rather than a heuristic, with no wrapper scripts, no shims, and no cooperation
required from the thing being measured.

## Language and shape

Swift, one SPM package, three targets. No third-party dependencies.

```
ClaudeTopKit     library      attribution engine, sampler, SQLite store
claude-top       executable   CLI over the kit
ClaudeTop.app    SwiftUI      MenuBarExtra + Charts, shipped as a DMG
```

Swift rather than a script because the engine reads process tables tens of times a minute.
`libproc` (`proc_listpids`, `proc_pidinfo`) and `sysctl(KERN_PROCARGS2)` give process,
memory, CPU-time and environment data in-process. Shelling out to `ps eww` once per PID,
which is what the fixture-capture script does, takes seconds for 600 processes and is not
viable at a 15-second sampling interval.

No Xcode project file. The app bundle is assembled by `Scripts/make-app.sh` from
`swift build` output plus an `Info.plist`. A menu bar app needs no storyboards or nibs, and
keeping everything in SPM means every file is reviewable in git and buildable from a
terminal, which matters because an agent is doing the implementation.

### Build order, and why the app is last

1. **`ClaudeTopKit`** with fixtures and tests. The hard part.
2. **`claude-top` CLI.** The tool that gets used day to day, and the thing hooks call.
3. **`ClaudeTop.app`** and the DMG.

The attribution cascade is where every bug will live, and it is fully verifiable from a
terminal: run the CLI, compare against `ps`, assert. A SwiftUI menu bar app is not
verifiable that way. An agent can make it compile and report success while the popover
renders blank. Building the engine first means the app is a thin shell over something that
already provably works, and nothing gets thrown away.

The CLI is also required regardless of the app, because phase 4's guardrails are hooks, and
hooks execute commands.

## Architecture

```
                    ┌──────────────────────┐
                    │  AttributionEngine   │
                    │   -> Snapshot        │
                    └───────────┬──────────┘
                                │
              ┌─────────────────┼──────────────────┐
              │                 │                  │
       ┌──────▼──────┐   ┌──────▼──────┐    ┌──────▼──────┐
       │  Sampler    │   │ claude-top  │    │ ClaudeTop   │
       │  (15s tick) │   │    CLI      │    │   .app      │
       └──────┬──────┘   └─────────────┘    └─────────────┘
              │
       ┌──────▼───────────────────┐
       │ ~/.claude/state/         │
       │   resources.db (SQLite)  │
       │   rolling 24h            │
       └──────────────────────────┘
```

### Attribution engine

Produces a `Snapshot`: every process and container on the machine assigned an attribution
key, plus machine totals.

```swift
enum AttributionKey: Hashable {
    case session(uuid: String)            // live session
    case orphan(repo: String, worktree: String)  // worktree, session gone
    case system(family: SystemFamily)     // docker, chrome, claudeDesktop, other
    case unattributed                     // honest about what it cannot place
}
```

Resolution is a cascade, first hit wins:

1. **Env stamp.** `KERN_PROCARGS2` for every PID. Extract `CLAUDE_CODE_MESSAGING_SOCKET`,
   which yields the spawning session's PID, and `CLAUDE_CODE_HOST_SESSION_ID`.
   Authoritative, survives reparenting and session death.
2. **Process tree.** Walk ppid from each live session root. Catches processes that lost
   their environment, for example anything re-exec'd through a shim.
3. **Worktree path.** `PWD` from the same `KERN_PROCARGS2` read, falling back to
   `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the residue. Matches
   `**/.claude/worktrees/<name>/**`. This tier catches the vite and tsx watchers that carry
   no stamp because they were re-exec'd.
4. **Container.** See below.

Anything resolving to a worktree with no live session becomes `orphan:`.

Live sessions come from `claude agents --json`, which returns `pid`, `cwd`, `sessionId`,
`startedAt` and the opening prompt as a name. That is the authoritative roster; the cascade
only has to explain the processes.

### Container attribution

Measured on the fixture: 7 of 13 containers map cleanly, 6 do not. The design is honest
about the remainder rather than guessing.

- **Tier A, Compose.** `com.docker.compose.project.working_dir` label maps directly to a
  worktree path. Covers 7 of 13 here, including
  `account-deletion-d7fb2e-db-1`, whose name even embeds the worktree hash.
- **Tier B, Testcontainers.** Containers carrying `org.testcontainers.session-id` cluster
  with their `testcontainers/ryuk` reaper, which shares the id. Covers 5 of the remaining 6.
  Shown as one unit per testcontainers session. Resolving that cluster to a Claude session
  requires finding the process holding a socket to ryuk's published port, which is a
  stretch goal, not v1. Until then the cluster is shown grouped and unattributed.
- **Tier C, unattributed.** Everything left, one container here (`sp-chatroom-pg`, no labels
  at all, started by bare `docker run --name`). Reported in "everything else", never
  guessed at, and never eligible for reaping.

Container CPU and memory come from `docker stats --no-stream`, which must run with a
timeout: it returned `--` for every column during the load-55 capture and cannot be
allowed to block a sample tick.

### CPU measurement

`ps` reports `%cpu` as an average over process lifetime, which is why a session that
finished a test run an hour ago still reads high while the one currently melting a core
reads low. Every number in the earlier "problem" table has that flaw and should not be
trusted for ranking.

The engine reads cumulative CPU time from `proc_pidinfo` and diffs consecutive samples,
dividing by elapsed wall time. Interval CPU%, not lifetime average. The one-shot CLI takes
two samples ~700 ms apart; the sampler diffs against the previous row in SQLite.

### Store

`~/.claude/state/resources.db`, SQLite via the system `libsqlite3`, rolling 24 hours.

```sql
CREATE TABLE sample (ts INTEGER PRIMARY KEY, load1 REAL, ncpu INTEGER,
                     mem_used_mb INTEGER, mem_total_mb INTEGER);

CREATE TABLE attribution (ts INTEGER, key TEXT, label TEXT, kind TEXT,
                          cpu_pct REAL, rss_mb INTEGER,
                          n_proc INTEGER, n_container INTEGER,
                          PRIMARY KEY (ts, key));

-- per-process detail, written only for keys above the detail threshold,
-- so 24h of history stays small
CREATE TABLE proc_detail (ts INTEGER, key TEXT, pid INTEGER,
                          cpu_pct REAL, rss_mb INTEGER, cmd TEXT);
```

About 30 keys at 4 samples/minute is ~173k attribution rows/day. Detail rows only for keys
above 50% CPU. `DELETE FROM ... WHERE ts < now-24h` on every tick.

### Sampler

A `LaunchAgent` with `StartInterval = 15` running `claude-top --sample`, a short-lived
process rather than a resident daemon. Nothing sits in RAM between ticks, a crash
self-heals on the next tick, and there is no long-lived process to leak or to audit later.
This is deliberate: a previous tool on this machine (claude-mem) burned enormous resources
through always-on background hooks, and the lesson taken from it was to prefer short-lived,
inspectable work.

When `ClaudeTop.app` is running it samples in-process on the same interval and the
LaunchAgent stands down, so there is never a double sampler.

### CLI

```
load 55.6 (10 cores, 5.5x oversubscribed)   mem 10.0/16.0 GB

CLAUDE SESSIONS                                    CPU     RAM  PROC  DOCKER
  reader-app::terms-page                          291%    281M     7       0
    └ 9x vitest worker                            287%
  tradebot::device-identify                       118%    489M    13       3
  platform::qa-testing                              4%     26M     5       1
  ...

ORPHANED (worktrees with no live session)          12%    225M    20       1
  reader-app::help-desk                             3%     32M     4       0   1h
  feed-service::ui-improvements                     3%     30M     6       2  17h
  platform::qa-testing                              0%     20M     5       1  21h

EVERYTHING ELSE
  Docker VM (13 containers)                       271%    2.3G
  Chrome (47 procs)                                31%    1.5G
  Claude desktop app (38 procs)                    21%    952M
  Testcontainers session 30ec6daa (2 containers)    2%     94M
  Unattributed (1 container)                        0%     31M
```

Flags:

- `--json` machine-readable snapshot, the interface hooks and the statusline consume
- `--since <duration>` history from SQLite, e.g. `--since 20m`
- `--sample` one sampler tick, what the LaunchAgent calls
- `--reap [--dry-run]` list orphans, confirm, then kill
- `--watch [n]` re-run every n seconds, a plain loop

No auto-refreshing full-screen TUI. At load 55 the thing you open to diagnose the problem
should not be competing for the cores you are trying to free, and `top` already exists.

### Statusline

A segment showing machine load and this session's own share, so the climb is visible before
it becomes a crisis. Reads the newest SQLite row rather than sampling, so it costs one
indexed query.

```
~/git_repositories/stable  main  load 4.2/10  self 12%
~/git_repositories/stable  main  ⚠ load 55.6/10  self 291%
```

This is the part Activity Monitor structurally cannot provide, because it has no concept of
"this session".

### ClaudeTop.app

`MenuBarExtra` showing current load, with a popover listing the worst offenders and a main
window using SwiftUI `Charts` for the 24h history. Same engine, no new logic.

Constraints that matter:

- **App Sandbox must be off.** Reading other processes' environments and shelling out to
  `docker` and `claude` are both incompatible with it. That rules out the Mac App Store,
  which is fine because distribution is a DMG.
- **Signing.** This machine has an *Apple Development* certificate (personal Apple ID, team
  436UQCUTNV) but not a *Developer ID Application* certificate. Local installs work with
  development signing. A DMG that opens on another machine without a Gatekeeper warning
  needs Developer ID plus notarization, which needs the paid Apple Developer Program.
  Decide before phase 3; do not block phases 1 and 2 on it.
- `LSUIElement = true` so no Dock icon.
- Minimum target macOS 14. This machine runs 26.6.2 with Swift 6.3.3 and Xcode 26.6.

`Scripts/make-app.sh` assembles the bundle, `Scripts/make-dmg.sh` builds the disk image
with `hdiutil` (`create-dmg` is not installed and is not a required dependency).

## Phase 4: guardrails

Same engine, driven by hooks instead of a terminal.

- **SessionEnd reap.** On exit, kill processes carrying that session's own stamp and bring
  down that session's own compose project.
- **PreToolUse parallelism cap.** When load already exceeds 2x core count, inject a worker
  cap into detected test-runner invocations (`vitest`, `jest`, `pytest -n`). A single
  vitest run defaults to one worker per core and can saturate the machine alone, which is
  exactly what the 9 workers in the fixture are.
- **SessionStart warning.** If load is already oversubscribed, print the current top
  offenders before a fifteenth session gets added.

### Safety constraints on reaping

Hard constraints, not preferences. The standing rule in this setup is that the agent does
not delete on the user's behalf. Auto-reap is a deliberate, narrow exception and must stay
narrow.

1. The SessionEnd hook may only kill processes whose env stamp names **its own** session.
   Never a path match, never a ppid match, never another session's stamp.
2. It may only bring down a compose project whose `working_dir` label is **its own**
   worktree.
3. Tier-C unattributed containers are never eligible for reaping, by anything.
4. It never touches files, branches, or worktrees. Processes and containers only.
5. `SIGTERM`, wait 5s, then `SIGKILL`. Never `SIGKILL` as an opening move.
6. Every kill appends to `~/.claude/state/reap.log` with timestamp, pid, command, and the
   reason it was selected.
7. A `.claude-top-keep` file in a worktree exempts it entirely.
8. `claude-top --reap`, the manual path, confirms interactively and defaults to no.

## Non-goals

- Token or cost tracking. claude-view does that well and it is a different axis.
- Cross-machine aggregation. This is about one laptop's contended cores.
- Hard limits via cgroups or macOS containerization. Revisit if the parallelism cap proves
  insufficient.
- Managing worktree lifecycle, creation, or pruning. Docktree's territory.
- Mac App Store distribution. Sandboxing forbids what this tool does.

## Testing

The engine's inputs are process, environment and container listings, so that is the seam:

```swift
Snapshot.from(procTable:procEnv:containers:agents:machine:)
```

Fixtures live in `Tests/Fixtures/load55-2026-09-10/`, captured from this machine at load
37.9 by `Scripts/capture-fixture.sh`. They are a realistic corpus: 648 processes, 81 with
session stamps, 5 dead sessions with 27 surviving children, 13 containers across all three
attribution tiers. Capture is sanitized by an environment-variable allowlist, home paths
are rewritten to `/Users/USER`, session prompt names are dropped, and a secret scan fails
the capture rather than writing anything token-shaped to disk.

Cases that must be covered:

- One test per cascade tier, plus a process matching several tiers resolving to the
  highest-priority one.
- A stamped process whose session pid is absent becomes `orphan:`.
- CPU diffing: two synthetic samples with known cumulative times produce the expected
  interval percentage.
- **Reap safety, the test that matters most:** given a snapshot with two live sessions, the
  SessionEnd reaper for session A selects zero processes belonging to session B, and zero
  tier-C containers.
- Container tiers: compose `working_dir` to worktree, testcontainers clustering by
  session-id including the ryuk reaper, and a no-label container landing in unattributed.
- `docker stats` timing out leaves container CPU unknown rather than failing the snapshot.

An integration test runs a real sample against the live machine and asserts that total
attributed RSS never exceeds machine total.

## Open questions for review

1. Approve CLI-before-app ordering, or insist the app comes first?
2. Is auto-reap on SessionEnd wanted at all, given the standing "no deletions by the agent"
   rule, or should phase 4 stop at `--reap` plus warnings?
3. Developer ID certificate: worth the paid program for a personal tool, or is development
   signing plus a local install enough?
