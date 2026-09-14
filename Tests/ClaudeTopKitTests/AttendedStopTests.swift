import Testing
import Foundation
@testable import ClaudeTopKit

/// A person pressing Stop on a named row, as against a timer deciding on its own.
///
/// The unattended reaper selects by env stamp and nothing else, and `ReapSafetyTests`
/// holds that line. This suite covers the other half: a row names a worktree and lists
/// what it is holding, so its button has to stop what it lists. A row saying "4p" whose
/// button signals nothing is a broken button, and that is what it was: the four processes
/// were placed by their working directory rather than by a stamp, so every one of them
/// fell outside the plan and the click ended in silence.
///
/// Widening reaches further, so everything it must still refuse is tested here too.
@Suite("Attended stop")
struct AttendedStopTests {

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

    private func container(_ name: String, workingDir: String? = nil,
                           labels: [String: String] = [:]) -> ContainerInfo {
        var l = labels
        if let workingDir { l["com.docker.compose.project.working_dir"] = workingDir }
        return ContainerInfo(id: "id-" + name, name: name, image: "postgres:17",
                             labels: l, cpuPercent: nil, rssBytes: nil)
    }

    private let worktreeA = "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page-63c477"
    private let worktreeB = "/Users/USER/git_repositories/tradebot/.claude/worktrees/flow-testing-670e04"
    private let orphanA = AttributionKey.orphan(repo: "reader-app", worktree: "terms-page-63c477")

    private func plan(for key: AttributionKey,
                      scope: ReapScope,
                      processes: [ProcessSample] = [],
                      environments: [ProcessEnvironment] = [],
                      containers: [ContainerInfo] = [],
                      sessions: [SessionInfo] = [],
                      keep: Set<String> = []) -> ReapPlan {
        AttributionEngine.reapPlan(
            for: key,
            processes: processes,
            environments: Dictionary(uniqueKeysWithValues: environments.map { ($0.pid, $0) }),
            containers: containers,
            roster: Roster(sessions: sessions, source: .live),
            keepMarkedWorktrees: keep,
            scope: scope)
    }

    // MARK: - the bug

    /// Found live. Four processes of a dev server, started from the desktop app's own
    /// terminal rather than by an agent, so none of them carried a messaging socket. The
    /// worktree's session had exited, the row read `4p`, and pressing Stop produced a
    /// spinner, then the button again, and not one line in the reap log.
    @Test("A row's Stop selects what the row shows, whatever tier placed it")
    func attendedStopReachesUnstampedProcesses() {
        // 500 never left the worktree and carries no stamp, which is the whole of what is
        // known about it. 502 was stamped by a session that has since exited.
        let processes = [proc(500), proc(502)]
        let environments = [env(500, pwd: worktreeA), env(502, session: 100, pwd: worktreeA)]

        let wide = plan(for: orphanA, scope: .attributed,
                        processes: processes, environments: environments)
        let narrow = plan(for: orphanA, scope: .stamped,
                          processes: processes, environments: environments)

        #expect(Set(wide.processes.map(\.pid)) == [500, 502])
        #expect(Set(narrow.processes.map(\.pid)) == [502],
                "the timer still sees only the stamped one")
    }

    @Test("A child placed only by its parent is selected, so nothing survives its parent")
    func attendedStopReachesTheWholeTree() {
        // The case the narrow rule accepted the cost of: an unstamped child was left for
        // its parent's death to take with it, which works until the parent is a shell
        // wrapper that exits and leaves the child reparented and running.
        let processes = [proc(500), proc(501, ppid: 500), proc(502, ppid: 501)]
        let environments = [env(500, session: 100, pwd: worktreeA), env(501), env(502)]

        let wide = plan(for: orphanA, scope: .attributed,
                        processes: processes, environments: environments)
        let narrow = plan(for: orphanA, scope: .stamped,
                          processes: processes, environments: environments)

        #expect(Set(wide.processes.map(\.pid)) == [500, 501, 502])
        #expect(Set(narrow.processes.map(\.pid)) == [500])
    }

    @Test("The unattended reaper still selects only stamped processes")
    func unattendedStaysNarrow() {
        let processes = [proc(500)]
        let environments = [env(500, pwd: worktreeA)]

        let p = plan(for: orphanA, scope: .stamped,
                     processes: processes, environments: environments)

        #expect(p.processes.isEmpty, "no stamp, so the timer may not touch it")
    }

    @Test("Scope defaults to the narrow rule, so a caller reaches wide only on purpose")
    func defaultScopeIsNarrow() {
        let wide = AttributionEngine.reapPlan(
            for: orphanA, processes: [proc(500)],
            environments: [500: env(500, pwd: worktreeA)], containers: [],
            roster: Roster(sessions: [], source: .live))

        #expect(wide.processes.isEmpty)
    }

    // MARK: - what widening must still refuse

    @Test("A wide stop never selects a live session's processes")
    func neverCrossesIntoALiveSession() {
        let live = session(100, worktreeB, uuid: "live")
        let processes = [proc(500), proc(600), proc(601, ppid: 600)]
        let environments = [env(500, pwd: worktreeA), env(600, session: 100), env(601)]

        let p = plan(for: orphanA, scope: .attributed, processes: processes,
                     environments: environments, sessions: [live])

        #expect(Set(p.processes.map(\.pid)) == [500],
                "600 and 601 are the live session's, at any tier")
    }

    /// The case the narrow rule was written for, and the reason widening is safe here:
    /// a process sitting in a worktree is attributed to whichever session holds that
    /// worktree now. When a live session has taken it over, the orphan's plan is empty
    /// because the processes are no longer the orphan's, not because the tier was refused.
    @Test("A wide stop on an orphan spares a live session that took over the worktree")
    func spareTheSessionThatTookOverTheWorktree() {
        let live = session(100, worktreeA, uuid: "live")
        let processes = [proc(500)]
        let environments = [env(500, pwd: worktreeA)]

        let p = plan(for: orphanA, scope: .attributed, processes: processes,
                     environments: environments, sessions: [live])

        #expect(p.processes.isEmpty)
    }

    @Test("A wide stop never selects claude-top's own machinery")
    func neverSelectsItself() {
        let app = "/Applications/ClaudeTop.app/Contents/MacOS/ClaudeTop"
        let processes = [proc(500, cmd: app), proc(501, cmd: "/usr/local/bin/claude-top --watch"),
                         proc(502, cmd: "/usr/bin/node")]
        let environments = [env(500, pwd: worktreeA), env(501, pwd: worktreeA),
                            env(502, pwd: worktreeA)]

        let p = plan(for: orphanA, scope: .attributed,
                     processes: processes, environments: environments)

        #expect(Set(p.processes.map(\.pid)) == [502])
    }

    @Test("A wide stop never selects a system process or the unattributed bucket")
    func neverSelectsWhatWasNeverAttributed() {
        // Placed nowhere: no stamp, no attributed ancestor, no worktree in its path.
        let processes = [proc(500, cmd: "/Applications/Google Chrome.app/Contents/MacOS/Chrome"),
                         proc(501)]
        let environments = [env(500, pwd: "/Users/USER"), env(501, pwd: "/Users/USER")]

        let p = plan(for: orphanA, scope: .attributed,
                     processes: processes, environments: environments)

        #expect(p.isEmpty)
        for key in [AttributionKey.system(family: .other), .unattributed] {
            #expect(plan(for: key, scope: .attributed, processes: processes,
                         environments: environments).isEmpty)
        }
    }

    @Test("A keep file exempts a worktree from a wide stop too")
    func keepFileStillExempts() {
        let processes = [proc(500)]
        let environments = [env(500, pwd: worktreeA)]

        let p = plan(for: orphanA, scope: .attributed, processes: processes,
                     environments: environments, keep: [worktreeA])

        #expect(p.isEmpty)
        #expect(p.refusal == .keepFile)
    }

    @Test("A wide stop on a roster that was not read selects nothing")
    func staleRosterStillRefuses() {
        let p = AttributionEngine.reapPlan(
            for: orphanA, processes: [proc(500)],
            environments: [500: env(500, pwd: worktreeA)], containers: [],
            roster: Roster(sessions: [], source: .cached(age: 90)),
            scope: .attributed)

        #expect(p.isEmpty)
        #expect(p.refusal == ReapRefusal.rosterNotLive)
    }

    @Test("A wide stop still takes only its own compose project, never testcontainers")
    func containerSelectionIsUnchanged() {
        let mine = container("mine", workingDir: worktreeA)
        let theirs = container("theirs", workingDir: worktreeB)
        let cluster = container("ryuk", labels: ["org.testcontainers.session-id": "abc"])
        let bare = container("sp-chatroom-pg")

        let p = plan(for: orphanA, scope: .attributed,
                     containers: [mine, theirs, cluster, bare])

        #expect(p.containers.map(\.containerID) == [mine.id])
    }

    @Test("Every wide selection carries the reason it was selected")
    func everyWideSelectionIsExplained() {
        let processes = [proc(500), proc(501, ppid: 500), proc(502)]
        let environments = [env(500, session: 100, pwd: worktreeA), env(501),
                            env(502, pwd: worktreeA)]

        let p = plan(for: orphanA, scope: .attributed, processes: processes,
                     environments: environments)

        #expect(p.processes.allSatisfy { !$0.reason.isEmpty })
        // The reason names the evidence, not the outcome. The reap log is read afterwards
        // by someone asking why a particular pid was signalled, and each of the three
        // rules answers that differently.
        #expect(p.processes.first { $0.pid == 500 }?.reason.contains("MESSAGING_SOCKET") == true)
        #expect(p.processes.first { $0.pid == 501 }?.reason.contains("process tree") == true)
        #expect(p.processes.first { $0.pid == 502 }?.reason.contains(worktreeA) == true)
    }

    // MARK: - saying what happened

    @Test("A stop that signalled nothing says so")
    func silenceIsReported() {
        let empty = ReapPlan(key: orphanA, processes: [], containers: [])
        let report = Renderer.stopReport(label: "reader-app::terms-page", plan: empty,
                                         outcome: nil)

        #expect(report != nil)
        #expect(report?.contains("reader-app::terms-page") == true)
    }

    @Test("A keep file is named as the reason, not reported as an empty result")
    func exemptionIsNamed() {
        let exempt = ReapPlan(key: orphanA, processes: [], containers: [],
                              refusal: .keepFile)
        let report = Renderer.stopReport(label: "reader-app::terms-page", plan: exempt,
                                         outcome: nil)

        #expect(report?.contains(".claude-top-keep") == true)
    }

    @Test("A plan whose targets had all exited by the time it ran says so")
    func alreadyGoneIsReported() {
        let p = ReapPlan(key: orphanA,
                         processes: [ReapTarget(pid: 500, command: "node", reason: "why")],
                         containers: [])
        let outcome = ReapOutcome(terminated: [], killed: [], survived: [],
                                  containersStopped: [])
        let report = Renderer.stopReport(label: "reader-app::terms-page", plan: p,
                                         outcome: outcome)

        #expect(report != nil)
    }

    @Test("A container docker would not stop is reported, not rounded into a success")
    func refusedContainerIsReported() {
        let p = ReapPlan(key: orphanA,
                         processes: [ReapTarget(pid: 500, command: "node", reason: "why")],
                         containers: [ReapComposeTarget(containerID: "abc", name: "db",
                                                        workingDirectory: worktreeA,
                                                        reason: "why")])
        let outcome = ReapOutcome(terminated: [500], killed: [], survived: [],
                                  containersStopped: [])
        let report = Renderer.stopReport(label: "reader-app::terms-page", plan: p,
                                         outcome: outcome)

        #expect(report?.contains("docker") == true)
    }

    /// `kill` reports "already gone" and "not yours to signal" the same way, so the report
    /// says what happened and not why. A wrong cause is worse than no cause here.
    @Test("A stop that signalled nothing does not guess at the reason")
    func noCauseIsInvented() {
        let p = ReapPlan(key: orphanA,
                         processes: [ReapTarget(pid: 500, command: "node", reason: "why")],
                         containers: [])
        let outcome = ReapOutcome(terminated: [], killed: [], survived: [],
                                  containersStopped: [])
        let report = Renderer.stopReport(label: "reader-app::terms-page", plan: p,
                                         outcome: outcome)

        #expect(report?.contains("exited") == false)
    }

    @Test("A stop that worked says nothing, because the row disappearing is the notice")
    func successIsQuiet() {
        let p = ReapPlan(key: orphanA,
                         processes: [ReapTarget(pid: 500, command: "node", reason: "why")],
                         containers: [])
        let outcome = ReapOutcome(terminated: [500], killed: [], survived: [],
                                  containersStopped: [])

        #expect(Renderer.stopReport(label: "reader-app::terms-page", plan: p,
                                    outcome: outcome) == nil)
    }

    @Test("A process that ignored both signals is named")
    func survivorsAreNamed() {
        let p = ReapPlan(key: orphanA,
                         processes: [ReapTarget(pid: 500, command: "node", reason: "why")],
                         containers: [])
        let outcome = ReapOutcome(terminated: [500], killed: [], survived: [500],
                                  containersStopped: [])
        let report = Renderer.stopReport(label: "reader-app::terms-page", plan: p,
                                         outcome: outcome)

        #expect(report?.contains("500") == true)
    }
}
