# claude-top

Per-session resource attribution for Claude Code on macOS.

Activity Monitor lists processes. When you are running a dozen Claude Code sessions, the
unit of work is a session, and no tool on the machine can tell you that *this* session is
the one holding 291% CPU through nine vitest workers, or that a worktree you abandoned
yesterday still has a vite watcher and a Postgres container running.

`claude-top` answers that.

```
load 55.6 (10 cores, 5.5x oversubscribed)   mem 10.0/16.0 GB

CLAUDE SESSIONS                                    CPU     RAM  PROC  DOCKER
  reader-app::terms-page                          291%    281M     7       0
    └ 9x vitest worker                            287%
  tradebot::device-identify                       118%    489M    13       3
  platform::qa-testing                              4%     26M     5       1

ORPHANED (worktrees with no live session)          12%    225M    20       1
  feed-service::ui-improvements                     3%     30M     6       2  17h
  platform::qa-testing                              0%     20M     5       1  21h

EVERYTHING ELSE
  Docker VM (13 containers)                       271%    2.3G
  Chrome (47 procs)                                31%    1.5G
```

## How it attributes

Claude Code already stamps every process it spawns with
`CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<session-pid>.sock`. On macOS the environment
of any same-uid process is readable, so that stamp is a lookup rather than a guess, and it
survives both reparenting and the session dying.

Four tiers, first hit wins: env stamp, then process tree, then worktree path, then Docker
Compose and Testcontainers labels. Anything that resolves to a worktree with no live
session is an orphan. Anything that resolves to nothing is reported as unattributed rather
than guessed at.

## Status

Design complete, implementation not started.

Read [`docs/superpowers/specs/2026-09-10-claude-top-design.md`](docs/superpowers/specs/2026-09-10-claude-top-design.md)
first. It has the measurements this is built from, the prior-art survey, and the reasoning
behind every structural choice.

Then read [`docs/IMPLEMENTATION-PLAN.md`](docs/IMPLEMENTATION-PLAN.md) for the task
breakdown.

## Layout

```
Sources/
  ClaudeTopKit/       attribution engine, sampler, SQLite store   (phase 1)
  ClaudeTopCLI/       the `claude-top` binary                     (phase 2)
  ClaudeTopApp/       SwiftUI MenuBarExtra, shipped as a DMG      (phase 3)
Tests/
  ClaudeTopKitTests/
  Fixtures/
    load55-2026-09-10/   real capture from a machine at load 55.6
Scripts/
  capture-fixture.sh  sanitized machine snapshot -> fixture
  make-app.sh         assemble ClaudeTop.app from swift build output
  make-dmg.sh         hdiutil disk image
```

Swift 6, SPM, no third-party dependencies, no Xcode project file. Everything builds from a
terminal with `swift build` and every file is reviewable in git.

## Fixtures

`Tests/Fixtures/load55-2026-09-10/` is a real capture: 648 processes, 44 carrying session
stamps, 5 dead sessions with 27 surviving children, 13 containers spanning all three
container-attribution tiers. That combination is hard to reproduce on demand, which is why
it was captured while the machine was actually on fire.

Regenerate with:

```bash
Scripts/capture-fixture.sh Tests/Fixtures/<name>
```

Capture is sanitized: environment variables are reduced to an allowlist of the four the
engine reads, home paths become `/Users/USER`, session prompt names are dropped, and a
secret scan aborts the capture rather than writing anything token-shaped to disk.

Fixtures still contain real repository and branch names. Decide what that means before
making this repository public.

## Requirements

macOS 14+. Built and tested on macOS 26.6.2, Swift 6.3.3, Xcode 26.6.

`docker` and `claude` on `PATH` are optional. Without them the corresponding attribution
tiers report nothing rather than failing.
