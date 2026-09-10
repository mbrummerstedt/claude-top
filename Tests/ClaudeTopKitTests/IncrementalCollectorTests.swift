import Testing
import Foundation
@testable import ClaudeTopKit

/// Re-reading only what changed.
///
/// A tick reads the environment of every process on the machine, which is six hundred
/// `sysctl` calls and most of what a sample costs. In a view that redraws every few
/// seconds that turns the monitor into part of the load it exists to report, which is the
/// objection the design notes raised against a live view in the first place.
///
/// Environments do not change. A process gets them at exec and keeps them, so the only
/// ones worth reading are the ones belonging to processes that were not there last time.
@Suite("Incremental collection")
struct IncrementalCollectorTests {

    private final class Recorder: @unchecked Sendable {
        var table: [ProcessSample] = []
        private(set) var environmentReads: [[Int32]] = []

        func readTable(_ commands: [Int32: String],
                       _ arguments: [Int32: [String]]) -> [ProcessSample] {
            table.map {
                ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssBytes,
                              cpuTime: $0.cpuTime, startedAt: $0.startedAt,
                              command: commands[$0.pid] ?? $0.command,
                              arguments: arguments[$0.pid] ?? [])
            }
        }

        func readEnvironments(_ pids: [Int32])
            -> ([Int32: ProcessEnvironment], [Int32: String], [Int32: [String]]) {
            environmentReads.append(pids.sorted())
            var environments: [Int32: ProcessEnvironment] = [:]
            var commands: [Int32: String] = [:]
            var arguments: [Int32: [String]] = [:]
            for pid in pids {
                environments[pid] = ProcessEnvironment(
                    pid: pid, messagingSocket: "/tmp/cc-socks/\(pid).sock",
                    hostSessionID: nil, entrypoint: nil, pwd: "/tmp")
                commands[pid] = "argv-for-\(pid)"
                arguments[pid] = ["argv-for-\(pid)"]
            }
            return (environments, commands, arguments)
        }
    }

    private func process(_ pid: Int32, born: TimeInterval = 0) -> ProcessSample {
        ProcessSample(pid: pid, ppid: 1, rssBytes: 1024, cpuTime: 1,
                      startedAt: Date(timeIntervalSince1970: 1_000_000 + born),
                      command: "/bin/sleep")
    }

    private func collector(_ recorder: Recorder) -> IncrementalCollector {
        IncrementalCollector(readTable: recorder.readTable,
                             readEnvironments: recorder.readEnvironments)
    }

    @Test("The first pass reads every process")
    func firstPassReadsEverything() {
        let recorder = Recorder()
        recorder.table = [process(1), process(2), process(3)]

        let sample = collector(recorder).collect()
        #expect(recorder.environmentReads == [[1, 2, 3]])
        #expect(sample.environments.count == 3)
    }

    @Test("A second pass over the same processes reads nothing")
    func secondPassReadsNothing() {
        let recorder = Recorder()
        recorder.table = [process(1), process(2), process(3)]

        let collector = collector(recorder)
        _ = collector.collect()
        let sample = collector.collect()

        // Not an empty read: no read at all. Nothing was new, so the syscall never
        // happens, which is the whole saving.
        #expect(recorder.environmentReads == [[1, 2, 3]],
                "the second pass re-read environments that could not have changed")
        #expect(sample.environments.count == 3, "the cached environments were lost")
    }

    @Test("Only processes that are new get read")
    func onlyNewProcessesAreRead() {
        let recorder = Recorder()
        recorder.table = [process(1), process(2)]

        let collector = collector(recorder)
        _ = collector.collect()
        recorder.table = [process(1), process(2), process(7), process(8)]
        let sample = collector.collect()

        #expect(recorder.environmentReads.last == [7, 8])
        #expect(sample.environments.count == 4)
    }

    @Test("A recycled PID is read again rather than trusted")
    func recycledPIDIsReRead() {
        // Same number, different process, different environment. Keeping the old one
        // would attribute a brand new process to whatever session used to hold the pid.
        let recorder = Recorder()
        recorder.table = [process(1), process(2)]

        let collector = collector(recorder)
        _ = collector.collect()
        recorder.table = [process(1), process(2, born: 500)]
        _ = collector.collect()

        #expect(recorder.environmentReads.last == [2])
    }

    @Test("Processes that exited are forgotten")
    func exitedProcessesAreForgotten() {
        // Otherwise the cache grows for as long as the view is open, and a later process
        // inheriting one of those pids finds a stale entry waiting for it.
        let recorder = Recorder()
        recorder.table = [process(1), process(2), process(3)]

        let collector = collector(recorder)
        _ = collector.collect()
        recorder.table = [process(1)]
        let sample = collector.collect()

        #expect(sample.environments.keys.sorted() == [1])
        #expect(collector.cachedProcessCount == 1)
    }

    @Test("Commands survive in the cache, so argv is not re-read either")
    func commandsAreCached() {
        // argv comes from the same syscall as the environment, so caching one caches both.
        let recorder = Recorder()
        recorder.table = [process(1)]

        let collector = collector(recorder)
        _ = collector.collect()
        let sample = collector.collect()
        #expect(sample.processes.first?.command == "argv-for-1")
    }
}
