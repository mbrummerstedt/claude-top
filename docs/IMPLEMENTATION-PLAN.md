# Implementation plan

Read `superpowers/specs/2026-09-10-claude-top-design.md` before starting. This file is the
task breakdown; the spec is the reasoning.

Work top to bottom. Each phase ends with something verifiable from a terminal.

---

## Phase 1 — ClaudeTopKit  (done)

The engine. This is the whole value of the project; everything after it is presentation.

### 1.1 Process table via libproc

Read the process table in-process rather than shelling out. `proc_listpids` for the PID
list, `proc_pidinfo` with `PROC_PIDTASKALLINFO` for RSS, cumulative user and system CPU
time, ppid, uid and start time.

Cumulative CPU time is the field that matters. `ps` `%cpu` is a lifetime average and is
useless for ranking, which is the mistake every number in the spec's problem table makes.

Test: reading the live machine returns a plausible process count and every entry has a
non-negative CPU time.

### 1.2 Environment reads via KERN_PROCARGS2

`sysctl` with `KERN_PROCARGS2` gives argv and environ for any same-uid process. Parse out
`CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_HOST_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`,
and `PWD`. Ignore the rest, and do not retain it: process environments contain tokens.

`CLAUDE_CODE_MESSAGING_SOCKET` is `/tmp/cc-socks/<session-pid>.sock`. The session PID is
the attribution anchor.

Expect failures for processes that exit between listing and reading. Skip them quietly.

Test: against `Tests/Fixtures/load55-2026-09-10/procenv.txt`, 44 processes carry a stamp
across 10 distinct session PIDs, and 6 more have a worktree `PWD` but no stamp. Those 6
are why tier 3 exists.

### 1.3 Live session roster

Shell out to `claude agents --json`, with a timeout. Gives `pid`, `cwd`, `sessionId`,
`startedAt`, `name`. Do not persist `name` anywhere: it is the user's opening prompt.

Derive a display label from `cwd`: `<repo>::<worktree>` for a path under
`<repo>/.claude/worktrees/<worktree>`, otherwise the directory's basename.

Absent or failing `claude` binary means an empty roster, not an error. Every session then
resolves as an orphan, which is correct.

### 1.4 Attribution cascade

```swift
enum AttributionKey: Hashable {
    case session(uuid: String)
    case orphan(repo: String, worktree: String)
    case system(family: SystemFamily)
    case unattributed
}
```

First hit wins:

1. Env stamp — `CLAUDE_CODE_MESSAGING_SOCKET` session PID present in the roster gives
   `.session`; absent from the roster gives `.orphan` derived from the process's `PWD`.
2. Process tree — ppid walk from live session roots.
3. Worktree path — `PWD`, falling back to `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the
   unresolved residue only. Match `**/.claude/worktrees/<name>/**`.
4. Otherwise `.system(family)` by executable path, or `.unattributed`.

Pure function over listings. No I/O in this layer:

```swift
Snapshot.from(procTable:procEnv:containers:agents:machine:)
```

Tests, one per tier plus:

- a process matching several tiers resolves to the highest-priority one
- a stamped process whose session PID is absent from the roster becomes `.orphan`, never
  `.system`
- the five dead session PIDs in the fixture each produce an orphan group

### 1.5 Container attribution

`docker ps --format '{{json .}}'` and `docker inspect <ids>`, both with a timeout.
`docker stats --no-stream` for CPU and memory, also with a timeout: it returned `--` for
every column during the load-55 capture, and a hung `docker` must degrade to "container
CPU unknown" rather than stall a sample tick.

- Tier A: `com.docker.compose.project.working_dir` label to a worktree path.
- Tier B: `org.testcontainers.session-id` clusters containers with their
  `testcontainers/ryuk` reaper, which carries the same id. Group and report as one unit.
  Mapping a cluster to a Claude session means finding the process holding a socket to
  ryuk's published port; that is a stretch goal, not v1. Until then the cluster is grouped
  and unattributed.
- Tier C: everything else is `.unattributed`. Never guessed at, never reapable.

Tests against `Tests/Fixtures/load55-2026-09-10/docker-labels.jsonl`: 7 map by Compose
label, 5 are Testcontainers across 3 session ids, `sp-chatroom-pg` lands in unattributed. The
container named `account-deletion-d7fb2e-db-1` must be attributed from its
label, not by parsing the worktree hash out of its name.

### 1.6 CPU interval calculation

Diff cumulative CPU time between two snapshots, divide by elapsed wall time. Handle PIDs
appearing and disappearing between samples, and clock changes.

Test: two synthetic snapshots with known cumulative times produce the expected percentage.

### 1.7 SQLite store

Schema is in the spec. System `libsqlite3` through a thin wrapper; no SPM package.
`~/.claude/state/resources.db`, WAL mode, rolling 24h pruned on every write.

`proc_detail` rows only for keys above 50% CPU, otherwise 24h of history gets large.

A fourth table, `cpu_baseline`, holds the previous tick's cumulative counters. `--sample`
is a short-lived process and has nothing else to diff against.

Test: write two ticks, read back, confirm pruning drops rows older than 24h.

---

## Phase 2 — claude-top CLI  (done)

Output format is in the spec. Sessions first, then orphans, then everything else. The
"everything else" section is not optional: the single largest CPU consumer measured was
Docker's VM, and a Claude-only view would have hidden it.

Flags: `--json`, `--since <duration>`, `--sample`, `--reap [--dry-run]`, `--watch [n]`.

`--json` is the contract the statusline and the hooks consume. Version it from day one.

Default invocation takes two samples ~700 ms apart for a live CPU reading. `--sample` takes
one and diffs against the previous SQLite row.

### 2.1 LaunchAgent

`StartInterval = 15`, running `claude-top --sample`. Short-lived, not resident. Nothing in
RAM between ticks and a crash self-heals on the next tick.

Pin the binary path absolutely in the plist. Do not rely on `PATH`: this machine has pyenv
shims early in the interactive `PATH` that launchd will not see.

Ship `Scripts/install-agent.sh` and `Scripts/uninstall-agent.sh`. Neither may delete
anything outside `~/Library/LaunchAgents/com.claudetop.sampler.plist`.

### 2.2 Statusline segment

Reads the newest SQLite row, prints load plus this session's share. One indexed query, no
sampling. Identify the current session from this process's own
`CLAUDE_CODE_MESSAGING_SOCKET`.

Must stay under ~50 ms. It runs on every prompt.

---

## Phase 3 — ClaudeTop.app

Only start when phase 1 tests pass and the CLI is in daily use.

`MenuBarExtra` with the current load, a popover listing worst offenders, and a window with
SwiftUI `Charts` over the 24h history. No new logic: the app is a view over the kit.

- `LSUIElement = true`, no Dock icon.
- App Sandbox **off**. Reading other processes' environments and shelling out to `docker`
  and `claude` are both incompatible with it. That rules out the Mac App Store, which is
  fine, because distribution is a DMG.
- `Scripts/make-app.sh` assembles the bundle from `swift build` output plus `Info.plist`.
- `Scripts/make-dmg.sh` uses `hdiutil`. `create-dmg` is not installed and must not become a
  requirement.

When the app is running it samples in-process and the LaunchAgent stands down. There must
never be two samplers writing at once.

**Signing, decide before starting:** this machine has an *Apple Development* certificate
(personal Apple ID, team 436UQCUTNV), not a *Developer ID Application* certificate. Local
installs work with development signing. A DMG that opens cleanly on another machine needs
Developer ID plus notarization, which needs the paid Apple Developer Program. Ask.

You cannot verify this phase by yourself. Compiling is not working. Ask Martin to look.

---

## Phase 4 — guardrails

Reap safety tests come before reap code. The rules are in the spec and in `CLAUDE.md`, and
they are hard constraints.

- **SessionEnd reap** — only that session's own stamped processes and its own compose
  project.
- **PreToolUse parallelism cap** — when load exceeds 2x core count, cap workers on detected
  `vitest`, `jest`, `pytest -n` invocations. The fixture's 9 vitest workers at ~29% each
  are the case this exists for.
- **SessionStart warning** — print current top offenders when load is already
  oversubscribed.

Open question from the spec: whether auto-reap on SessionEnd is wanted at all, given the
standing "no deletions by the agent" rule, or whether phase 4 should stop at manual
`--reap` plus warnings. Confirm before building it.
