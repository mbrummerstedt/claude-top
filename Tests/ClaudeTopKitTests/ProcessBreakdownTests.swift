import Testing
import Foundation
@testable import ClaudeTopKit

/// Why a session is heavy, not just that it is.
///
/// A row saying a session holds 239% across 36 processes tells you to worry. A row saying
/// nine of those are vitest workers tells you what to do about it. Every command line
/// below is one that was actually running on the reference machine.
///
/// This is display naming and nothing else. Attribution never consults it, and the
/// fallback is always the honest basename of what was executed.
@Suite("Process breakdown")
struct ProcessBreakdownTests {

    // MARK: - naming

    @Test("A process that rewrote its own argv is read as what it says it is")
    func rewrittenArgv() {
        // vitest workers and postgres backends both replace their command line. There is
        // no executable path left to read, only the words they chose.
        #expect(AttributionEngine.processName(forCommand: "node (vitest)") == "vitest")
        #expect(AttributionEngine.processName(forCommand: "node (vitest 1)") == "vitest")
        #expect(AttributionEngine.processName(forCommand: "postgres: io worker 1") == "postgres")
        #expect(AttributionEngine.processName(forCommand: "postgres: checkpointer") == "postgres")
        #expect(AttributionEngine.processName(
            forCommand: "postgres: sdp sdp_rs_qa ::1(59386) idle") == "postgres")
    }

    @Test("An interpreter is stepped past to reach what it is running")
    func stepsPastInterpreters() {
        // `python` seventeen times and `uv` ten times is what the reference machine gives
        // if you stop at the first token, which is no information at all.
        #expect(AttributionEngine.processName(
            forCommand: "uv run uvicorn app.main:app --reload --port 8047") == "uvicorn")
        #expect(AttributionEngine.processName(
            forCommand: "uv run pytest -m not device and not llm -q") == "pytest")
        #expect(AttributionEngine.processName(
            forCommand: "uv run celery -A product_feed_tool.celery_app worker "
                      + "--loglevel=WARNING --concurrency=2") == "celery")
        #expect(AttributionEngine.processName(
            forCommand: "timeout 900 uv run pytest -q") == "pytest")
    }

    @Test("A package runner is stepped past only when it is running something else")
    func packageRunners() {
        #expect(AttributionEngine.processName(
            forCommand: "node /usr/local/bin/pnpm exec vitest run src/db/batch.db.test.ts")
            == "vitest")
        // `pnpm dev` is pnpm running a script this cannot see into. Naming it after the
        // script name would be inventing a fact.
        #expect(AttributionEngine.processName(
            forCommand: "node /usr/local/bin/pnpm dev --port 5173") == "pnpm")
        #expect(AttributionEngine.processName(
            forCommand: "node /usr/local/bin/pnpm --filter @platform/web dev") == "pnpm")
    }

    @Test("A tool run straight from node_modules is named after itself")
    func nodeModulesBinaries() {
        #expect(AttributionEngine.processName(
            forCommand: "node /Users/USER/r/.claude/worktrees/w-1/web/node_modules/.bin/vite")
            == "vite")
        #expect(AttributionEngine.processName(forCommand: "next-server (v15.5.25)")
            == "next-server")
    }

    @Test("A generic entry point takes its name from the package around it")
    func genericEntryPoints() {
        // `cli.mjs` says nothing. The directory holding it is the package name.
        #expect(AttributionEngine.processName(
            forCommand: "node /Users/USER/r/node_modules/.bin/../tsx/dist/cli.mjs watch src/index.ts")
            == "tsx")
    }

    @Test("Anything unrecognised falls back to what was executed")
    func honestFallback() {
        #expect(AttributionEngine.processName(
            forCommand: "/Applications/Xcode.app/Contents/Developer/usr/bin/make dev") == "make")
        #expect(AttributionEngine.processName(
            forCommand: "infisical run --projectId=abc --env=dev -- bash scripts/dev-stack.sh")
            == "infisical")
        #expect(AttributionEngine.processName(forCommand: "/usr/sbin/cfprefsd") == "cfprefsd")
        #expect(AttributionEngine.processName(forCommand: "") == "?")
    }

    @Test("An executable path containing a space is not cut at the space")
    func pathsWithSpaces() {
        // Observed on this machine: a command under `Library/Application Support` was
        // being named `Application`, because the joined command line had been split back
        // apart on spaces. The real argv has no such ambiguity.
        let withArgv = ProcessSample(
            pid: 1, ppid: 1, rssBytes: 0, cpuTime: 0, startedAt: Date(),
            command: "/opt/homebrew/bin/uv run --directory "
                   + "/Users/USER/Library/Application Support/Claude/ext server",
            arguments: ["/opt/homebrew/bin/uv", "run", "--directory",
                        "/Users/USER/Library/Application Support/Claude/ext", "server"])
        #expect(AttributionEngine.processName(of: withArgv) != "Application")

        let studio = ProcessSample(
            pid: 2, ppid: 1, rssBytes: 0, cpuTime: 0, startedAt: Date(),
            command: "/Applications/Android Studio.app/Contents/MacOS/studio",
            arguments: ["/Applications/Android Studio.app/Contents/MacOS/studio"])
        #expect(AttributionEngine.processName(of: studio) == "studio")
    }

    @Test("Without argv it still falls back to splitting the command")
    func fallsBackWithoutArgv() {
        // Fixtures hold the joined form only, and so does any process whose argv could
        // not be read.
        let joined = ProcessSample(pid: 1, ppid: 1, rssBytes: 0, cpuTime: 0,
                                   startedAt: Date(), command: "node (vitest 3)")
        #expect(AttributionEngine.processName(of: joined) == "vitest")
    }

    @Test("A name containing brackets keeps them")
    func balancedBracketsSurvive() {
        // `(vitest` is a fragment of a rewritten argv and the bracket has to go. `Claude
        // Helper (Renderer)` is what the thing is called, and was losing its closing
        // bracket to a blanket trim.
        let helper = ProcessSample(
            pid: 1, ppid: 1, rssBytes: 0, cpuTime: 0, startedAt: Date(),
            command: "x",
            arguments: ["/Applications/Claude.app/Contents/Frameworks/"
                        + "Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"])
        #expect(AttributionEngine.processName(of: helper) == "Claude Helper (Renderer)")
    }

    @Test("A version directory is not mistaken for a program")
    func versionDirectoriesAreSkipped() {
        // Observed live: `25.2.6-b5b9692` was being reported as though it were the thing
        // running, because the entry point below it was generically named.
        let versioned = ProcessSample(
            pid: 1, ppid: 1, rssBytes: 0, cpuTime: 0, startedAt: Date(), command: "x",
            arguments: ["/opt/tools/platform-tools/25.2.6-b5b9692/bin/main"])
        let name = AttributionEngine.processName(of: versioned)
        #expect(name != "25.2.6-b5b9692")
        #expect(name == "platform-tools")
    }

    // MARK: - grouping

    private func process(_ pid: Int32, _ command: String, rss: UInt64 = 1_048_576)
        -> ProcessSample {
        ProcessSample(pid: pid, ppid: 1, rssBytes: rss, cpuTime: 1, startedAt: Date(),
                      command: command)
    }

    private func group(_ pids: [Int32]) -> AttributionGroup {
        AttributionGroup(key: .session(uuid: "a"), label: "r::w", tier: .envStamp,
                         cpuPercent: 300, rssBytes: 0, pids: pids, containerIDs: [])
    }

    @Test("Identical workers collapse into one row with a count")
    func workersCollapse() {
        // The line the original design mocked up and the reason this exists.
        let processes = (0..<9).map { process(Int32(100 + $0), "node (vitest \($0))") }
        let breakdown = AttributionEngine.breakdown(
            of: group(processes.map(\.pid)), processes: processes,
            cpuPercents: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, 29.0) }))

        #expect(breakdown.count == 1)
        #expect(breakdown.first?.name == "vitest")
        #expect(breakdown.first?.count == 9)
        #expect(breakdown.first?.cpuPercent == 261)
    }

    @Test("Different kinds stay separate and come back heaviest first")
    func heaviestFirst() {
        let processes = [process(1, "node (vitest 0)"), process(2, "node (vitest 1)"),
                         process(3, "uv run uvicorn app:app")]
        let breakdown = AttributionEngine.breakdown(
            of: group([1, 2, 3]), processes: processes,
            cpuPercents: [1: 40, 2: 40, 3: 5])
        #expect(breakdown.map(\.name) == ["vitest", "uvicorn"])
        #expect(breakdown.first?.count == 2)
    }

    @Test("Only the group's own processes are counted")
    func staysInsideTheGroup() {
        let processes = [process(1, "node (vitest 0)"), process(99, "node (vitest 1)")]
        let breakdown = AttributionEngine.breakdown(
            of: group([1]), processes: processes, cpuPercents: [1: 40, 99: 40])
        #expect(breakdown.first?.count == 1)
        #expect(breakdown.first?.pids == [1])
    }

    @Test("An unusable interval leaves the breakdown's CPU unknown")
    func unknownCPU() {
        let processes = [process(1, "node (vitest 0)")]
        let breakdown = AttributionEngine.breakdown(
            of: group([1]), processes: processes, cpuPercents: [:])
        #expect(breakdown.first?.cpuPercent == nil)
        #expect(breakdown.first?.rssBytes == 1_048_576)
    }

    @Test("A group with nothing in it breaks down into nothing")
    func emptyGroup() {
        #expect(AttributionEngine.breakdown(of: group([]), processes: [],
                                            cpuPercents: [:]).isEmpty)
    }

    @Test("Every stamped process in the reference capture gets a name")
    func fixtureNamesEverything() throws {
        let commands = try Fixture.processes().map(\.command)
        for command in commands where !command.isEmpty {
            let name = AttributionEngine.processName(forCommand: command)
            #expect(!name.isEmpty)
            #expect(!name.hasPrefix("-"), "a flag became a name: \(command.prefix(60))")
            #expect(!name.contains("/"), "a path became a name: \(name)")
        }
    }
}
