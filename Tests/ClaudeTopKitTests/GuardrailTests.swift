import Testing
import Foundation
@testable import ClaudeTopKit

/// The hooks. Same engine, driven by Claude Code's lifecycle instead of a terminal.
///
/// A single `vitest` run defaults to one worker per core and can saturate a machine on
/// its own. The reference capture caught nine of them at roughly 29% each, which is most
/// of a ten-core laptop spent by one command nobody thought was expensive.
@Suite("Guardrails")
struct GuardrailTests {

    private let cores = 10
    private let busy = 25.0     // 2.5x oversubscribed
    private let calm = 4.0

    // MARK: - when the cap applies at all

    @Test("A calm machine is left alone")
    func calmMachineUntouched() {
        // The cap exists for a machine already in trouble. Applying it always would slow
        // down every test run on a laptop doing nothing.
        #expect(Guardrails.cappedCommand("npx vitest run", loadAverage1: calm,
                                         cpuCount: cores) == nil)
    }

    @Test("The cap engages once load passes twice the core count")
    func thresholdIsTwiceTheCores() {
        #expect(Guardrails.workerCap(loadAverage1: 19, cpuCount: 10) == nil)
        #expect(Guardrails.workerCap(loadAverage1: 21, cpuCount: 10) != nil)
    }

    @Test("The cap leaves at least one worker")
    func capNeverReachesZero() {
        // A cap of zero would not slow a test run down, it would break it.
        for cpuCount in 1...16 {
            let cap = Guardrails.workerCap(loadAverage1: Double(cpuCount) * 10,
                                           cpuCount: cpuCount)
            #expect((cap ?? 1) >= 1, "\(cpuCount) cores produced a cap of \(cap ?? -1)")
        }
    }

    // MARK: - what gets capped

    @Test("vitest, jest and pytest are recognised")
    func recognisedRunners() {
        #expect(Guardrails.cappedCommand("npx vitest run", loadAverage1: busy, cpuCount: cores)
                == "npx vitest run --maxWorkers=2")
        #expect(Guardrails.cappedCommand("npx jest", loadAverage1: busy, cpuCount: cores)
                == "npx jest --maxWorkers=2")
        #expect(Guardrails.cappedCommand("pytest -n auto", loadAverage1: busy, cpuCount: cores)
                == "pytest -n 2")
    }

    @Test("An existing worker count is replaced rather than duplicated")
    func replacesExistingCount() {
        #expect(Guardrails.cappedCommand("pytest -n 16", loadAverage1: busy, cpuCount: cores)
                == "pytest -n 2")
    }

    @Test("A cap the author already chose is respected")
    func respectsAnExplicitCap() {
        // Someone who wrote --maxWorkers=1 knows something the hook does not.
        #expect(Guardrails.cappedCommand("npx vitest run --maxWorkers=1",
                                         loadAverage1: busy, cpuCount: cores) == nil)
        #expect(Guardrails.cappedCommand("npx jest --maxWorkers=4",
                                         loadAverage1: busy, cpuCount: cores) == nil)
    }

    @Test("Runners reached through a package runner are still recognised")
    func throughPackageRunners() {
        for prefix in ["npx", "pnpm exec", "yarn", "bun x", "uv run", "poetry run"] {
            let capped = Guardrails.cappedCommand("\(prefix) vitest run",
                                                  loadAverage1: busy, cpuCount: cores)
            #expect(capped?.hasSuffix("--maxWorkers=2") == true, "\(prefix) was not recognised")
        }
    }

    @Test("A runner invoked by path is recognised")
    func byPath() {
        let capped = Guardrails.cappedCommand("./node_modules/.bin/vitest run",
                                              loadAverage1: busy, cpuCount: cores)
        #expect(capped == "./node_modules/.bin/vitest run --maxWorkers=2")
    }

    // MARK: - what must not get capped

    @Test("A command that merely mentions a runner is not a runner")
    func mentioningIsNotRunning() {
        // The same trap as attributing a process by its arguments. Rewriting someone's
        // grep because the word appears in it would be worse than doing nothing.
        for command in ["grep -r vitest .",
                        "echo 'run vitest to check'",
                        "git commit -m 'speed up jest'",
                        "cat pytest.ini"] {
            #expect(Guardrails.cappedCommand(command, loadAverage1: busy, cpuCount: cores) == nil,
                    "rewrote: \(command)")
        }
    }

    @Test("A wrapper whose underlying runner is unknown is left alone")
    func doesNotGuessThroughScripts() {
        // `npm test` might be vitest, might be a shell script, might be five things in a
        // row. Appending a flag to a guess produces a command that does not run.
        #expect(Guardrails.cappedCommand("npm test", loadAverage1: busy, cpuCount: cores) == nil)
        #expect(Guardrails.cappedCommand("make test", loadAverage1: busy, cpuCount: cores) == nil)
    }

    @Test("pytest without xdist is left alone")
    func pytestWithoutXdist() {
        // -n comes from pytest-xdist. Adding it to a pytest that does not have the plugin
        // installed turns a passing suite into an argument error.
        #expect(Guardrails.cappedCommand("pytest tests/", loadAverage1: busy,
                                         cpuCount: cores) == nil)
    }

    @Test("Only the segment holding the runner is rewritten")
    func rewritesTheRightSegment() {
        let capped = Guardrails.cappedCommand("npm run build && npx vitest run && echo done",
                                              loadAverage1: busy, cpuCount: cores)
        #expect(capped == "npm run build && npx vitest run --maxWorkers=2 && echo done")
    }

    @Test("A command with no runner in any segment is untouched")
    func noRunnerAnywhere() {
        #expect(Guardrails.cappedCommand("swift build && swift test",
                                         loadAverage1: busy, cpuCount: cores) == nil)
    }

    // MARK: - the session start warning

    private func snapshot(load: Double, groups: [AttributionGroup]) -> Snapshot {
        Snapshot(machine: MachineInfo(cpuCount: 10, memTotalBytes: 17_179_869_184,
                                      memUsedBytes: 10_737_418_240, loadAverage1: load,
                                      capturedAt: Date(), homeDirectory: "/Users/USER",
                                      processCount: 700),
                 groups: groups)
    }

    private func group(_ key: AttributionKey, _ label: String, cpu: Double?,
                       procs: Int = 4) -> AttributionGroup {
        AttributionGroup(key: key, label: label, tier: .envStamp, cpuPercent: cpu,
                         rssBytes: 1_048_576, pids: (0..<procs).map { Int32(100 + $0) },
                         containerIDs: [],
                         oldestProcessStartedAt: Date().addingTimeInterval(-72_000))
    }

    @Test("A calm machine produces no warning at all")
    func noWarningWhenCalm() {
        // A hook that speaks every session is a hook people turn off.
        #expect(Guardrails.sessionStartWarning(snapshot(load: 4, groups: [
            group(.session(uuid: "a"), "reader-app::terms-page", cpu: 10),
        ])) == nil)
    }

    @Test("An oversubscribed machine names the worst offenders")
    func warnsWithOffenders() {
        let warning = Guardrails.sessionStartWarning(snapshot(load: 55.6, groups: [
            group(.session(uuid: "a"), "reader-app::terms-page", cpu: 291),
            group(.orphan(repo: "feed-service", worktree: "ui-improvements-053b29"),
                  "feed-service::ui-improvements", cpu: 12),
            group(.system(family: .docker), "Docker", cpu: 271),
        ]))
        let text = try! #require(warning)
        #expect(text.contains("55.6"))
        #expect(text.contains("reader-app::terms-page"))
        #expect(text.contains("Docker"))
    }

    @Test("The warning points at the orphans, because those are free to reclaim")
    func warningHighlightsOrphans() {
        // Stopping a live session costs someone their work. Stopping leftovers of a
        // session that exited yesterday costs nothing, so that is what to say first.
        let warning = Guardrails.sessionStartWarning(snapshot(load: 55.6, groups: [
            group(.session(uuid: "a"), "reader-app::terms-page", cpu: 291),
            group(.orphan(repo: "feed-service", worktree: "ui-improvements-053b29"),
                  "feed-service::ui-improvements", cpu: 12, procs: 20),
        ]))
        let text = try! #require(warning)
        #expect(text.contains("claude-top --reap"))
        #expect(text.contains("20 processes"))
    }

    @Test("No orphans means no reap suggestion")
    func noOrphansNoSuggestion() {
        let warning = Guardrails.sessionStartWarning(snapshot(load: 55.6, groups: [
            group(.session(uuid: "a"), "reader-app::terms-page", cpu: 291),
        ]))
        #expect(warning?.contains("--reap") == false)
    }

    @Test("With no sampler history the load warning still fires")
    func warnsWithoutHistory() {
        // A session opening on a struggling machine before the sampler has ever run is
        // exactly when the warning is most useful, so it must not depend on there being
        // history to name offenders from.
        let warning = Guardrails.sessionStartWarning(snapshot(load: 55.6, groups: []))
        let text = try! #require(warning)
        #expect(text.contains("55.6"))
        #expect(!text.contains("Using the most CPU"), "an empty list of offenders was printed")
    }

    @Test("The warning never carries a session prompt")
    func warningNeverCarriesAPrompt() {
        // It becomes model context and may be written into a transcript.
        let secret = "migrate the billing schema before the audit"
        let withPrompt = AttributionGroup(
            key: .session(uuid: "a"), label: "~", tier: .envStamp, cpuPercent: 291,
            rssBytes: 1024, pids: [100], containerIDs: [], promptPreview: secret)
        let warning = Guardrails.sessionStartWarning(snapshot(load: 55.6, groups: [withPrompt]))
        #expect(warning?.contains(secret) == false)
    }
}
