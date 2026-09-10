import Testing
import Foundation
@testable import ClaudeTopKit

/// The cascade. Every bug in this project will live here.
///
/// Four tiers, first hit wins. The rule that matters most is that a stamped process whose
/// session is gone becomes an orphan and never a system process: on the reference machine
/// that was 27 processes, some running for 22 hours, each still naming the session that
/// spawned it. Charging those to "other" is how they stay invisible.
@Suite("Attribution cascade")
struct AttributionCascadeTests {

    // MARK: - builders

    private func proc(_ pid: Int32, ppid: Int32 = 1, cmd: String = "/bin/sleep") -> ProcessSample {
        ProcessSample(pid: pid, ppid: ppid, rssBytes: 1024, cpuTime: 1,
                      startedAt: Date(timeIntervalSince1970: 1_000_000), command: cmd)
    }

    private func env(_ pid: Int32, session: Int32? = nil, pwd: String? = nil) -> ProcessEnvironment {
        ProcessEnvironment(pid: pid,
                           messagingSocket: session.map { "/tmp/cc-socks/\($0).sock" },
                           hostSessionID: nil, entrypoint: nil, pwd: pwd)
    }

    private func session(_ pid: Int32, _ cwd: String, uuid: String) -> SessionInfo {
        SessionInfo(pid: pid, cwd: cwd, sessionID: uuid,
                    startedAt: Date(timeIntervalSince1970: 900_000))
    }

    private let worktreeA = "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page-63c477"
    private let worktreeB = "/Users/USER/git_repositories/tradebot/.claude/worktrees/flow-testing-670e04"

    private func resolve(_ procs: [ProcessSample],
                         _ envs: [ProcessEnvironment],
                         _ sessions: [SessionInfo]) -> [Int32: ProcessAttribution] {
        AttributionEngine.resolveProcesses(
            processes: procs,
            environments: Dictionary(uniqueKeysWithValues: envs.map { ($0.pid, $0) }),
            sessions: sessions)
    }

    // MARK: - tier 1, env stamp

    @Test("A stamped process is charged to the live session that spawned it")
    func tier1LiveSession() {
        let r = resolve([proc(500)], [env(500, session: 100)],
                        [session(100, worktreeA, uuid: "uuid-a")])
        #expect(r[500]?.key == .session(uuid: "uuid-a"))
        #expect(r[500]?.tier == .envStamp)
    }

    @Test("A stamped process whose session is gone becomes an orphan, never a system process")
    func tier1DeadSessionBecomesOrphan() {
        // The case the tool exists for.
        let r = resolve([proc(500)], [env(500, session: 100, pwd: worktreeA)], [])
        #expect(r[500]?.key == .orphan(repo: "reader-app", worktree: "terms-page-63c477"))
        #expect(r[500]?.tier == .envStamp)
    }

    @Test("Two dead sessions in one worktree collapse into a single orphan group")
    func deadSessionsShareAWorktree() {
        // Happens when a worktree is worked twice. The reference capture has exactly this:
        // sessions 46108 and 51801 both died in pricing-api::revenue-share.
        let r = resolve([proc(500), proc(501)],
                        [env(500, session: 100, pwd: worktreeA),
                         env(501, session: 200, pwd: worktreeA)], [])
        #expect(r[500]?.key == r[501]?.key)
    }

    @Test("An orphan takes its worktree from a sibling when its own PWD has moved on")
    func orphanInheritsWorktreeFromSibling() {
        // A child that chdir'd elsewhere still belongs to the session that spawned it.
        // Splitting it into its own group would hide it from the worktree it came from.
        let r = resolve([proc(500), proc(501)],
                        [env(500, session: 100, pwd: worktreeA),
                         env(501, session: 100, pwd: "/tmp")], [])
        #expect(r[501]?.key == .orphan(repo: "reader-app", worktree: "terms-page-63c477"))
    }

    @Test("An orphan with no discoverable worktree is still an orphan, keyed by its session")
    func orphanWithNoWorktree() {
        let r = resolve([proc(500)], [env(500, session: 100, pwd: "/tmp")], [])
        guard case .orphan(let repo, let worktree)? = r[500]?.key else {
            Issue.record("expected an orphan, got \(String(describing: r[500]?.key))")
            return
        }
        #expect(repo.isEmpty)
        #expect(worktree.contains("100"), "the dead session's pid is what is left to key on")
    }

    @Test("A live session's stamp wins even when the process sits outside any worktree")
    func liveStampBeatsMissingWorktree() {
        let r = resolve([proc(500)], [env(500, session: 100, pwd: "/Users/USER")],
                        [session(100, "/Users/USER", uuid: "uuid-a")])
        #expect(r[500]?.key == .session(uuid: "uuid-a"))
    }

    // MARK: - tier 2, process tree

    @Test("An unstamped child of a live session is charged to that session")
    func tier2DirectChild() {
        let r = resolve([proc(100), proc(500, ppid: 100)], [],
                        [session(100, worktreeA, uuid: "uuid-a")])
        #expect(r[500]?.key == .session(uuid: "uuid-a"))
        #expect(r[500]?.tier == .processTree)
    }

    @Test("A grandchild through an unstamped intermediate is still charged to the session")
    func tier2Grandchild() {
        let r = resolve([proc(100), proc(500, ppid: 100), proc(501, ppid: 500)], [],
                        [session(100, worktreeA, uuid: "uuid-a")])
        #expect(r[501]?.key == .session(uuid: "uuid-a"))
    }

    @Test("A parent cycle does not hang the walk")
    func tier2CycleTerminates() {
        // Not reachable through a real process table, but the table is sampled while it
        // mutates, so a self-parent or a cycle can be observed. A hang here would stall
        // every sampler tick after it.
        let r = resolve([proc(500, ppid: 501), proc(501, ppid: 500)], [], [])
        #expect(r.count == 2)
    }

    @Test("The session process itself is charged to its own session")
    func sessionRootIsItsOwnSession() {
        let r = resolve([proc(100)], [], [session(100, worktreeA, uuid: "uuid-a")])
        #expect(r[100]?.key == .session(uuid: "uuid-a"))
    }

    // MARK: - tier 3, worktree path

    @Test("An unstamped, unparented process in a live worktree joins that session")
    func tier3LiveWorktree() {
        // Re-exec'd watchers lose the environment but keep the working directory.
        let r = resolve([proc(500)], [env(500, pwd: worktreeA + "/apps/web")],
                        [session(100, worktreeA, uuid: "uuid-a")])
        #expect(r[500]?.key == .session(uuid: "uuid-a"))
        #expect(r[500]?.tier == .worktreePath)
    }

    @Test("An unstamped process in a worktree with no live session is an orphan")
    func tier3OrphanedWorktree() {
        let r = resolve([proc(500)], [env(500, pwd: worktreeA)], [])
        #expect(r[500]?.key == .orphan(repo: "reader-app", worktree: "terms-page-63c477"))
        #expect(r[500]?.tier == .worktreePath)
    }

    @Test("A session anywhere inside a worktree claims processes elsewhere in it")
    func tier3SessionInSubdirectory() {
        let r = resolve([proc(500)], [env(500, pwd: worktreeA + "/apps/api")],
                        [session(100, worktreeA + "/packages/core", uuid: "uuid-a")])
        #expect(r[500]?.key == .session(uuid: "uuid-a"))
    }

    @Test("A plain repository checkout is not a worktree and does not attribute")
    func tier3PlainCheckoutIsNotAWorktree() {
        // Only `.claude/worktrees/` counts. Charging everything under a repository to a
        // session would sweep up editors, language servers and shells that belong to the
        // person, not to any agent.
        let r = resolve([proc(500)], [env(500, pwd: "/Users/USER/git_repositories/reader-app")], [])
        #expect(r[500]?.key == .system(family: .other))
    }

    // MARK: - tier 4, system families

    @Test("Families come from the executable path")
    func tier4Families() {
        #expect(AttributionEngine.systemFamily(
            forCommand: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") == .chrome)
        #expect(AttributionEngine.systemFamily(
            forCommand: "/Applications/Docker.app/Contents/MacOS/com.docker.backend") == .docker)
        #expect(AttributionEngine.systemFamily(
            forCommand: "/Applications/Claude.app/Contents/MacOS/Claude") == .claudeDesktop)
        #expect(AttributionEngine.systemFamily(forCommand: "/usr/sbin/cfprefsd") == .other)
    }

    @Test("The Docker VM process is recognised as Docker")
    func tier4DockerVM() {
        // The single largest CPU consumer measured, at 188-271%. A Claude-only view would
        // have hidden it, which is why "everything else" is not an optional section.
        #expect(AttributionEngine.systemFamily(
            forCommand: "/Applications/Docker.app/Contents/MacOS/com.docker.krun") == .docker)
    }

    @Test("A command that merely mentions a family in its arguments is not that family")
    func tier4ArgumentsAreNotTheExecutable() {
        // The reference capture contains shell one-liners with `docker` in the argument
        // string. Matching the whole command line would file them under Docker and inflate
        // the largest bucket on the machine with things that are not Docker.
        #expect(AttributionEngine.systemFamily(
            forCommand: "/bin/sh -c ids=$(docker ps -q) && echo \"$ids\"") == .other)
        #expect(AttributionEngine.systemFamily(
            forCommand: "/usr/bin/grep -r 'Google Chrome' .") == .other)
    }

    // MARK: - precedence

    @Test("A stamp outranks the process tree when the two disagree")
    func stampBeatsProcessTree() {
        // Reparenting: the process was spawned by session A, then adopted under session B.
        // The stamp is what survived, and it is what is true.
        let r = resolve([proc(100), proc(200), proc(500, ppid: 200)],
                        [env(500, session: 100)],
                        [session(100, worktreeA, uuid: "uuid-a"),
                         session(200, worktreeB, uuid: "uuid-b")])
        #expect(r[500]?.key == .session(uuid: "uuid-a"))
        #expect(r[500]?.tier == .envStamp)
    }

    @Test("A dead session's stamp outranks a live session sharing its worktree")
    func deadStampBeatsLiveWorktree() {
        // A worktree picked back up by a new session. The leftovers of the previous one
        // are still leftovers, and folding them into the new session would mean the new
        // session appears to be burning CPU it never asked for.
        let r = resolve([proc(500)], [env(500, session: 100, pwd: worktreeA)],
                        [session(999, worktreeA, uuid: "uuid-new")])
        #expect(r[500]?.key == .orphan(repo: "reader-app", worktree: "terms-page-63c477"))
        #expect(r[500]?.tier == .envStamp)
    }

    @Test("Every process is accounted for exactly once")
    func everyProcessAccountedFor() {
        let procs = (1...20).map { proc(Int32($0), ppid: 1) }
        let r = resolve(procs, [], [])
        #expect(r.count == 20)
        #expect(Set(r.keys) == Set(procs.map(\.pid)))
    }

    // MARK: - against the reference capture

    @Test("All 44 stamped processes in the capture resolve through the stamp")
    func fixtureStampedResolveByStamp() throws {
        let r = AttributionEngine.resolveProcesses(
            processes: try Fixture.processes().map {
                ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                              cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
            },
            environments: try Fixture.environments(),
            sessions: try Fixture.sessions())

        let stamped = try Fixture.environments().values.filter { $0.spawningSessionPID != nil }
        #expect(stamped.count == 44)
        for e in stamped {
            #expect(r[e.pid]?.tier == .envStamp, "pid \(e.pid) did not resolve through its stamp")
        }
    }

    @Test("The capture's five dead sessions produce four orphan groups holding 27 processes")
    func fixtureOrphanGroups() throws {
        let r = AttributionEngine.resolveProcesses(
            processes: try Fixture.processes().map {
                ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                              cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
            },
            environments: try Fixture.environments(),
            sessions: try Fixture.sessions())

        let orphaned = r.values.filter { if case .orphan = $0.key { return true } else { return false } }
        // Five dead sessions, but two of them died in the same worktree, so the person
        // looking at the output sees four things to clean up rather than five.
        #expect(Set(orphaned.map(\.key)).count == 4)

        // 27 processes carry a dead session's stamp. The groups hold 41, because the
        // cascade also collects their unstamped descendants, and that difference is the
        // point: a Postgres left behind by a dead session forks a dozen workers and only
        // the postmaster carries the stamp. Reporting 27 would understate what killing
        // that group actually frees.
        let stamped = try Fixture.environments().values.filter { e in
            guard let spawner = e.spawningSessionPID else { return false }
            return !Set(try! Fixture.sessions().map(\.pid)).contains(spawner)
        }
        #expect(stamped.count == 27)
        #expect(orphaned.count == 41)
    }

    @Test("A stamped process's unstamped children are charged to the same orphan group")
    func fixtureOrphanedPostgresWorkersRollUp() throws {
        let r = AttributionEngine.resolveProcesses(
            processes: try Fixture.processes().map {
                ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                              cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
            },
            environments: try Fixture.environments(),
            sessions: try Fixture.sessions())

        // 61849 is a Postgres postmaster stamped to a session that no longer exists. Its
        // workers carry no stamp of their own and would otherwise read as unremarkable
        // system processes sitting at the bottom of the list.
        let postmaster = try #require(r[61849])
        #expect(postmaster.tier == .envStamp)
        for worker: Int32 in [61850, 61851, 61852, 61853, 61854, 61858, 61859, 61860] {
            #expect(r[worker]?.key == postmaster.key, "worker \(worker) left behind")
            #expect(r[worker]?.tier == .processTree)
        }
    }

    @Test("No stamped process in the capture is ever charged to a system family")
    func fixtureNoStampedProcessBecomesSystem() throws {
        let r = AttributionEngine.resolveProcesses(
            processes: try Fixture.processes().map {
                ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                              cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
            },
            environments: try Fixture.environments(),
            sessions: try Fixture.sessions())

        for (pid, e) in try Fixture.environments() where e.spawningSessionPID != nil {
            if case .system = r[pid]?.key {
                Issue.record("stamped pid \(pid) was charged to a system family")
            }
        }
    }

    @Test("The capture's six unstamped watchers resolve to their live session by path")
    func fixtureTier3Watchers() throws {
        let r = AttributionEngine.resolveProcesses(
            processes: try Fixture.processes().map {
                ProcessSample(pid: $0.pid, ppid: $0.ppid, rssBytes: $0.rssKB * 1024,
                              cpuTime: $0.cpuTime, startedAt: Date(), command: $0.command)
            },
            environments: try Fixture.environments(),
            sessions: try Fixture.sessions())

        // All six sit in reader-app::help-desk, which still has a live session, so they
        // belong to it rather than to the orphan pile.
        let live = try Fixture.sessions().first { $0.cwd.hasSuffix("help-desk-51d6e2") }
        let helpDesk = try #require(live)
        for pid: Int32 in [13667, 13793, 96907, 96923, 96924, 96925] {
            #expect(r[pid]?.key == .session(uuid: helpDesk.sessionID), "pid \(pid)")
        }
    }
}
