import Testing
import Foundation
@testable import ClaudeTopKit

/// The most important tests in this repository.
///
/// Everything else being wrong produces a misleading number. This being wrong kills work
/// that was still running. Selection is by env stamp for processes and by the compose
/// `working_dir` label for containers, and by nothing else: no path matching, no ppid
/// walking, no name parsing. Each of those could cross into a session that is still
/// working, and none of them is worth the reach it buys.
@Suite("Reap safety")
struct ReapSafetyTests {

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

    private func plan(for key: AttributionKey,
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
            sessions: sessions,
            keepMarkedWorktrees: keep)
    }

    // MARK: - the one that matters

    @Test("Reaping one session selects nothing belonging to another live session")
    func neverCrossesIntoAnotherSession() {
        // Two sessions working simultaneously, which is the normal state of this machine.
        let sessions = [session(100, worktreeA, uuid: "uuid-a"),
                        session(200, worktreeB, uuid: "uuid-b")]
        let processes = [proc(100), proc(500, ppid: 100), proc(501, ppid: 100),
                         proc(200), proc(600, ppid: 200), proc(601, ppid: 200)]
        let environments = [env(500, session: 100), env(501, session: 100),
                            env(600, session: 200), env(601, session: 200)]

        let a = plan(for: .session(uuid: "uuid-a"), processes: processes,
                     environments: environments, sessions: sessions)

        let bPIDs: Set<Int32> = [200, 600, 601]
        #expect(Set(a.processes.map(\.pid)).intersection(bPIDs).isEmpty,
                "a reap of session A selected processes belonging to session B")
        #expect(Set(a.processes.map(\.pid)) == [500, 501])
    }

    @Test("Reaping an orphan selects nothing belonging to a live session in the same worktree")
    func orphanReapSparesTheLiveSessionThatTookOverTheWorktree() {
        // A worktree picked back up. The old session's leftovers are reapable; the new
        // session's processes are sitting in the same directory and are not.
        let sessions = [session(999, worktreeA, uuid: "uuid-new")]
        let processes = [proc(500), proc(600)]
        let environments = [env(500, session: 100, pwd: worktreeA),   // dead session 100
                            env(600, session: 999, pwd: worktreeA)]   // the live one

        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     processes: processes, environments: environments, sessions: sessions)
        #expect(Set(p.processes.map(\.pid)) == [500])
    }

    // MARK: - selection is by stamp, never by anything else

    @Test("A process sitting in the worktree without a stamp is never selected")
    func neverSelectsByPath() {
        // It might belong to the session. It might be the person's own editor or shell.
        // A reap does not get to guess, so this one is reported and left alone.
        let processes = [proc(500)]
        let environments = [env(500, pwd: worktreeA)]
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     processes: processes, environments: environments)
        #expect(p.processes.isEmpty)
    }

    @Test("A child of a selected process is not itself selected")
    func neverSelectsByParent() {
        // Signalling the parent is what stops the children: a Postgres postmaster shuts
        // its workers down cleanly on SIGTERM. Walking the tree to signal each one both
        // risks stepping outside the session and interferes with that shutdown.
        let processes = [proc(500), proc(501, ppid: 500)]
        let environments = [env(500, session: 100, pwd: worktreeA)]
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     processes: processes, environments: environments)
        #expect(Set(p.processes.map(\.pid)) == [500])
    }

    @Test("A process stamped by a session that resolves elsewhere is not selected")
    func neverSelectsAForeignStamp() {
        let processes = [proc(500), proc(600)]
        let environments = [env(500, session: 100, pwd: worktreeA),
                            env(600, session: 200, pwd: worktreeB)]
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     processes: processes, environments: environments)
        #expect(Set(p.processes.map(\.pid)) == [500])
    }

    // MARK: - containers

    @Test("A compose project in the target worktree is selected")
    func selectsOwnComposeProject() {
        let c = container("terms-db-1", workingDir: worktreeA)
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     containers: [c])
        #expect(p.containers.map(\.containerID) == [c.id])
    }

    @Test("A compose project belonging to a different worktree is never selected")
    func neverSelectsAnotherWorktreesComposeProject() {
        let mine = container("terms-db-1", workingDir: worktreeA)
        let theirs = container("flow-db-1", workingDir: worktreeB)
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     containers: [mine, theirs])
        #expect(p.containers.map(\.containerID) == [mine.id])
    }

    @Test("A tier-C unattributed container is never selected, by anything")
    func neverSelectsUnattributedContainers() {
        // No label says who wanted it, so nothing may decide it is disposable.
        let bare = container("sp-chatroom-pg")
        for key: AttributionKey in [.orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                                    .session(uuid: "uuid-a"),
                                    .unattributed,
                                    .system(family: .docker)] {
            #expect(plan(for: key, containers: [bare]).containers.isEmpty)
        }
    }

    @Test("A testcontainers cluster is never selected")
    func neverSelectsTestcontainers() {
        // Its own reaper will take it down. Racing that reaper achieves nothing and can
        // interrupt a test run that is still going.
        let db = container("strange_borg", labels: [
            "org.testcontainers": "true", "org.testcontainers.session-id": "30ec6daa"])
        let ryuk = container("testcontainers-ryuk-30ec6daa", labels: [
            "org.testcontainers": "true", "org.testcontainers.ryuk": "true"])
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     containers: [db, ryuk])
        #expect(p.containers.isEmpty)
    }

    // MARK: - what is not reapable at all

    @Test("System families are never reapable")
    func systemIsNeverReapable() {
        let processes = [proc(500, cmd: "/Applications/Docker.app/Contents/MacOS/com.docker.krun")]
        for family: SystemFamily in [.docker, .chrome, .claudeDesktop, .other] {
            let p = plan(for: .system(family: family), processes: processes)
            #expect(p.isEmpty, "\(family) was treated as reapable")
        }
    }

    @Test("The unattributed bucket is never reapable")
    func unattributedIsNeverReapable() {
        let processes = [proc(500)]
        let containers = [container("sp-chatroom-pg")]
        #expect(plan(for: .unattributed, processes: processes, containers: containers).isEmpty)
    }

    @Test("A keep file exempts the worktree entirely and says so")
    func keepFileExempts() {
        let processes = [proc(500)]
        let environments = [env(500, session: 100, pwd: worktreeA)]
        let containers = [container("terms-db-1", workingDir: worktreeA)]
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     processes: processes, environments: environments,
                     containers: containers, keep: [worktreeA])
        #expect(p.isEmpty)
        #expect(p.exemptedByKeepFile)
    }

    @Test("Every selection carries the reason it was selected")
    func everySelectionIsExplained() {
        // Written to the reap log with each kill, so a reap can be audited afterwards
        // rather than only trusted beforehand.
        let processes = [proc(500)]
        let environments = [env(500, session: 100, pwd: worktreeA)]
        let containers = [container("terms-db-1", workingDir: worktreeA)]
        let p = plan(for: .orphan(repo: "reader-app", worktree: "terms-page-63c477"),
                     processes: processes, environments: environments, containers: containers)
        #expect(p.processes.allSatisfy { !$0.reason.isEmpty })
        #expect(p.containers.allSatisfy { !$0.reason.isEmpty })
        #expect(p.processes.first?.reason.contains("100") == true,
                "the reason should name the stamp that selected it")
    }

    // MARK: - against the reference capture

    @Test("Reaping each live session in the capture never touches another session")
    func fixtureLiveSessionsAreIsolated() throws {
        let procs = try Fixture.processes().map {
            ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                          cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
        }
        let envs = try Fixture.environments()
        let sessions = try Fixture.sessions()
        let attribution = AttributionEngine.resolveProcesses(
            processes: procs, environments: envs, sessions: sessions)

        for target in sessions {
            let p = AttributionEngine.reapPlan(
                for: .session(uuid: target.sessionID), processes: procs,
                environments: envs, containers: try Fixture.containers(), sessions: sessions)

            for selected in p.processes {
                guard case .session(let uuid)? = attribution[selected.pid]?.key else {
                    Issue.record("reap of \(target.sessionID) selected unattributed pid \(selected.pid)")
                    continue
                }
                #expect(uuid == target.sessionID,
                        "reap of \(target.sessionID) selected pid \(selected.pid) from \(uuid)")
            }
        }
    }

    @Test("Reaping every orphan in the capture never touches a live session")
    func fixtureOrphanReapsSpareLiveSessions() throws {
        let procs = try Fixture.processes().map {
            ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                          cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
        }
        let envs = try Fixture.environments()
        let sessions = try Fixture.sessions()
        let attribution = AttributionEngine.resolveProcesses(
            processes: procs, environments: envs, sessions: sessions)
        let orphanKeys = Set(attribution.values.map(\.key).filter {
            if case .orphan = $0 { return true } else { return false }
        })
        #expect(orphanKeys.count == 4)

        var totalSelected = 0
        for key in orphanKeys {
            let p = AttributionEngine.reapPlan(
                for: key, processes: procs, environments: envs,
                containers: try Fixture.containers(), sessions: sessions)
            totalSelected += p.processes.count
            for selected in p.processes {
                if case .session(let uuid)? = attribution[selected.pid]?.key {
                    Issue.record("orphan reap selected pid \(selected.pid) from live session \(uuid)")
                }
            }
        }
        // The 27 processes carrying a dead session's stamp, and only those. Their
        // unstamped children go down with them rather than being signalled directly.
        #expect(totalSelected == 27)
    }
}
