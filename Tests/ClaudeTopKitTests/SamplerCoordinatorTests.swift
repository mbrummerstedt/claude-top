import Testing
import Foundation
@testable import ClaudeTopKit

/// Who is allowed to write a tick.
///
/// When the app is running it samples in-process and the LaunchAgent stands down. Two
/// samplers writing at once would double the cost of the thing that exists to reduce cost,
/// and would interleave two different CPU baselines into one table, which produces
/// nonsense percentages rather than merely duplicate rows.
@Suite("Sampler coordination")
struct SamplerCoordinatorTests {

    private let me: Int32 = 1000
    private let now = Date(timeIntervalSince1970: 1_757_500_000)

    private func owner(_ pid: Int32, secondsAgo: TimeInterval) -> SamplerOwner {
        SamplerOwner(pid: pid, heartbeat: now.addingTimeInterval(-secondsAgo))
    }

    @Test("With nobody claiming it, sample")
    func noOwner() {
        #expect(!SamplerCoordinator.shouldYield(to: nil, selfPID: me, now: now,
                                                isAlive: { _ in true }))
    }

    @Test("A claim of our own does not stop us")
    func ownClaim() {
        // Otherwise the app would stand down in favour of itself and never sample again.
        #expect(!SamplerCoordinator.shouldYield(to: owner(me, secondsAgo: 1), selfPID: me,
                                                now: now, isAlive: { _ in true }))
    }

    @Test("A live owner with a fresh heartbeat takes precedence")
    func liveOwner() {
        #expect(SamplerCoordinator.shouldYield(to: owner(2000, secondsAgo: 5), selfPID: me,
                                               now: now, isAlive: { _ in true }))
    }

    @Test("A claim left behind by a process that is gone is ignored")
    func deadOwner() {
        // The app crashing must not leave the sampler permanently stood down.
        #expect(!SamplerCoordinator.shouldYield(to: owner(2000, secondsAgo: 5), selfPID: me,
                                                now: now, isAlive: { _ in false }))
    }

    @Test("A live owner that stopped updating its claim is ignored")
    func stalledOwner() {
        // Still running, no longer sampling. Waiting on it would mean no history at all,
        // and the recycled-pid case looks exactly like this from here.
        #expect(!SamplerCoordinator.shouldYield(to: owner(2000, secondsAgo: 600), selfPID: me,
                                                now: now, isAlive: { _ in true }))
    }

    @Test("A claim from the future is not trusted")
    func futureHeartbeat() {
        // A clock change, or a file written by something else entirely.
        #expect(!SamplerCoordinator.shouldYield(to: owner(2000, secondsAgo: -600), selfPID: me,
                                                now: now, isAlive: { _ in true }))
    }

    @Test("A claim round-trips through the file it is kept in")
    func claimRoundTrip() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }

        try SamplerCoordinator.claim(pid: 4242, at: now, path: path)
        let read = try #require(SamplerCoordinator.owner(at: path))
        #expect(read.pid == 4242)
        #expect(abs(read.heartbeat.timeIntervalSince(now)) < 1)
    }

    @Test("A missing or unreadable claim reads as nobody claiming it")
    func unreadableClaim() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/owner.json")
        #expect(SamplerCoordinator.owner(at: missing) == nil)

        let garbage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: garbage) }
        try "not json".write(to: garbage, atomically: true, encoding: .utf8)
        #expect(SamplerCoordinator.owner(at: garbage) == nil)
    }

    @Test("Releasing a claim leaves nothing behind")
    func release() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-owner-\(UUID().uuidString).json")
        try SamplerCoordinator.claim(pid: 4242, at: now, path: path)
        SamplerCoordinator.release(at: path)
        #expect(SamplerCoordinator.owner(at: path) == nil)
    }
}
