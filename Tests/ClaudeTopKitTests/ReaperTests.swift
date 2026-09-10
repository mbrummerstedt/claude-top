import Testing
import Foundation
@testable import ClaudeTopKit

/// How a reap is carried out, tested without anything being signalled.
@Suite("Reaper")
struct ReaperTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var signals: [(pid: Int32, signal: Int32)] = []
        var stubbornPIDs: Set<Int32> = []

        func send(_ pid: Int32, _ signal: Int32) -> Bool {
            lock.lock(); defer { lock.unlock() }
            signals.append((pid, signal))
            return true
        }
        func alive(_ pid: Int32) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return stubbornPIDs.contains(pid)
        }
    }

    private func plan(_ pids: [Int32], containers: [String] = []) -> ReapPlan {
        ReapPlan(key: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                 processes: pids.map { ReapTarget(pid: $0, command: "/usr/bin/node",
                                                  reason: "stamp names session 100") },
                 containers: containers.map {
                     ReapComposeTarget(containerID: $0, name: $0,
                                       workingDirectory: "/tmp", reason: "compose working_dir")
                 })
    }

    private func reaper(_ recorder: Recorder, log: URL) -> Reaper {
        Reaper(signaller: { recorder.send($0, $1) },
               isAlive: { recorder.alive($0) },
               stopContainer: { _ in true },
               logURL: log)
    }

    private func temporaryLog() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-reap-\(UUID().uuidString).log")
    }

    @Test("SIGTERM is the opening move, always")
    func termFirst() {
        // A SIGKILL first gives a Postgres no chance to close cleanly and a test runner no
        // chance to remove its temporary directories.
        let recorder = Recorder()
        let log = temporaryLog(); defer { try? FileManager.default.removeItem(at: log) }

        _ = reaper(recorder, log: log).execute(plan([500, 501]), sleeper: { _ in })
        #expect(recorder.signals.allSatisfy { $0.signal == SIGTERM })
        #expect(recorder.signals.map(\.pid) == [500, 501])
    }

    @Test("A process that exits on SIGTERM is never sent SIGKILL")
    func noEscalationWhenItExits() {
        let recorder = Recorder()   // nothing is stubborn, so everything exits
        let log = temporaryLog(); defer { try? FileManager.default.removeItem(at: log) }

        let outcome = reaper(recorder, log: log).execute(plan([500]), sleeper: { _ in })
        #expect(!recorder.signals.contains { $0.signal == SIGKILL })
        #expect(outcome.terminated == [500])
        #expect(outcome.killed.isEmpty)
    }

    @Test("A process still alive after the grace period is escalated")
    func escalatesAfterGrace() {
        let recorder = Recorder()
        recorder.stubbornPIDs = [501]
        let log = temporaryLog(); defer { try? FileManager.default.removeItem(at: log) }

        let outcome = reaper(recorder, log: log).execute(plan([500, 501]), sleeper: { _ in })
        #expect(outcome.killed == [501])
        #expect(recorder.signals.filter { $0.signal == SIGKILL }.map(\.pid) == [501])
    }

    @Test("The grace period is waited out before anything is escalated")
    func waitsBeforeEscalating() {
        let recorder = Recorder()
        recorder.stubbornPIDs = [500]
        let log = temporaryLog(); defer { try? FileManager.default.removeItem(at: log) }

        var slept: [TimeInterval] = []
        _ = reaper(recorder, log: log).execute(plan([500]), gracePeriod: 5,
                                               sleeper: { slept.append($0) })
        #expect(slept == [5])
    }

    @Test("An empty plan signals nothing and waits for nothing")
    func emptyPlanDoesNothing() {
        let recorder = Recorder()
        let log = temporaryLog(); defer { try? FileManager.default.removeItem(at: log) }

        var slept = false
        let outcome = reaper(recorder, log: log)
            .execute(ReapPlan(key: .unattributed, processes: [], containers: []),
                     sleeper: { _ in slept = true })
        #expect(recorder.signals.isEmpty)
        #expect(!slept)
        #expect(outcome == ReapOutcome(terminated: [], killed: [], survived: [],
                                       containersStopped: []))
    }

    @Test("Every signal is written to the log with the reason it was sent")
    func logsEverySignal() throws {
        let recorder = Recorder()
        recorder.stubbornPIDs = [500]
        let log = temporaryLog(); defer { try? FileManager.default.removeItem(at: log) }

        _ = reaper(recorder, log: log).execute(plan([500], containers: ["abc"]),
                                               sleeper: { _ in })
        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("SIGTERM pid=500"))
        #expect(contents.contains("stamp names session 100"))
        #expect(contents.contains("SIGKILL pid=500"))
        #expect(contents.contains("did not exit"))
        #expect(contents.contains("STOP container=abc"))
        #expect(contents.contains("orphan:reader-app::terms-page-63c477"))
    }

    @Test("The log is appended to, not replaced")
    func logAppends() throws {
        let recorder = Recorder()
        let log = temporaryLog(); defer { try? FileManager.default.removeItem(at: log) }

        let r = reaper(recorder, log: log)
        _ = r.execute(plan([500]), sleeper: { _ in })
        _ = r.execute(plan([600]), sleeper: { _ in })

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("pid=500"))
        #expect(contents.contains("pid=600"))
    }
}
