import Testing
import Foundation
@testable import ClaudeTopKit

/// Reconciling with Activity Monitor.
///
/// macOS grants task info only for your own processes, so roughly a third of a Mac is
/// invisible here, and on a busy machine that third includes `kernel_task` and
/// `WindowServer` near the top of the list. Attributed CPU therefore never sums to what
/// the machine is doing, and a tool that shows the smaller number without saying so reads
/// as wrong even when every figure in it is right.
///
/// These read the same counters Activity Monitor and `top` read, so the gap can be stated
/// rather than left for someone to notice.
@Suite("System CPU")
struct SystemCPUTests {

    private func ticks(user: UInt64, system: UInt64, idle: UInt64,
                       nice: UInt64 = 0) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test("Tick deltas become the percentages Activity Monitor shows")
    func matchesActivityMonitorsUnits() {
        // A machine that spent 20% of its ticks in user code and 10% in the kernel.
        let measured = AttributionEngine.systemCPU(
            earlier: ticks(user: 0, system: 0, idle: 0),
            later: ticks(user: 200, system: 100, idle: 700))
        let cpu = try! #require(measured)
        #expect(abs(cpu.userPercent - 20) < 0.01)
        #expect(abs(cpu.systemPercent - 10) < 0.01)
        #expect(abs(cpu.busyPercent - 30) < 0.01)
    }

    @Test("The same figure is available in the units the rows use")
    func perCoreUnits() {
        // Group rows are per-core sums: a process on two cores reads 200%. The machine
        // total has to be offered the same way or the two cannot be compared at all.
        let cpu = try! #require(AttributionEngine.systemCPU(
            earlier: ticks(user: 0, system: 0, idle: 0),
            later: ticks(user: 200, system: 100, idle: 700)))
        #expect(abs(cpu.busyPerCore(cpuCount: 10) - 300) < 0.01)
    }

    @Test("Nice time counts as busy, because the machine was not idle")
    func niceIsBusy() {
        let cpu = try! #require(AttributionEngine.systemCPU(
            earlier: ticks(user: 0, system: 0, idle: 0, nice: 0),
            later: ticks(user: 100, system: 0, idle: 800, nice: 100)))
        #expect(abs(cpu.busyPercent - 20) < 0.01)
    }

    @Test("Two identical readings measure nothing rather than zero")
    func noElapsedTicks() {
        // Zero would claim an idle machine. Nothing elapsed, so nothing is known.
        let same = ticks(user: 10, system: 10, idle: 10)
        #expect(AttributionEngine.systemCPU(earlier: same, later: same) == nil)
    }

    @Test("Counters going backwards measure nothing")
    func countersWentBackwards() {
        #expect(AttributionEngine.systemCPU(
            earlier: ticks(user: 500, system: 500, idle: 500),
            later: ticks(user: 1, system: 1, idle: 1)) == nil)
    }

    // MARK: - the gap

    private func snapshot(busyPerCore: Double, attributed: Double,
                          unreadable: Int) -> Snapshot {
        let machine = MachineInfo(cpuCount: 10, memTotalBytes: 17_179_869_184,
                                  memUsedBytes: 10_737_418_240, loadAverage1: 10,
                                  capturedAt: Date(), homeDirectory: "/Users/USER",
                                  processCount: 400 + unreadable)
        let group = AttributionGroup(
            key: .system(family: .other), label: "Other processes", tier: .unresolved,
            cpuPercent: attributed, rssBytes: 0,
            pids: (0..<400).map { Int32(100 + $0) }, containerIDs: [])
        return Snapshot(machine: machine, groups: [group],
                        systemCPU: SystemCPU(userPercent: busyPerCore / 10 * 0.7,
                                             systemPercent: busyPerCore / 10 * 0.3))
    }

    @Test("The unexplained share is the difference, never a negative number")
    func unexplainedShare() {
        let s = snapshot(busyPerCore: 314, attributed: 172, unreadable: 212)
        #expect(abs(s.attributedCPUPercent - 172) < 0.01)
        #expect(abs((s.unaccountedCPUPercent ?? 0) - 142) < 1)
    }

    @Test("Attributing more than the machine reports leaves nothing unexplained")
    func neverNegative() {
        // The two are sampled over slightly different windows, so attribution can edge
        // past the total. A negative gap would be nonsense on screen.
        let s = snapshot(busyPerCore: 100, attributed: 140, unreadable: 0)
        #expect(s.unaccountedCPUPercent == 0)
    }

    @Test("With no reading of the machine there is no gap to state")
    func noSystemReading() {
        let machine = MachineInfo(cpuCount: 10, memTotalBytes: 1, loadAverage1: 1,
                                  capturedAt: Date())
        #expect(Snapshot(machine: machine, groups: []).unaccountedCPUPercent == nil)
    }

    @Test("The live machine's own counters read and advance")
    func liveCountersAdvance() throws {
        // The kernel updates these roughly five times a second, and less often on an idle
        // machine: forty reads twenty milliseconds apart saw four changes. A short window
        // can legitimately span no ticks at all, which is why `systemCPU` answers nil for
        // that rather than claiming an idle machine. A second is comfortably enough.
        let first = try #require(MachineProbe.cpuTicks())
        Thread.sleep(forTimeInterval: 1.0)
        let second = try #require(MachineProbe.cpuTicks())

        let cpu = try #require(AttributionEngine.systemCPU(earlier: first, later: second),
                               "counters did not advance in a full second")
        #expect(cpu.busyPercent >= 0)
        #expect(cpu.busyPercent <= 100.5, "busy cannot exceed the whole machine")
        #expect(cpu.userPercent >= 0)
    }

    @Test("A window too short to span a tick reports unknown rather than idle")
    func windowTooShortIsUnknown() throws {
        // The one-shot CLI samples 700ms apart. On a quiet machine that can fall between
        // updates, and "CPU —" is the honest answer; "CPU 0%" would not be.
        let ticks = try #require(MachineProbe.cpuTicks())
        #expect(AttributionEngine.systemCPU(earlier: ticks, later: ticks) == nil)
    }
}
