import Testing
import Foundation
@testable import ClaudeTopKit

/// Interval CPU, not lifetime average.
///
/// `ps` reports `%cpu` averaged over a process's whole life, which is why a session that
/// finished a test run an hour ago still reads high while the one currently melting a
/// core reads low. Ranking is the entire job of this tool, so the engine diffs cumulative
/// CPU time between two samples instead.
@Suite("CPU interval calculation")
struct CPUIntervalTests {

    private func sample(pid: Int32, cpuTime: TimeInterval, startedAt: Date) -> ProcessSample {
        ProcessSample(pid: pid, ppid: 1, rssBytes: 0, cpuTime: cpuTime,
                      startedAt: startedAt, command: "worker")
    }

    /// Percentages are derived through `Date` arithmetic at epoch magnitudes, so they
    /// carry a few parts per billion of representation error. The tolerance is far
    /// tighter than any miscalculation would be: a real bug here is off by whole cores.
    private func expect(_ actual: Double?, _ want: Double,
                        _ comment: Comment? = nil,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual != nil, comment, sourceLocation: sourceLocation)
        guard let actual else { return }
        #expect(abs(actual - want) < 1e-4, comment, sourceLocation: sourceLocation)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var t1: Date { t0.addingTimeInterval(1) }
    private var born: Date { t0.addingTimeInterval(-3600) }

    @Test("A process burning one core for the whole interval reads 100%")
    func oneCore() {
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 10, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 11, startedAt: born)], laterAt: t1)
        expect(pct[42], 100)
    }

    @Test("Percentages exceed 100 across multiple cores")
    func multipleCores() {
        // The case the tool exists for: nine vitest workers on a ten-core machine.
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 0, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 2.87, startedAt: born)], laterAt: t1)
        expect(pct[42], 287)
    }

    @Test("An idle process reads zero however long it has been alive")
    func idleDespiteLongLife() {
        // 3600s of cumulative CPU and none of it in this interval. `ps` would rank this
        // process near the top; it belongs at the bottom.
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 3600, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 3600, startedAt: born)], laterAt: t1)
        expect(pct[42], 0)
    }

    @Test("A sub-second interval scales correctly")
    func subSecondInterval() {
        // The one-shot CLI samples roughly 700 ms apart.
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 0, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 0.35, startedAt: born)], laterAt: t0.addingTimeInterval(0.7))
        expect(pct[42], 50)
    }

    @Test("A process that died between samples is absent from the result")
    func diedBetweenSamples() {
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 10, startedAt: born)], earlierAt: t0,
            later: [], laterAt: t1)
        #expect(pct[42] == nil)
    }

    @Test("A process born during the interval is charged against the interval")
    func bornDuringInterval() {
        // It pinned a core for the half-second it existed, so measured against its own
        // life it reads 100%. The spec asks for interval CPU%, divided by elapsed wall
        // time, because these rows get summed and compared against the machine's busy
        // cores in the headline. Against that window it took half a core, and 50% is
        // what lets the two reconcile.
        let bornMidway = t0.addingTimeInterval(0.5)
        let pct = AttributionEngine.cpuPercents(
            earlier: [], earlierAt: t0,
            later: [sample(pid: 99, cpuTime: 0.5, startedAt: bornMidway)], laterAt: t1)
        expect(pct[99], 50)
    }

    @Test("A recycled PID is measured as new, never diffed against its predecessor")
    func recycledPID() {
        // Same PID, different process. Diffing cumulative times here would produce a
        // negative delta, and on a busy machine PIDs recycle within minutes. The hour of
        // CPU the previous holder of the PID accumulated must not reach the result at
        // all: 0.25s against the 1s window is 25%.
        let bornMidway = t0.addingTimeInterval(0.5)
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 3600, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 0.25, startedAt: bornMidway)], laterAt: t1)
        expect(pct[42], 25)
    }

    @Test("Cumulative time going backwards never produces a negative percentage")
    func neverNegative() {
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 10, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 9, startedAt: born)], laterAt: t1)
        expect(pct[42], 0)
    }

    @Test("A clock that did not advance yields no readings rather than wrong ones")
    func nonAdvancingClock() {
        // The sampler diffs against the previous row in SQLite, so a clock change can put
        // the two samples out of order. A missing entry means unknown, the same contract
        // as a nil container cpuPercent. Inventing a number here would be worse.
        let backwards = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 10, startedAt: born)], earlierAt: t1,
            later: [sample(pid: 42, cpuTime: 11, startedAt: born)], laterAt: t0)
        #expect(backwards.isEmpty)

        let identical = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 10, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 11, startedAt: born)], laterAt: t0)
        #expect(identical.isEmpty)
    }

    @Test("Every process in the later sample gets a reading, unless its share is unknowable")
    func everyLaterProcessCovered() {
        // pid 2 is absent from the baseline and older than the window, so how much of
        // its lifetime CPU falls inside the window cannot be known. See `staleProcess`.
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 1, cpuTime: 5, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 1, cpuTime: 5.1, startedAt: born),
                    sample(pid: 2, cpuTime: 0.2, startedAt: born),
                    sample(pid: 3, cpuTime: 0, startedAt: t0.addingTimeInterval(0.9))],
            laterAt: t1)
        #expect(Set(pct.keys) == [1, 3])
    }

    // MARK: - the denominator

    /// The figure every row is summed into and compared against the machine's busy cores
    /// is a share of the sampling window. A process's share of its own short life is a
    /// different number, and mixing the two inflates whatever spawned most recently.
    @Test("A process born inside the window is a share of the window, not of its own life")
    func bornInsideTheWindow() {
        // Born 100ms before the second reading, burning a core the whole time. It used
        // 0.1s of CPU out of a 1s window, which is 10% of the window. Measured against
        // its own 100ms life it would read 100%, and a hook spawning greps would then
        // outrank the process actually melting a core.
        let pct = AttributionEngine.cpuPercents(
            earlier: [], earlierAt: t0,
            later: [sample(pid: 7, cpuTime: 0.1, startedAt: t1.addingTimeInterval(-0.1))],
            laterAt: t1)
        expect(pct[7], 10)
    }

    @Test("Short-lived processes cannot sum past the machine")
    func burstsStayBounded() {
        // Ten hook scripts, each alive 50ms of the 1s window and each burning a core for
        // its whole life. Together they used half a core-second, so they are 50% of one
        // core, not the 1000% that measuring each against its own life would produce.
        let born = t1.addingTimeInterval(-0.05)
        let procs = (1...10).map { sample(pid: Int32($0), cpuTime: 0.05, startedAt: born) }
        let pct = AttributionEngine.cpuPercents(earlier: [], earlierAt: t0,
                                                later: procs, laterAt: t1)
        expect(pct.values.reduce(0, +), 50)
    }

    /// The case that produces a five-figure percentage if the whole lifetime is divided
    /// by the window: an hour-old process that the first listing missed.
    @Test("A process the baseline missed, older than the window, reads unknown not enormous")
    func staleProcess() {
        let pct = AttributionEngine.cpuPercents(
            earlier: [], earlierAt: t0,
            later: [sample(pid: 9, cpuTime: 3000, startedAt: born)], laterAt: t1)
        #expect(pct[9] == nil)
    }
}
