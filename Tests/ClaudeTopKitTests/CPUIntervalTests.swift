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

    @Test("A process born during the interval is measured from its own start")
    func bornDuringInterval() {
        // Charging 0.5s of CPU against a 1s interval would read 50%, but the process only
        // existed for the second half of it and was pinning a core throughout.
        let bornMidway = t0.addingTimeInterval(0.5)
        let pct = AttributionEngine.cpuPercents(
            earlier: [], earlierAt: t0,
            later: [sample(pid: 99, cpuTime: 0.5, startedAt: bornMidway)], laterAt: t1)
        expect(pct[99], 100)
    }

    @Test("A recycled PID is measured as new, never diffed against its predecessor")
    func recycledPID() {
        // Same PID, different process. Diffing cumulative times here would produce a
        // negative delta, and on a busy machine PIDs recycle within minutes.
        let bornMidway = t0.addingTimeInterval(0.5)
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 42, cpuTime: 3600, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 42, cpuTime: 0.25, startedAt: bornMidway)], laterAt: t1)
        expect(pct[42], 50)
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

    @Test("Every process in the later sample gets a reading")
    func everyLaterProcessCovered() {
        let pct = AttributionEngine.cpuPercents(
            earlier: [sample(pid: 1, cpuTime: 5, startedAt: born)], earlierAt: t0,
            later: [sample(pid: 1, cpuTime: 5.1, startedAt: born),
                    sample(pid: 2, cpuTime: 0.2, startedAt: born),
                    sample(pid: 3, cpuTime: 0, startedAt: t0.addingTimeInterval(0.9))],
            laterAt: t1)
        #expect(Set(pct.keys) == [1, 2, 3])
    }
}
