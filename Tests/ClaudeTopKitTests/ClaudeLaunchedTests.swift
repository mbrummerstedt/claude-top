import Testing
import Foundation
@testable import ClaudeTopKit

/// Processes the Claude desktop app started, which carry no stamp.
///
/// A command run from the app's own terminal is launched through
/// `/Applications/Claude.app/Contents/Helpers/disclaimer` and inherits no
/// `CLAUDE_CODE_MESSAGING_SOCKET`, because no agent spawned it. Only the working directory
/// places it, which is the weakest evidence the cascade has and the reason the unattended
/// reaper was never allowed to touch it. In 403 runs on the machine this was written for,
/// `--auto-reap` signalled zero processes and stopped eleven containers: every dev server
/// left behind by a session that exited was out of its reach by construction.
///
/// Descending from the desktop app is stronger than the path alone. It says Claude started
/// this, which is the question the path could not answer, and it is what separates a dev
/// server left in a dead worktree from the editor the person opened on the same directory.
@Suite("Claude-launched processes")
struct ClaudeLaunchedTests {

    private let desktopApp = "/Applications/Claude.app/Contents/MacOS/Claude"
    private let launcher = "/Applications/Claude.app/Contents/Helpers/disclaimer -- /bin/zsh -c ./dev.sh"
    private let worktreeA = "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page-63c477"
    private let orphanA = AttributionKey.orphan(repo: "reader-app", worktree: "terms-page-63c477")

    private func proc(_ pid: Int32, ppid: Int32 = 1, cmd: String = "/usr/bin/node") -> ProcessSample {
        ProcessSample(pid: pid, ppid: ppid, rssBytes: 1024, cpuTime: 1,
                      startedAt: Date(), command: cmd)
    }

    private func env(_ pid: Int32, session: Int32? = nil, pwd: String? = nil) -> ProcessEnvironment {
        ProcessEnvironment(pid: pid,
                           messagingSocket: session.map { "/tmp/cc-socks/\($0).sock" },
                           hostSessionID: nil, entrypoint: nil, pwd: pwd)
    }

    private func session(_ pid: Int32, _ cwd: String, uuid: String) -> SessionInfo {
        SessionInfo(pid: pid, cwd: cwd, sessionID: uuid, startedAt: Date())
    }

    private func resolve(_ processes: [ProcessSample], _ environments: [ProcessEnvironment],
                         _ sessions: [SessionInfo] = []) -> [Int32: ProcessAttribution] {
        AttributionEngine.resolveProcesses(
            processes: processes,
            environments: Dictionary(uniqueKeysWithValues: environments.map { ($0.pid, $0) }),
            sessions: sessions)
    }

    private func plan(for key: AttributionKey, scope: ReapScope,
                      processes: [ProcessSample], environments: [ProcessEnvironment],
                      sessions: [SessionInfo] = [], keep: Set<String> = []) -> ReapPlan {
        AttributionEngine.reapPlan(
            for: key, processes: processes,
            environments: Dictionary(uniqueKeysWithValues: environments.map { ($0.pid, $0) }),
            containers: [], roster: Roster(sessions: sessions, source: .live),
            keepMarkedWorktrees: keep, scope: scope)
    }

    /// The shape found live: the app, its launcher, and the command the person typed.
    private func desktopChain(leaf: Int32) -> [ProcessSample] {
        [proc(900, cmd: desktopApp), proc(901, ppid: 900, cmd: launcher),
         proc(leaf, ppid: 901)]
    }

    // MARK: - the tier

    @Test("A process in a worktree descending from the desktop app is placed as Claude-launched")
    func ancestryIsRecorded() {
        let r = resolve(desktopChain(leaf: 500), [env(500, pwd: worktreeA)])

        #expect(r[500]?.tier == .claudeLaunched)
    }

    @Test("The same process with no Claude ancestor is placed by its path alone")
    func withoutAncestryItIsStillOnlyAPath() {
        let r = resolve([proc(500)], [env(500, pwd: worktreeA)])

        #expect(r[500]?.tier == .worktreePath)
    }

    /// Ancestry is evidence about where a process came from, not about who owns it. It has
    /// to leave the group alone, or a stop aimed at one worktree could land in another.
    @Test("Ancestry changes the tier and never the group")
    func ancestryDoesNotMoveTheGroup() {
        let withApp = resolve(desktopChain(leaf: 500), [env(500, pwd: worktreeA)])
        let without = resolve([proc(500)], [env(500, pwd: worktreeA)])

        #expect(withApp[500]?.key == orphanA)
        #expect(withApp[500]?.key == without[500]?.key)
    }

    @Test("A worktree a live session holds still claims its Claude-launched processes")
    func aLiveSessionStillOwnsItsWorktree() {
        let live = session(100, worktreeA, uuid: "live")
        let r = resolve(desktopChain(leaf: 500), [env(500, pwd: worktreeA)], [live])

        #expect(r[500]?.key == .session(uuid: "live"))
    }

    @Test("A stamp still wins over ancestry")
    func stampOutranksAncestry() {
        let r = resolve(desktopChain(leaf: 500),
                        [env(500, session: 100, pwd: worktreeA)],
                        [session(100, worktreeA, uuid: "live")])

        #expect(r[500]?.tier == .envStamp)
    }

    @Test("Descending from the app without being in a worktree places nothing")
    func ancestryAloneIsNotAttribution() {
        let r = resolve(desktopChain(leaf: 500), [env(500, pwd: "/Users/USER")])

        #expect(r[500]?.tier == .unresolved,
                "the app started it, but nothing says which worktree it belongs to")
    }

    // MARK: - what the unattended reaper may now take

    @Test("Unattended reaping takes a Claude-launched process in a dead worktree")
    func autoReapReachesItNow() {
        let p = plan(for: orphanA, scope: .startedByClaude,
                     processes: desktopChain(leaf: 500),
                     environments: [env(500, pwd: worktreeA)])

        #expect(p.processes.map(\.pid) == [500])
    }

    /// The case the narrow rule was written to protect, and the reason ancestry is the
    /// right line rather than the path: an editor opened on the worktree was started by
    /// the person, from the Dock, and nothing about it says Claude.
    @Test("Unattended reaping still leaves alone what the person started themselves")
    func autoReapSparesWhatClaudeDidNotStart() {
        let editor = [proc(500, cmd: "/Applications/Some Editor.app/Contents/MacOS/Editor")]
        let p = plan(for: orphanA, scope: .startedByClaude,
                     processes: editor, environments: [env(500, pwd: worktreeA)])

        #expect(p.processes.isEmpty)
    }

    @Test("Unattended reaping never crosses into a live session")
    func autoReapStaysInItsGroup() {
        let live = session(100, "/Users/USER/git_repositories/tradebot/.claude/worktrees/x-1",
                           uuid: "live")
        var processes = desktopChain(leaf: 500)
        processes.append(proc(600, ppid: 901))
        let environments = [env(500, pwd: worktreeA),
                            env(600, session: 100, pwd: live.cwd)]

        let p = plan(for: orphanA, scope: .startedByClaude,
                     processes: processes, environments: environments, sessions: [live])

        #expect(p.processes.map(\.pid) == [500])
    }

    @Test("A keep file still exempts a worktree from unattended reaping")
    func keepFileStillExempts() {
        let p = plan(for: orphanA, scope: .startedByClaude,
                     processes: desktopChain(leaf: 500),
                     environments: [env(500, pwd: worktreeA)], keep: [worktreeA])

        #expect(p.isEmpty)
        #expect(p.refusal == ReapRefusal.keepFile)
    }

    @Test("The narrowest scope is unchanged and still takes only stamped processes")
    func stampedScopeIsUnmoved() {
        let p = plan(for: orphanA, scope: .stamped,
                     processes: desktopChain(leaf: 500),
                     environments: [env(500, pwd: worktreeA)])

        #expect(p.processes.isEmpty)
    }

    @Test("A row's Stop still takes a path-only process the unattended reaper will not")
    func attendedIsStillWider() {
        let processes = [proc(500)]
        let environments = [env(500, pwd: worktreeA)]

        let attended = plan(for: orphanA, scope: .attributed,
                            processes: processes, environments: environments)
        let unattended = plan(for: orphanA, scope: .startedByClaude,
                              processes: processes, environments: environments)

        #expect(attended.processes.map(\.pid) == [500])
        #expect(unattended.processes.isEmpty)
    }

    @Test("Selection by ancestry says so, so the reap log can be read back")
    func theReasonNamesTheEvidence() {
        let p = plan(for: orphanA, scope: .startedByClaude,
                     processes: desktopChain(leaf: 500),
                     environments: [env(500, pwd: worktreeA)])

        let reason = p.processes.first?.reason ?? ""
        #expect(reason.contains("Claude"))
        #expect(reason.contains(worktreeA))
    }

    @Test("claude-top is never selected, whatever started it")
    func neverItself() {
        var processes = desktopChain(leaf: 500)
        processes.append(proc(501, ppid: 901,
                              cmd: "/Applications/ClaudeTop.app/Contents/MacOS/ClaudeTop"))
        let environments = [env(500, pwd: worktreeA), env(501, pwd: worktreeA)]

        let p = plan(for: orphanA, scope: .startedByClaude,
                     processes: processes, environments: environments)

        #expect(p.processes.map(\.pid) == [500])
    }

    // MARK: - against the reference capture

    @Test("The capture splits its unstamped worktree processes by provenance")
    func fixtureSplit() throws {
        let raw = try Fixture.processes()
        let processes = raw.map {
            ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                          cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
        }
        let placed = AttributionEngine.resolveProcesses(
            processes: processes, environments: try Fixture.environments(),
            sessions: try Fixture.sessions())

        // All six, and none placed by the path alone. Every unstamped process sitting in
        // a worktree on the reference machine had been started by the desktop app, which
        // is why refusing this tier left the unattended reaper with nothing to do.
        #expect(placed.values.filter { $0.tier == .claudeLaunched }.count == 6)
        #expect(placed.values.filter { $0.tier == .worktreePath }.count == 0)
    }
}
