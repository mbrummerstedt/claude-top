import Testing
import Foundation
@testable import ClaudeTopKit

/// Stopping things with nobody watching.
///
/// Every other reap path in this project has a person reading a list first. This one does
/// not, so the question it has to answer is not "is this abandoned" but "has this been
/// abandoned long enough that nothing could still want it".
///
/// Process age cannot answer that. A session that exited a minute ago can own a process
/// three days old, and reaping on process age would take it instantly. What counts is how
/// long the worktree has been *continuously observed* with no session, which has to be
/// remembered across runs because a single sample cannot see it.
@Suite("Automatic reaping")
struct AutoReapTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    private func store() throws -> (ResourceStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-autoreap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try ResourceStore(path: directory.appendingPathComponent("r.db").path),
                directory)
    }

    private func orphan(_ worktree: String) -> AttributionKey {
        .orphan(repo: "r", worktree: worktree)
    }

    // MARK: - remembering when something became abandoned

    @Test("The first sighting is remembered")
    func firstSighting() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.recordOrphans([orphan("a")], at: ago(5))
        #expect(store.orphanedSince()[orphan("a").storageKey] == ago(5))
    }

    @Test("Seeing it again does not restart the clock")
    func laterSightingsKeepTheFirst() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Sampled every fifteen seconds in practice, so sightings are close together.
        // An hour between them would be a gap, not a sequence, and is covered below.
        var at = ago(5)
        for _ in 0..<20 {
            try store.recordOrphans([orphan("a")], at: at)
            at = at.addingTimeInterval(60)
        }
        #expect(store.orphanedSince()[orphan("a").storageKey] == ago(5))
    }

    @Test("A worktree that came back to life is forgotten")
    func revivedWorktreeIsForgotten() throws {
        // Someone opened a session in it again. The clock must not carry on from before.
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.recordOrphans([orphan("a"), orphan("b")], at: ago(9))
        try store.recordOrphans([orphan("b")], at: ago(1))
        #expect(store.orphanedSince()[orphan("a").storageKey] == nil)
    }

    @Test("A gap in observation restarts the clock")
    func observationGapRestartsTheClock() throws {
        // The laptop was asleep, or the sampler was not installed. Nine hours passed with
        // nobody watching, so nine hours of abandonment cannot be claimed: a session could
        // have come and gone in that time unseen.
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.recordOrphans([orphan("a")], at: ago(9))
        try store.recordOrphans([orphan("a")], at: now)
        #expect(store.orphanedSince()[orphan("a").storageKey] == now)
    }

    @Test("A short gap between samples is not a break in observation")
    func normalSamplingGapIsFine() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.recordOrphans([orphan("a")], at: ago(5))
        try store.recordOrphans([orphan("a")], at: ago(5).addingTimeInterval(60))
        #expect(store.orphanedSince()[orphan("a").storageKey] == ago(5))
    }

    // MARK: - what may be stopped without anyone looking

    private func group(_ key: AttributionKey, processes: Int = 4) -> AttributionGroup {
        AttributionGroup(key: key, label: "r::\(key.storageKey.suffix(3))", tier: .envStamp,
                         cpuPercent: 0, rssBytes: 1024,
                         pids: (0..<processes).map { Int32(100 + $0) }, containerIDs: [])
    }

    @Test("Nothing is eligible before the quarantine has elapsed")
    func quarantineHolds() {
        let eligible = AutoReap.eligible(
            orphans: [group(orphan("a"))],
            orphanedSince: [orphan("a").storageKey: ago(2)],
            quarantine: 8 * 3600, now: now)
        #expect(eligible.isEmpty)
    }

    @Test("Something abandoned for longer than the quarantine is eligible")
    func quarantineElapsed() {
        let eligible = AutoReap.eligible(
            orphans: [group(orphan("a"))],
            orphanedSince: [orphan("a").storageKey: ago(9)],
            quarantine: 8 * 3600, now: now)
        #expect(eligible.map(\.key) == [orphan("a")])
    }

    @Test("Something never recorded is never eligible")
    func unrecordedIsNotEligible() {
        // Seen for the first time on this very run. There is no history to justify it.
        let eligible = AutoReap.eligible(
            orphans: [group(orphan("a"))], orphanedSince: [:],
            quarantine: 8 * 3600, now: now)
        #expect(eligible.isEmpty)
    }

    @Test("A record from the future is not trusted")
    func futureRecord() {
        let eligible = AutoReap.eligible(
            orphans: [group(orphan("a"))],
            orphanedSince: [orphan("a").storageKey: now.addingTimeInterval(3600)],
            quarantine: 8 * 3600, now: now)
        #expect(eligible.isEmpty)
    }

    @Test("A live session is never eligible, whatever the records say")
    func sessionsAreNeverEligible() {
        // Belt and braces: `orphans` should only ever hold orphans, and this makes a
        // mistake upstream survivable rather than fatal.
        let eligible = AutoReap.eligible(
            orphans: [group(.session(uuid: "live"))],
            orphanedSince: [AttributionKey.session(uuid: "live").storageKey: ago(99)],
            quarantine: 8 * 3600, now: now)
        #expect(eligible.isEmpty)
    }

    @Test("A quarantine of zero is refused rather than obeyed")
    func zeroQuarantineIsRefused() {
        // The whole safety of this rests on the waiting period. A configuration that
        // removes it is far more likely to be a mistake than an intention.
        let eligible = AutoReap.eligible(
            orphans: [group(orphan("a"))],
            orphanedSince: [orphan("a").storageKey: ago(99)],
            quarantine: 0, now: now)
        #expect(eligible.isEmpty)
    }

    @Test("Only the oldest few are taken in one run")
    func boundedPerRun() {
        // An unattended thing that can stop forty groups in one pass is one bad rule away
        // from stopping forty groups it should not have. A ceiling keeps the blast radius
        // of any future mistake small enough to notice and recover from.
        let many = (0..<20).map { group(orphan("w\($0)")) }
        let since = Dictionary(uniqueKeysWithValues: many.enumerated().map {
            ($0.element.key.storageKey, ago(Double(20 - $0.offset) + 9))
        })
        let eligible = AutoReap.eligible(orphans: many, orphanedSince: since,
                                         quarantine: 8 * 3600, now: now, limit: 3)
        #expect(eligible.count == 3)
        // The longest abandoned first, so repeated runs work through the backlog.
        #expect(eligible.first?.key == orphan("w0"))
    }
}
