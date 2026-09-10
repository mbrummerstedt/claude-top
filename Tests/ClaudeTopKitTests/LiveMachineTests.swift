import Testing
import Foundation
@testable import ClaudeTopKit

/// Against the machine this is running on, rather than against the capture.
///
/// Fixtures pin down the awkward cases; these check that the readers are pointed at
/// something real. They assert shape and internal consistency, never specific numbers,
/// because the numbers are whatever the machine happens to be doing.
@Suite("Live machine", .serialized)
struct LiveMachineTests {

    @Test("The process table reads")
    func processTableReads() {
        let processes = ProcessTable.current()
        #expect(processes.count > 50, "a Mac runs more processes than this")
        // launchd is deliberately absent. macOS grants task info only for your own
        // processes, so the table covers this user and stops there.
        #expect(!processes.contains { $0.pid == 1 })
        #expect(processes.allSatisfy { $0.cpuTime >= 0 })
        #expect(processes.allSatisfy { $0.startedAt.timeIntervalSince1970 > 0 })
        #expect(processes.contains { $0.rssBytes > 0 })
    }

    @Test("This process can find itself and read its own figures")
    func findsItself() throws {
        let me = getpid()
        let mine = try #require(ProcessTable.current().first { $0.pid == me })
        #expect(mine.rssBytes > 1_000_000, "a running test bundle holds more than a megabyte")
        #expect(mine.ppid > 0)
    }

    @Test("This process can read its own environment back")
    func readsOwnEnvironment() {
        // If this fails, KERN_PROCARGS2 is not returning what the parser expects and every
        // tier-1 attribution on the machine is silently empty.
        let me = getpid()
        let (environments, commands) = ProcessEnvironmentReader.read(pids: [me])
        #expect(commands[me]?.isEmpty == false, "own argv came back empty")
        #expect(environments[me]?.pwd != nil, "own PWD came back empty")
    }

    @Test("The machine probe reports a real machine")
    func machineProbe() {
        let m = MachineProbe.current()
        #expect(m.cpuCount > 0)
        #expect(m.memTotalBytes > 1_000_000_000)
        #expect(m.loadAverage1 >= 0)
        #expect(!m.homeDirectory.isEmpty)
    }

    @Test("A full snapshot attributes every process without exceeding the machine")
    func fullSnapshotIsInternallyConsistent() {
        let snapshot = Sampler.snapshot(separatedBy: 0.3)

        #expect(!snapshot.groups.isEmpty)
        // The check the whole design has to survive: if attributed memory exceeds what is
        // installed, something is being counted twice.
        #expect(snapshot.attributedRSSBytes <= snapshot.machine.memTotalBytes,
                "attributed RSS exceeded installed memory")

        let pids = snapshot.groups.flatMap(\.pids)
        #expect(Set(pids).count == pids.count, "a process landed in two groups")
        #expect(snapshot.groups.allSatisfy { !$0.label.isEmpty })
    }

    @Test("The snapshot says how many processes it could not inspect")
    func reportsWhatItCouldNotSee() {
        // Roughly a third of a Mac's process table belongs to root and other users. The
        // output has to say so: a breakdown that silently omits a third of the machine is
        // the kind of confidently incomplete number this tool exists to replace.
        let snapshot = Sampler.snapshot(separatedBy: 0.3)
        #expect(snapshot.machine.processCount > snapshot.attributedProcessCount)
        #expect(snapshot.unreadableProcessCount > 0)
    }

    @Test("Interval CPU stays within what the cores can deliver")
    func cpuWithinPhysicalLimits() {
        let snapshot = Sampler.snapshot(separatedBy: 0.5)
        let total = snapshot.groups.compactMap(\.cpuPercent).reduce(0, +)
        #expect(total >= 0)
        // Some headroom for processes that started mid-interval, but a lifetime-average
        // bug would put this into the thousands of percent.
        #expect(total <= Double(snapshot.machine.cpuCount) * 100 * 2,
                "interval CPU exceeded twice the machine's capacity, which suggests a lifetime average crept in")
    }

    @Test("A reap plan for every group on this machine stays inside that group")
    func liveReapPlansAreContained() {
        // Run against whatever is actually happening right now. Nothing is signalled: the
        // plan is inert, and producing one touches nothing.
        let sample = Sampler.collect()
        let attribution = AttributionEngine.resolveProcesses(
            processes: sample.processes, environments: sample.environments,
            sessions: sample.sessions)

        for key in Set(attribution.values.map(\.key)) {
            let plan = AttributionEngine.reapPlan(
                for: key, processes: sample.processes, environments: sample.environments,
                containers: sample.containers, sessions: sample.sessions)
            for selected in plan.processes {
                #expect(attribution[selected.pid]?.key == key,
                        "a reap plan for \(key) selected pid \(selected.pid) from another group")
            }
        }
    }
}
