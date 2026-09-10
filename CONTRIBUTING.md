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
builds from a terminal and every file is reviewable in a diff.

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
assert shape and internal consistency, never specific numbers.

## Things that will get a change sent back

**Third-party dependencies.** System frameworks only: `libproc`, `sysctl`, `libsqlite3`,
SwiftUI, Charts. Raise it first if you think you need a package.

**Shelling out without a timeout.** `docker stats` returned dashes for every column during
the reference capture. Every external command has a deadline and degrades to "unknown".

**Widening a reap.** Selection is by env stamp for processes and by the Compose
`working_dir` label for containers, and by nothing else. Not a path match, not a parent
walk. Both of those could cross into a session that is still working. The narrowness costs
something real, and it is worth it.

**`SIGKILL` as an opening move.** `SIGTERM`, wait, then escalate.

**Anything that persists a prompt.** The `name` field from `claude agents --json` is the
user's own words. It reaches the terminal table and nothing else. See
`Tests/ClaudeTopKitTests/PromptBoundaryTests.swift`.

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

Commits follow [Conventional Commits](https://www.conventionalcommits.org/) with a subject
under 50 characters and a body only when the why is not obvious from the diff.

## Reporting a bug

Attribution bugs are the ones worth reporting carefully, and they need enough to reproduce
the reasoning rather than just the symptom. `claude-top --json` is usually the fastest way
to show what the engine concluded.

Read [SECURITY.md](SECURITY.md) before opening anything that involves reading another
process's memory or environment.
