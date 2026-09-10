import Testing
import Foundation
@testable import ClaudeTopKit

/// What happens when the roster cannot be read.
///
/// This is the failure that matters most, because of when it happens. `claude agents
/// --json` took 5.9 seconds on this machine at load 22, past a three second timeout, and
/// a failed read was being treated as "no sessions are running". Every live session then
/// resolved as an orphan, which is the bucket `--reap` acts on. The tool degraded into
/// offering to kill live work at exactly the load it exists to be used at.
///
/// An unreadable roster is not an empty roster. Nothing may conclude a session is gone
/// from a question that was never answered.
@Suite("Roster resilience")
struct RosterResilienceTests {

    private func session(_ pid: Int32, uuid: String) -> SessionInfo {
        SessionInfo(pid: pid, cwd: "/Users/USER/git_repositories/r/.claude/worktrees/w-123456",
                    sessionID: uuid, startedAt: Date())
    }

    private func temporaryCache() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-roster-\(UUID().uuidString).json")
    }

    // MARK: - provenance

    @Test("A roster read just now may be acted on")
    func liveRosterIsActionable() {
        let roster = Roster(sessions: [session(100, uuid: "a")], source: .live)
        #expect(roster.isUsableForDisplay)
        #expect(roster.allowsReaping)
    }

    @Test("A cached roster is good enough to look at and not good enough to kill by")
    func cachedRosterIsDisplayOnly() {
        // A session started since the cache was written is absent from it, so its
        // processes would read as orphaned. Fine in a list, not fine as a kill list.
        let roster = Roster(sessions: [session(100, uuid: "a")], source: .cached(age: 120))
        #expect(roster.isUsableForDisplay)
        #expect(!roster.allowsReaping)
    }

    @Test("An unavailable roster is neither")
    func unavailableRosterIsNeither() {
        let roster = Roster(sessions: [], source: .unavailable)
        #expect(!roster.isUsableForDisplay)
        #expect(!roster.allowsReaping)
    }

    @Test("An empty answer from a working roster is still a live roster")
    func genuinelyEmptyIsStillLive() {
        // No sessions running is a real answer and must stay distinguishable from not
        // having been able to ask.
        let roster = Roster(sessions: [], source: .live)
        #expect(roster.isUsableForDisplay)
        #expect(roster.allowsReaping)
    }

    // MARK: - the cache

    @Test("A successful read is remembered for the next one that fails")
    func successIsCached() throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }

        SessionRoster.remember([session(100, uuid: "a"), session(200, uuid: "b")], at: cache)
        let recovered = try #require(SessionRoster.remembered(at: cache, now: Date(),
                                                             maximumAge: 600))
        #expect(recovered.sessions.map(\.sessionID) == ["a", "b"])
        if case .cached = recovered.source {} else {
            Issue.record("a recovered roster must say it came from cache")
        }
    }

    @Test("A cache older than the window is not used")
    func staleCacheIsNotUsed() throws {
        // Sessions come and go. A roster from an hour ago describes a machine that no
        // longer exists, and presenting it as current would be its own wrong answer.
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }

        SessionRoster.remember([session(100, uuid: "a")], at: cache)
        let later = Date().addingTimeInterval(3600)
        #expect(SessionRoster.remembered(at: cache, now: later, maximumAge: 600) == nil)
    }

    @Test("A missing or unreadable cache is simply no cache")
    func unreadableCache() throws {
        #expect(SessionRoster.remembered(at: URL(fileURLWithPath: "/nonexistent/x.json"),
                                         now: Date(), maximumAge: 600) == nil)

        let garbage = temporaryCache()
        defer { try? FileManager.default.removeItem(at: garbage) }
        try "not json".write(to: garbage, atomically: true, encoding: .utf8)
        #expect(SessionRoster.remembered(at: garbage, now: Date(), maximumAge: 600) == nil)
    }

    @Test("The cache never holds a session prompt")
    func cacheNeverHoldsAPrompt() throws {
        // It is a file on disk that outlives the terminal the prompt was printed to.
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }

        let secret = "migrate the billing schema before the audit"
        SessionRoster.remember([SessionInfo(pid: 100, cwd: "/Users/USER", sessionID: "a",
                                            startedAt: Date(), promptPreview: secret)],
                               at: cache)
        let onDisk = try String(contentsOf: cache, encoding: .utf8)
        #expect(!onDisk.contains(secret))
        #expect(SessionRoster.remembered(at: cache, now: Date(), maximumAge: 600)?
                    .sessions.first?.promptPreview == nil)
    }

    @Test("A read that times out falls back to the last good roster, labelled as such")
    func timeoutFallsBackToCache() throws {
        // The bug, end to end. `claude agents --json` took 5.9s at load 22 against a 3s
        // timeout, the read failed, and an empty roster resolved all 21 live sessions to
        // orphans. Now the last good answer is reused and marked as not fresh, so the
        // list stays right and the kill list stays refused.
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        SessionRoster.remember([session(100, uuid: "still-here")], at: cache)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-slow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let slow = directory.appendingPathComponent("claude-slow")
        try "#!/bin/sh\nsleep 30".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: slow.path)

        let roster = SessionRoster.live(timeout: 0.5, candidates: [slow.path], cache: cache)
        #expect(roster.sessions.map(\.sessionID) == ["still-here"],
                "a timeout lost the roster instead of falling back")
        #expect(roster.allowsReaping == false, "a cached roster must not authorise a reap")
        #expect(roster.isUsableForDisplay)
    }

    @Test("A read that fails with no cache reports unavailable, not empty")
    func failureWithoutCacheIsUnavailable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let broken = directory.appendingPathComponent("claude-broken")
        try "#!/bin/sh\nexit 1".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: broken.path)

        let roster = SessionRoster.live(timeout: 5, candidates: [broken.path],
                                        cache: temporaryCache())
        #expect(roster.source == .unavailable)
        #expect(!roster.allowsReaping)
    }

    // MARK: - what a reap is allowed to do about it

    private func plan(roster: Roster) -> ReapPlan {
        let worktree = "/Users/USER/git_repositories/r/.claude/worktrees/w-123456"
        return AttributionEngine.reapPlan(
            for: .orphan(repo: "r", worktree: "w-123456"),
            processes: [ProcessSample(pid: 500, ppid: 1, rssBytes: 0, cpuTime: 0,
                                      startedAt: Date(), command: "/usr/bin/node")],
            environments: [500: ProcessEnvironment(pid: 500,
                                                   messagingSocket: "/tmp/cc-socks/999.sock",
                                                   hostSessionID: nil, entrypoint: nil,
                                                   pwd: worktree)],
            containers: [], roster: roster)
    }

    @Test("A reap on a live roster proceeds")
    func reapOnLiveRoster() {
        #expect(plan(roster: Roster(sessions: [], source: .live)).processes.map(\.pid) == [500])
    }

    @Test("A reap refuses on a cached roster and says why")
    func reapRefusesOnCachedRoster() {
        // The session that owns pid 500 might have started after the cache was written.
        let plan = plan(roster: Roster(sessions: [], source: .cached(age: 120)))
        #expect(plan.isEmpty)
        #expect(plan.refusal == .rosterNotLive)
    }

    @Test("A reap refuses outright when the roster could not be read")
    func reapRefusesOnUnavailableRoster() {
        // The exact case that made this dangerous: every live session looks orphaned.
        let plan = plan(roster: Roster(sessions: [], source: .unavailable))
        #expect(plan.isEmpty)
        #expect(plan.refusal == .rosterNotLive)
    }

    @Test("A keep file still refuses, and says that instead")
    func keepFileRefusalIsDistinct() {
        let worktree = "/Users/USER/git_repositories/r/.claude/worktrees/w-123456"
        let plan = AttributionEngine.reapPlan(
            for: .orphan(repo: "r", worktree: "w-123456"),
            processes: [], environments: [:], containers: [],
            roster: Roster(sessions: [], source: .live),
            keepMarkedWorktrees: [worktree])
        #expect(plan.refusal == .keepFile)
    }
}
