import Testing
import Foundation
@testable import ClaudeTopKit

/// The layer that talks to the machine. Parsing is kept separate from launching so the
/// awkward inputs (a `docker stats` that answered in dashes, a `claude` binary that is not
/// installed) are testable without needing to reproduce the conditions that cause them.
@Suite("Collectors")
struct CollectorTests {

    // MARK: - shelling out

    @Test("A command's output comes back")
    func shellCapturesOutput() throws {
        let r = Shell.run("/bin/echo", ["hello"], timeout: 5)
        #expect(r?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("A command that outlives its timeout returns nothing instead of hanging")
    func shellTimesOut() throws {
        // `docker stats` answered in dashes for every column during the reference capture
        // and a hung docker must degrade to "unknown", never stall a sampler tick.
        let started = Date()
        let r = Shell.run("/bin/sleep", ["30"], timeout: 0.4)
        #expect(r == nil)
        #expect(Date().timeIntervalSince(started) < 5, "the timeout did not actually fire")
    }

    @Test("A command that fails returns nothing rather than its error text")
    func shellNonZeroExit() {
        #expect(Shell.run("/usr/bin/false", [], timeout: 5) == nil)
    }

    @Test("A binary that is not installed is not an error")
    func shellMissingBinary() {
        // `docker` and `claude` are both optional. Their absence means the corresponding
        // tier reports nothing, which is a correct answer, not a failure.
        #expect(Shell.run("/nonexistent/claude", ["agents"], timeout: 5) == nil)
    }

    // MARK: - session roster

    @Test("The roster parses and drops the prompt text")
    func rosterParse() throws {
        // `name` is the user's opening prompt. It must not be retained, logged, or stored.
        let json = """
        [{"pid": 1527, "cwd": "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page-63c477",
          "sessionId": "local_abc-123", "startedAt": 1757500000000,
          "name": "fix the thing that keeps breaking in production"}]
        """
        let sessions = SessionRoster.parse(Data(json.utf8))
        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == 1527)
        #expect(sessions.first?.sessionID == "local_abc-123")
        #expect(sessions.first?.startedAt.timeIntervalSince1970 == 1_757_500_000)

        let mirror = String(describing: sessions)
        #expect(!mirror.contains("production"), "prompt text survived into the roster")
    }

    @Test("Malformed roster JSON yields an empty roster, not a crash")
    func rosterMalformed() {
        #expect(SessionRoster.parse(Data("not json".utf8)).isEmpty)
        #expect(SessionRoster.parse(Data("[]".utf8)).isEmpty)
        #expect(SessionRoster.parse(Data("""
            [{"pid": 1, "cwd": "/tmp"}]
            """.utf8)).isEmpty, "a row missing sessionId is unusable")
    }

    @Test("An empty roster means every session resolves as an orphan")
    func emptyRosterIsCorrectNotBroken() {
        // Which is exactly right when `claude` is not installed: nothing on the machine
        // can confirm any session is alive.
        let procs = [ProcessSample(pid: 500, ppid: 1, rssBytes: 0, cpuTime: 0,
                                   startedAt: Date(), command: "/usr/bin/node")]
        let envs: [Int32: ProcessEnvironment] = [500: ProcessEnvironment(
            pid: 500, messagingSocket: "/tmp/cc-socks/100.sock", hostSessionID: nil,
            entrypoint: nil, pwd: "/Users/USER/git_repositories/a/.claude/worktrees/b-123456")]
        let r = AttributionEngine.resolveProcesses(processes: procs, environments: envs, sessions: [])
        #expect(r[500]?.key == .orphan(repo: "a", worktree: "b-123456"))
    }

    // MARK: - containers

    @Test("Container listings parse into labels")
    func containerParse() {
        let ps = """
        {"ID":"313d2a2ef186","Names":"tb-replay-postgres-1","Image":"postgres:17-alpine","Labels":"com.docker.compose.project.working_dir=/Users/USER/git_repositories/tradebot/.claude/worktrees/device-identify-2186f8,com.docker.compose.project=tb-replay"}
        """
        let containers = ContainerCollector.parseContainers(psJSONLines: ps)
        #expect(containers.count == 1)
        #expect(containers.first?.composeWorkingDir?.hasSuffix("device-identify-2186f8") == true)
        #expect(containers.first?.name == "tb-replay-postgres-1")
    }

    @Test("A label value containing a comma is not split into two labels")
    func containerLabelWithComma() {
        // `docker ps` joins labels with commas and does not escape commas inside values,
        // so the split has to stop at the first `=` of each pair rather than trusting the
        // separator. A truncated working_dir would silently misattribute the container.
        let ps = """
        {"ID":"abc","Names":"x","Image":"y","Labels":"description=one, two, three,com.docker.compose.project.working_dir=/Users/USER/git_repositories/r/.claude/worktrees/w-123456"}
        """
        let containers = ContainerCollector.parseContainers(psJSONLines: ps)
        #expect(containers.first?.composeWorkingDir == "/Users/USER/git_repositories/r/.claude/worktrees/w-123456")
    }

    @Test("A container with no labels parses as having no labels")
    func containerNoLabels() {
        let ps = #"{"ID":"abc","Names":"sp-chatroom-pg","Image":"postgres:16","Labels":""}"#
        let containers = ContainerCollector.parseContainers(psJSONLines: ps)
        #expect(containers.first?.labels.isEmpty == true)
    }

    @Test("Stats parse into CPU and memory")
    func statsParse() {
        let stats = """
        {"Container":"313d2a2ef186","CPUPerc":"12.34%","MemUsage":"31.2MiB / 7.65GiB"}
        {"Container":"4f96e10aa0ac","CPUPerc":"0.00%","MemUsage":"1.5GiB / 7.65GiB"}
        """
        let parsed = ContainerCollector.parseStats(statsJSONLines: stats)
        #expect(parsed["313d2a2ef186"]?.cpuPercent == 12.34)
        #expect(parsed["313d2a2ef186"]?.rssBytes == 32_715_571)         // 31.2 MiB
        #expect(parsed["4f96e10aa0ac"]?.rssBytes == 1_610_612_736)      // 1.5 GiB
    }

    @Test("Stats of dashes mean unknown, never zero")
    func statsDashesAreUnknown() {
        // Exactly what the reference capture got back at load 55. Reporting zero would say
        // the container is idle when the truth is that docker could not answer.
        let parsed = ContainerCollector.parseStats(statsJSONLines: """
            {"Container":"313d2a2ef186","CPUPerc":"--","MemUsage":"-- / --"}
            """)
        #expect(parsed["313d2a2ef186"]?.cpuPercent == nil)
        #expect(parsed["313d2a2ef186"]?.rssBytes == nil)
    }

    @Test("Stats that never arrived leave every container unknown")
    func statsMissingEntirely() {
        let containers = ContainerCollector.merge(
            containers: [ContainerInfo(id: "abc", name: "x", image: "y", labels: [:],
                                       cpuPercent: nil, rssBytes: nil)],
            stats: [:])
        #expect(containers.first?.cpuPercent == nil)
        #expect(containers.first?.rssBytes == nil)
    }

    @Test("Stats merge onto the containers they belong to")
    func statsMerge() {
        let merged = ContainerCollector.merge(
            containers: [ContainerInfo(id: "abc123456789", name: "x", image: "y", labels: [:],
                                       cpuPercent: nil, rssBytes: nil)],
            stats: ["abc123456789": (cpuPercent: 5.0, rssBytes: UInt64(1024))])
        #expect(merged.first?.cpuPercent == 5)
        #expect(merged.first?.rssBytes == 1024)
    }

    // MARK: - environment reads

    @Test("The four variables are extracted and everything else is discarded")
    func environmentAllowlist() {
        // Process environments routinely hold API keys and database passwords. Anything
        // outside the allowlist must not survive the read, let alone reach a fixture.
        let block = [
            "PWD=/Users/USER/git_repositories/r/.claude/worktrees/w-123456",
            "CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/1527.sock",
            "CLAUDE_CODE_HOST_SESSION_ID=local_abc",
            "CLAUDE_CODE_ENTRYPOINT=cli",
            "AWS_SECRET_ACCESS_KEY=should-never-appear",
            "DATABASE_URL=postgres://user:hunter2@localhost/db",
        ]
        let env = ProcessEnvironmentReader.extract(pid: 500, environmentEntries: block)
        #expect(env.spawningSessionPID == 1527)
        #expect(env.hostSessionID == "local_abc")
        #expect(env.entrypoint == "cli")
        #expect(env.pwd?.hasSuffix("w-123456") == true)

        let mirror = String(describing: env)
        #expect(!mirror.contains("hunter2"))
        #expect(!mirror.contains("should-never-appear"))
    }

    @Test("A process with none of the four variables yields an empty reading")
    func environmentAbsent() {
        let env = ProcessEnvironmentReader.extract(pid: 500, environmentEntries: ["TERM=xterm"])
        #expect(env.spawningSessionPID == nil)
        #expect(env.pwd == nil)
    }

    @Test("A malformed socket path does not produce a session")
    func environmentMalformedSocket() {
        let env = ProcessEnvironmentReader.extract(
            pid: 500, environmentEntries: ["CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/notanumber.sock"])
        #expect(env.spawningSessionPID == nil)
    }
}
