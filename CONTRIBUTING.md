# Contributing

Thanks for looking. This is a small tool with one job, and the bar for changes is set by
that job rather than by how much code they add.

## The rule everything else follows from

**Correct attribution is the whole value.** A number that is confidently wrong is worse
than no number, because someone is about to decide what to kill based on it.

If a process or container cannot be attributed, it goes in the `unattributed` bucket and
is shown as such. Do not widen a tier to make the output tidier, and do not parse a name
when a label exists. There is exactly one place in this codebase where a name is parsed
(the Testcontainers reaper, which carries its session id nowhere else), and it is
commented with why.

## Getting set up

```bash
git clone https://github.com/mbrummerstedt/claude-top
cd claude-top
swift test
```

macOS 14+ and a Swift 6 toolchain. There is no Xcode project, deliberately: everything
builds from a terminal and every file is reviewable in a diff. Nothing is fetched on the
first build, because there are no packages to fetch.

Run one suite while you work on it. The filter matches the type name rather than the
display name in `@Suite`:

```bash
swift test --filter ReapSafety
swift test --filter AttributionCascade
```

## Where the code lives

| Path | What it is |
|---|---|
| `Sources/ClaudeTopKit/AttributionEngine.swift` | The cascade. The seam the test suite hangs off |
| `Sources/ClaudeTopKit/Models.swift` | Groups, keys, snapshots, and what `reapable` means |
| `Sources/ClaudeTopKit/ProcessTable.swift` | `libproc`, read in-process rather than shelling out |
| `Sources/ClaudeTopKit/ProcessEnvironmentReader.swift` | `KERN_PROCARGS2`, and the four variables kept |
| `Sources/ClaudeTopKit/ContainerCollector.swift` | Three `docker` calls, each allowed to fail |
| `Sources/ClaudeTopKit/Renderer.swift` | The table, the JSON contract, the statusline |
| `Sources/ClaudeTopKit/Reaper.swift`, `AutoReap.swift` | Selection and signalling, and the quarantine clock |
| `Sources/ClaudeTopKit/ResourceStore.swift` | The rolling 24 hours, in SQLite through the system library |
| `Sources/ClaudeTopCLI/` | The binary and the live view |
| `Sources/ClaudeTopApp/` | The MenuBarExtra app, assembled by `Scripts/make-app.sh` |
| `Tests/Fixtures/load55-2026-09-10/` | A real capture from a machine under load |

The engine holds no I/O. Collectors read the machine, the engine turns those listings into
a snapshot, and the renderer turns a snapshot into output. A change that needs the machine
in order to be tested has usually crossed one of those lines.

## Tests come first

This project is written test-first, and pull requests are expected to be too. Write the
failing test, watch it fail for the reason you expect, then write the code.

The seam is `AttributionEngine.attribute(...)`, a pure function over listings with no I/O.
Every attribution rule is testable against `Tests/Fixtures/load55-2026-09-10/` without
touching the machine you are on. If a change is hard to test there, that usually means the
I/O and the logic have not been separated yet.

Facts the reference capture is pinned to, which your change should not silently alter:

- 662 processes, 44 carrying a session stamp, across 10 session PIDs
- 5 of those session PIDs are gone, with 27 stamped children still running between them
- those children plus their own unstamped descendants make 41 processes in 4 orphan groups
- 13 containers: 7 Compose, 5 Testcontainers across 3 clusters, 1 with no labels at all

If a change moves one of those numbers, say why in the pull request. Sometimes it is
correct for them to move, and it is never correct for them to move quietly.

There are also tests that run against whatever your machine happens to be doing. They
assert shape and internal consistency, never specific numbers, so they pass on an idle
laptop and on one at load 55.

## Things that will get a change sent back

**Third-party dependencies.** System frameworks only: `libproc`, `sysctl`, `libsqlite3`,
SwiftUI, Charts. Raise it first if you think you need a package.

**Shelling out without a timeout.** `docker stats` returned dashes for every column during
the reference capture. Every external command has a deadline and degrades to "unknown".

**Widening an unattended reap.** A timer with nobody reading its list selects processes by
env stamp and by nothing else. Not a path match, not a parent walk. Both of those say
something weaker than a stamp does, and weaker is not enough for something that acts while
you are asleep. An attended stop is the other case and takes the whole group it is shown,
which `ReapScope` carries; adding a caller that reaches wide without a person in front of
it is the thing to stop.

**Letting a stop end in silence.** A stop that signalled nothing has to say so. The panel
reports success by the row disappearing, so a row that stays with nothing beside it reads
as a button that does not work, which is exactly what the silent `continue` on an empty
plan turned it into.

**`SIGKILL` as an opening move.** `SIGTERM`, wait, then escalate.

**Anything that persists a prompt.** The `name` field from `claude agents --json` is the
user's own words. It reaches the terminal table and nothing else. See
`Tests/ClaudeTopKitTests/PromptBoundaryTests.swift`.

**A number with no stated denominator.** Host CPU percent and container CPU percent are
measured against different things and are never added together. If you add a figure to the
output, the reader has to be able to tell what it is a share of.

## Opening a pull request

CI runs `swift build`, `swift test`, a release build, and the binary against the runner
itself on macOS, plus a fixture hygiene scan on Linux. Run the suite locally first. A green
run takes about 20 seconds, so there is no reason to find out from CI.

Worth putting in the description:

- what the change is for, in the terms a user would describe the problem
- which fixture facts moved, if any, and why that is correct
- for anything touching selection or signalling, which test covers the case that it does
  not reach further than intended

Commits follow [Conventional Commits](https://www.conventionalcommits.org/) with a subject
under 50 characters and a body only when the why is not obvious from the diff. Small,
readable commits are easier to accept than one large one.

Contributions are accepted under the MIT license that covers the rest of the project.

## Good places to start

The most useful thing you can bring is an attribution case this misses. If something on
your machine lands in `unattributed` and you can show what it should have been charged to,
that is worth more than any feature. `claude-top --json` shows what the engine concluded.

Podman is the obvious gap in the container tiers. It carries the same Compose labels the
engine already understands, but the collector only ever looks for a `docker` binary, so a
Podman machine reports no containers at all.

The live view could use time on a small terminal. Row allocation is tested, but a real
80x24 window finds things a test does not.

And anything in the output that reads as more certain than it is counts as a bug here,
even when the number happens to be right.

## Fixtures

If you capture a new one, it is anonymized before its first commit, never after. Git
history is forever and this repository is public.

```bash
cp Scripts/anonymize-map.example.json Scripts/anonymize-map.json
# fill in your own repository and container names, and a "forbidden" list
Scripts/capture-fixture.sh Tests/Fixtures/<name>
Scripts/anonymize-fixture.sh Tests/Fixtures/<name>
```

`anonymize-map.json` is gitignored on purpose: it is the reverse lookup, and publishing it
would undo the anonymization. Replacements keep the shape of what they replace, because
path depth, hash suffixes and container naming patterns are what the fixture is for.

CI fails the build if a fixture contains an un-rewritten home directory, a secret-shaped
string, a committed mapping file, or a session prompt.

## Style

Match the surrounding code. Comments explain why, not what.

Prose in this repository, including commit messages and documentation, should read as
though a person wrote it. No em dashes, no three-item lists for rhythm, no promotional
filler, and none of "comprehensive", "robust" or "seamlessly".

## Reporting a bug

Attribution bugs are the ones worth reporting carefully, and they need enough to reproduce
the reasoning rather than just the symptom. `claude-top --json` is usually the fastest way
to show what the engine concluded. There is an
[issue template](.github/ISSUE_TEMPLATE/attribution.md) for exactly that case.

Read [SECURITY.md](SECURITY.md) before opening anything that involves reading another
process's memory or environment, or a reap selecting outside its own session. Those go to
a private advisory rather than a public issue.

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies to everyone taking part.
