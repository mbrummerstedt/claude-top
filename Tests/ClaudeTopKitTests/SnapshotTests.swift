import Testing
import Foundation
@testable import ClaudeTopKit

/// Composition: per-process and per-container attributions rolled into the groups the CLI
/// prints and the JSON contract exposes.
@Suite("Snapshot composition")
struct SnapshotTests {

    private func proc(_ pid: Int32, ppid: Int32 = 1, rss: UInt64 = 1_048_576,
                      cmd: String = "/usr/bin/node") -> ProcessSample {
        ProcessSample(pid: pid, ppid: ppid, rssBytes: rss, cpuTime: 1,
                      startedAt: Date(), command: cmd)
    }

    private func env(_ pid: Int32, session: Int32? = nil, pwd: String? = nil) -> ProcessEnvironment {
        ProcessEnvironment(pid: pid,
                           messagingSocket: session.map { "/tmp/cc-socks/\($0).sock" },
                           hostSessionID: nil, entrypoint: nil, pwd: pwd)
    }

    private let worktreeA = "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page-63c477"
    private let worktreeB = "/Users/USER/git_repositories/tradebot/.claude/worktrees/flow-testing-670e04"

    private func machine(load: Double = 55.6) -> MachineInfo {
        MachineInfo(cpuCount: 10, memTotalBytes: 17_179_869_184, loadAverage1: load,
                    capturedAt: Date(), homeDirectory: "/Users/USER")
    }

    private func session(_ pid: Int32, _ cwd: String, uuid: String) -> SessionInfo {
        SessionInfo(pid: pid, cwd: cwd, sessionID: uuid, startedAt: Date())
    }

    private func snapshot(processes: [ProcessSample] = [],
                          environments: [ProcessEnvironment] = [],
                          containers: [ContainerInfo] = [],
                          sessions: [SessionInfo] = [],
                          cpu: [Int32: Double] = [:],
                          machine m: MachineInfo? = nil) -> Snapshot {
        AttributionEngine.attribute(
            processes: processes,
            environments: Dictionary(uniqueKeysWithValues: environments.map { ($0.pid, $0) }),
            containers: containers,
            sessions: sessions,
            cpuPercents: cpu,
            machine: m ?? machine())
    }

    @Test("Processes sharing a key roll into one group")
    func groupsByKey() {
        let s = snapshot(processes: [proc(500, rss: 1000), proc(501, rss: 2000)],
                         environments: [env(500, session: 100), env(501, session: 100)],
                         sessions: [session(100, worktreeA, uuid: "uuid-a")],
                         cpu: [500: 120, 501: 40])
        let group = s.sessions.first
        #expect(s.sessions.count == 1)
        #expect(group?.cpuPercent == 160)
        #expect(group?.rssBytes == 3000)
        #expect(group?.pids.sorted() == [500, 501])
        #expect(group?.label == "reader-app::terms-page")
    }

    @Test("Container CPU and memory are reported apart from process CPU and memory")
    func containerFiguresStaySeparate() {
        // A container's usage is already inside the Docker VM process's. Folding it into
        // the session's own figures would count the same memory twice, and the totals are
        // checked against what the machine has.
        let c = ContainerInfo(id: "db", name: "terms-db-1", image: "postgres:17",
                              labels: ["com.docker.compose.project.working_dir": worktreeA],
                              cpuPercent: 30, rssBytes: 500_000_000)
        let s = snapshot(processes: [proc(500, rss: 1000)],
                         environments: [env(500, session: 100)],
                         containers: [c],
                         sessions: [session(100, worktreeA, uuid: "uuid-a")],
                         cpu: [500: 10])
        let group = try? #require(s.sessions.first)
        #expect(group?.cpuPercent == 10)
        #expect(group?.rssBytes == 1000)
        #expect(group?.containerCPUPercent == 30)
        #expect(group?.containerRSSBytes == 500_000_000)
        #expect(group?.containerIDs == ["db"])
    }

    @Test("A container whose stats are unknown leaves the group's container figures unknown")
    func unknownContainerStats() {
        // `docker stats` returned dashes for every column during the reference capture.
        let c = ContainerInfo(id: "db", name: "terms-db-1", image: "postgres:17",
                              labels: ["com.docker.compose.project.working_dir": worktreeA],
                              cpuPercent: nil, rssBytes: nil)
        let s = snapshot(containers: [c], sessions: [session(100, worktreeA, uuid: "uuid-a")])
        #expect(s.sessions.first?.containerCPUPercent == nil)
        #expect(s.sessions.first?.containerRSSBytes == nil)
    }

    @Test("An unusable interval reports unknown CPU rather than zero")
    func unusableIntervalIsUnknown() {
        // Zero would read as an idle session and rank it at the bottom, which is exactly
        // the wrong answer to give someone deciding what to kill.
        let s = snapshot(processes: [proc(500)], environments: [env(500, session: 100)],
                         sessions: [session(100, worktreeA, uuid: "uuid-a")], cpu: [:])
        #expect(s.sessions.first?.cpuPercent == nil)
    }

    @Test("A group takes the highest-priority tier among its members")
    func groupTierIsTheBestEvidence() {
        // 500 is stamped; 501 only matches by path. The group is as well known as its
        // best-known member.
        let s = snapshot(processes: [proc(500), proc(501)],
                         environments: [env(500, session: 100), env(501, pwd: worktreeA)],
                         sessions: [session(100, worktreeA, uuid: "uuid-a")],
                         cpu: [500: 1, 501: 1])
        #expect(s.sessions.first?.tier == .envStamp)
    }

    @Test("Sessions come first, then orphans, then everything else")
    func blockOrdering() {
        let s = snapshot(
            processes: [proc(500), proc(600), proc(700, cmd: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")],
            environments: [env(500, session: 100), env(600, session: 900, pwd: worktreeB)],
            sessions: [session(100, worktreeA, uuid: "uuid-a")],
            cpu: [500: 1, 600: 999, 700: 500])

        // The orphan and Chrome both out-consume the session. Block order still holds,
        // because "which of my sessions is this" is a different question from "what is
        // using the most CPU" and the output answers the first one.
        let kinds = s.groups.map { key -> String in
            switch key.key {
            case .session: return "session"
            case .orphan: return "orphan"
            case .system: return "system"
            case .unattributed: return "unattributed"
            }
        }
        #expect(kinds == ["session", "orphan", "system"])
    }

    @Test("Within a block, the heaviest consumer is first")
    func withinBlockOrderedByCPU() {
        let s = snapshot(processes: [proc(500), proc(600)],
                         environments: [env(500, session: 100), env(600, session: 200)],
                         sessions: [session(100, worktreeA, uuid: "uuid-a"),
                                    session(200, worktreeB, uuid: "uuid-b")],
                         cpu: [500: 12, 600: 291])
        #expect(s.sessions.map(\.label) == ["tradebot::flow-testing", "reader-app::terms-page"])
    }

    @Test("A session running from the home directory is labelled ~")
    func homeDirectorySession() {
        // Four of the fourteen sessions in the reference capture ran from home. Labelling
        // them with the account name says nothing about which session it is.
        let s = snapshot(processes: [proc(500)], environments: [env(500, session: 100)],
                         sessions: [session(100, "/Users/USER", uuid: "uuid-a")],
                         cpu: [500: 1])
        #expect(s.sessions.first?.label == "~")
    }

    // MARK: - against the reference capture

    private func fixtureSnapshot() throws -> Snapshot {
        let procs = try Fixture.processes().map {
            ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                          cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
        }
        return AttributionEngine.attribute(
            processes: procs,
            environments: try Fixture.environments(),
            containers: try Fixture.containers(),
            sessions: try Fixture.sessions(),
            cpuPercents: Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, 1.0) }),
            machine: try Fixture.machine())
    }

    @Test("Attributed memory never exceeds what the machine has")
    func attributedMemoryFitsInTheMachine() throws {
        let s = try fixtureSnapshot()
        #expect(s.attributedRSSBytes > 0)
        #expect(s.attributedRSSBytes <= s.machine.memTotalBytes,
                "attributed RSS exceeded machine total, which means something is counted twice")
    }

    @Test("Every process and every container lands in exactly one group")
    func nothingDroppedOrDuplicated() throws {
        let s = try fixtureSnapshot()
        let pids = s.groups.flatMap(\.pids)
        #expect(pids.count == 662)
        #expect(Set(pids).count == 662)

        let ids = s.groups.flatMap(\.containerIDs)
        #expect(ids.count == 13)
        #expect(Set(ids).count == 13)
    }

    @Test("The capture yields ten live sessions and four things to clean up")
    func fixtureShape() throws {
        let s = try fixtureSnapshot()
        // Fourteen sessions were live, but only ten of them own any process on the
        // machine beyond themselves; the roster is authoritative, the groups explain it.
        #expect(s.sessions.count >= 10)
        #expect(s.orphans.count == 4)
        #expect(s.orphans.allSatisfy { $0.label.contains("::") })
    }

    @Test("The load figure and oversubscription survive into the snapshot")
    func machineFiguresPreserved() throws {
        let s = try fixtureSnapshot()
        #expect(s.machine.cpuCount == 10)
        #expect(s.machine.oversubscription > 3)
    }
}
