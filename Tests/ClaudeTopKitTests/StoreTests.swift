import Testing
import Foundation
@testable import ClaudeTopKit

/// The rolling 24 hours behind `--since` and the statusline.
///
/// About thirty keys at four ticks a minute is 173,000 attribution rows a day, so pruning
/// is not housekeeping to do later: it is what keeps the file small enough that the
/// statusline can read it on every prompt.
@Suite("Store")
struct StoreTests {

    private func temporaryStore() throws -> (ResourceStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("resources.db")
        return (try ResourceStore(path: path.path), directory)
    }

    private func snapshot(at date: Date, load: Double = 55.6,
                          groups: [AttributionGroup] = []) -> Snapshot {
        Snapshot(machine: MachineInfo(cpuCount: 10, memTotalBytes: 17_179_869_184,
                                      memUsedBytes: 10_737_418_240, loadAverage1: load,
                                      capturedAt: date, homeDirectory: "/Users/USER",
                                      processCount: 700),
                 groups: groups)
    }

    private func group(_ key: AttributionKey, label: String, cpu: Double?,
                       rss: UInt64 = 1_048_576, pids: [Int32] = [1]) -> AttributionGroup {
        AttributionGroup(key: key, label: label, tier: .envStamp, cpuPercent: cpu,
                         rssBytes: rss, pids: pids, containerIDs: [])
    }

    // MARK: - keys

    @Test("Attribution keys round-trip through their string form")
    func keyRoundTrip() {
        // The string form is both the SQLite primary key and the `key` field in --json,
        // so a consumer that stored one yesterday must still be able to read it.
        let keys: [AttributionKey] = [
            .session(uuid: "local_abc-123"),
            .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
            .orphan(repo: "", worktree: "session-29449"),
            .system(family: .docker),
            .system(family: .claudeDesktop),
            .unattributed,
        ]
        for key in keys {
            #expect(AttributionKey(storageKey: key.storageKey) == key, "\(key) did not survive")
        }
    }

    @Test("An unreadable key is rejected rather than guessed at")
    func keyRejectsGarbage() {
        #expect(AttributionKey(storageKey: "nonsense") == nil)
        #expect(AttributionKey(storageKey: "system:notafamily") == nil)
        #expect(AttributionKey(storageKey: "orphan:missing-separator") == nil)
    }

    // MARK: - writing and reading

    @Test("A tick written is a tick read back")
    func roundTrip() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        try store.write(snapshot(at: now, groups: [
            group(.session(uuid: "uuid-a"), label: "reader-app::terms-page", cpu: 291),
            group(.system(family: .docker), label: "Docker", cpu: 271),
        ]))

        let latest = try #require(try store.latest())
        #expect(abs(latest.timestamp.timeIntervalSince(now)) < 1)
        #expect(latest.loadAverage1 == 55.6)
        #expect(latest.cpuCount == 10)
        #expect(latest.groups.count == 2)

        let session = latest.groups.first { $0.key == .session(uuid: "uuid-a") }
        #expect(session?.label == "reader-app::terms-page")
        #expect(session?.cpuPercent == 291)
        #expect(session?.processCount == 1)
    }

    @Test("Unknown CPU is stored as unknown, not as zero")
    func unknownCPUSurvives() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(snapshot(at: Date(), groups: [
            group(.session(uuid: "uuid-a"), label: "a", cpu: nil),
        ]))
        #expect(try store.latest()?.groups.first?.cpuPercent == nil)
    }

    @Test("The newest tick is the one returned")
    func latestIsNewest() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let earlier = Date().addingTimeInterval(-60)
        try store.write(snapshot(at: earlier, load: 3))
        try store.write(snapshot(at: Date(), load: 55))
        #expect(try store.latest()?.loadAverage1 == 55)
    }

    @Test("History comes back in order and only from the window asked for")
    func history() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        for minutes in [30, 20, 10, 1] {
            try store.write(snapshot(at: now.addingTimeInterval(Double(-60 * minutes)),
                                     load: Double(minutes)))
        }
        let recent = try store.history(since: now.addingTimeInterval(-15 * 60))
        #expect(recent.map(\.loadAverage1) == [10, 1])
    }

    @Test("Per-process detail is written only for the groups worth explaining")
    func detailThreshold() throws {
        // 24 hours of per-process rows for every group would make the file large enough
        // that the statusline query stops being free.
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        try store.write(snapshot(at: now, groups: [
            group(.session(uuid: "busy"), label: "busy", cpu: 291, pids: [10, 11]),
            group(.session(uuid: "idle"), label: "idle", cpu: 3, pids: [20]),
        ]), processes: [
            ProcessSample(pid: 10, ppid: 1, rssBytes: 1024, cpuTime: 1, startedAt: now, command: "vitest"),
            ProcessSample(pid: 11, ppid: 1, rssBytes: 1024, cpuTime: 1, startedAt: now, command: "vitest"),
            ProcessSample(pid: 20, ppid: 1, rssBytes: 1024, cpuTime: 1, startedAt: now, command: "tsx"),
        ], cpuPercents: [10: 200, 11: 91, 20: 3], detailThreshold: 50)

        let detail = try store.processDetail(at: now)
        #expect(Set(detail.map(\.pid)) == [10, 11])
    }

    @Test("Rows older than the window are pruned on write")
    func pruning() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = Date().addingTimeInterval(-25 * 3600)
        try store.write(snapshot(at: old, load: 1))
        #expect(try store.latest()?.loadAverage1 == 1)

        try store.write(snapshot(at: Date(), load: 2))
        let everything = try store.history(since: Date().addingTimeInterval(-48 * 3600))
        #expect(everything.count == 1, "the 25-hour-old tick should have been pruned")
        #expect(everything.first?.loadAverage1 == 2)
    }

    // MARK: - the CPU baseline

    @Test("The baseline round-trips so a single tick can still measure an interval")
    func baselineRoundTrip() throws {
        // The sampler runs once every fifteen seconds and exits. Without the previous
        // tick's cumulative counters on disk it has nothing to diff against and could
        // only report the lifetime averages this tool exists to avoid.
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let earlier = Date().addingTimeInterval(-15)
        let born = Date().addingTimeInterval(-3600)
        try store.writeBaseline([
            ProcessSample(pid: 42, ppid: 1, rssBytes: 0, cpuTime: 10, startedAt: born, command: "x"),
        ], at: earlier)

        let baseline = try #require(try store.baseline())
        #expect(abs(baseline.readAt.timeIntervalSince(earlier)) < 1)
        #expect(baseline.processes.first?.cpuTime == 10)

        let later = [ProcessSample(pid: 42, ppid: 1, rssBytes: 0, cpuTime: 25,
                                   startedAt: born, command: "x")]
        let cpu = AttributionEngine.cpuPercents(
            earlier: baseline.processes, earlierAt: baseline.readAt,
            later: later, laterAt: earlier.addingTimeInterval(15))
        #expect(abs((cpu[42] ?? 0) - 100) < 1)
    }

    @Test("Writing a baseline replaces the previous one rather than accumulating")
    func baselineReplaces() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.writeBaseline([
            ProcessSample(pid: 1, ppid: 0, rssBytes: 0, cpuTime: 1, startedAt: Date(), command: "a"),
            ProcessSample(pid: 2, ppid: 0, rssBytes: 0, cpuTime: 1, startedAt: Date(), command: "b"),
        ], at: Date())
        try store.writeBaseline([
            ProcessSample(pid: 3, ppid: 0, rssBytes: 0, cpuTime: 1, startedAt: Date(), command: "c"),
        ], at: Date())

        #expect(try store.baseline()?.processes.map(\.pid) == [3])
    }

    @Test("A store with nothing in it answers with nothing rather than failing")
    func emptyStore() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.latest() == nil)
        #expect(try store.baseline() == nil)
        #expect(try store.history(since: Date().addingTimeInterval(-3600)).isEmpty)
    }

    @Test("Reopening the same file finds what was written")
    func persistsAcrossOpens() throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("resources.db").path

        try store.write(snapshot(at: Date(), load: 42))
        let reopened = try ResourceStore(path: path)
        #expect(try reopened.latest()?.loadAverage1 == 42)
    }

    @Test("The database directory is created if it is not there")
    func createsItsDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("nested").appendingPathComponent("r.db").path
        _ = try ResourceStore(path: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
