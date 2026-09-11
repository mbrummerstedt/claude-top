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
        let (environments, commands, arguments) = ProcessEnvironmentReader.read(pids: [me])
        #expect(commands[me]?.isEmpty == false, "own argv came back empty")
        #expect(environments[me]?.pwd != nil, "own PWD came back empty")
        #expect(arguments[me]?.isEmpty == false, "own argv array came back empty")
    }

    @Test("Cumulative CPU time matches what the kernel says this process has used")
    func cpuTimeMatchesGetrusage() throws {
        // The unit this whole tool ranks on. `pti_total_user` and `pti_total_system` are
        // mach absolute time units, and on Apple Silicon a tick is 125/3 nanoseconds, so
        // reading them as nanoseconds understates every process by nearly 42x. On Intel
        // the timebase is 1:1 and the mistake is invisible, which is how it survives.
        //
        // Checked against getrusage, which reports this process's own consumption in
        // plain timevals. Nothing here depends on the scheduler: an earlier version spun
        // a thread for a wall second and asserted it earned roughly a second of CPU,
        // which is untrue on a machine at load 43 where it earns a fifth of one.
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        let fromKernel = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6

        let me = getpid()
        let fromLibproc = try #require(ProcessTable.current().first { $0.pid == me }?.cpuTime)

        try #require(fromKernel > 0.05, "this process has used too little CPU to compare")
        // Sampled a moment apart, so they differ by whatever ran in between, never by a
        // factor. The tick error would put libproc at 2.4% of the kernel's figure.
        #expect(abs(fromLibproc - fromKernel) / fromKernel < 0.25,
                "libproc says \(fromLibproc)s, getrusage says \(fromKernel)s")
    }

    @Test("Cumulative CPU time agrees with what ps reports for the same process")
    func cpuTimeAgreesWithPS() throws {
        // A second opinion from a tool that has been right about this since 1979.
        let heaviest = try #require(ProcessTable.current().max { $0.cpuTime < $1.cpuTime })
        let reported = try #require(Shell.run("/bin/ps", ["-o", "time=", "-p", "\(heaviest.pid)"],
                                              timeout: 5))
        let fromPS = Fixture.parseCPUTime(reported.trimmingCharacters(in: .whitespacesAndNewlines))
        try #require(fromPS > 1, "no process on this machine has enough CPU time to compare")

        let difference = abs(heaviest.cpuTime - fromPS) / fromPS
        #expect(difference < 0.05,
                "libproc says \(heaviest.cpuTime)s, ps says \(fromPS)s")
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
                containers: sample.containers, roster: sample.roster)
            for selected in plan.processes {
                #expect(attribution[selected.pid]?.key == key,
                        "a reap plan for \(key) selected pid \(selected.pid) from another group")
            }
        }
    }

    /// The live half of `ReapSafetyTests.neverReapsItself`. The unit test proves the rule
    /// against a constructed process table; this proves it against whatever this machine
    /// is running, including a menu bar app or a `--watch` that inherited a live session's
    /// stamp by having been launched from inside one.
    @Test("No reap plan on this machine ever selects claude-top itself")
    func liveReapPlansNeverSelectTheTool() {
        let sample = Sampler.collect()
        let attribution = AttributionEngine.resolveProcesses(
            processes: sample.processes, environments: sample.environments,
            sessions: sample.sessions)

        for key in Set(attribution.values.map(\.key)) {
            let plan = AttributionEngine.reapPlan(
                for: key, processes: sample.processes, environments: sample.environments,
                containers: sample.containers, roster: sample.roster)
            for selected in plan.processes {
                #expect(!AttributionEngine.isOwnMachinery(selected.command),
                        "a reap plan for \(key) selected this tool: \(selected.command)")
            }
        }
    }
}
