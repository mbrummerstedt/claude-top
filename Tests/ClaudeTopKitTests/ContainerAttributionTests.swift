import Testing
import Foundation
@testable import ClaudeTopKit

/// Containers were 2.3 GB and the single largest CPU consumer on the reference machine,
/// so leaving them out would miss most of the problem. Seven of thirteen map cleanly. The
/// design is honest about the other six rather than guessing, because a container shown
/// under the wrong session is a container someone kills while it is still in use.
@Suite("Container attribution")
struct ContainerAttributionTests {

    private func container(_ name: String, labels: [String: String] = [:]) -> ContainerInfo {
        ContainerInfo(id: "id-" + name, name: name, image: "postgres:17-alpine",
                      labels: labels, cpuPercent: nil, rssBytes: nil)
    }

    private func session(_ pid: Int32, _ cwd: String, uuid: String) -> SessionInfo {
        SessionInfo(pid: pid, cwd: cwd, sessionID: uuid, startedAt: Date())
    }

    private let worktree = "/Users/USER/git_repositories/tradebot/.claude/worktrees/device-identify-2186f8"

    // MARK: - tier A, compose

    @Test("A compose project in a live session's worktree is charged to that session")
    func composeToLiveSession() {
        let c = container("tb-replay-postgres-1",
                          labels: ["com.docker.compose.project.working_dir": worktree])
        let r = AttributionEngine.resolveContainers(
            containers: [c], sessions: [session(100, worktree, uuid: "uuid-a")])
        #expect(r[c.id]?.key == .session(uuid: "uuid-a"))
        #expect(r[c.id]?.tier == .containerLabel)
    }

    @Test("A compose project in a worktree with no live session is an orphan")
    func composeToOrphan() {
        // The 47-hour Postgres nobody remembers starting.
        let c = container("feed-service-postgres-1", labels: [
            "com.docker.compose.project.working_dir":
                "/Users/USER/git_repositories/feed-service/.claude/worktrees/ui-improvements-053b29"])
        let r = AttributionEngine.resolveContainers(containers: [c], sessions: [])
        #expect(r[c.id]?.key == .orphan(repo: "feed-service", worktree: "ui-improvements-053b29"))
    }

    @Test("A compose working_dir below the worktree root still resolves to the worktree")
    func composeWorkingDirInSubdirectory() {
        // `platform-uiqa-db-1` in the reference capture has its compose file in an `infra`
        // subdirectory. Comparing the label to a session cwd for equality would miss it.
        let c = container("platform-uiqa-db-1", labels: [
            "com.docker.compose.project.working_dir":
                "/Users/USER/git_repositories/platform/.claude/worktrees/qa-testing-a538f6/infra"])
        let r = AttributionEngine.resolveContainers(containers: [c], sessions: [])
        #expect(r[c.id]?.key == .orphan(repo: "platform", worktree: "qa-testing-a538f6"))
    }

    @Test("Attribution comes from the label even when the name would give the same answer")
    func labelNotName() {
        // `account-deletion-d7fb2e-db-1` embeds the worktree hash in its container name.
        // That is how the compose project happened to be named, not a contract, and
        // parsing names is how a tool starts being confidently wrong.
        let dir = "/Users/USER/git_repositories/reader-app/.claude/worktrees/account-deletion-d7fb2e"
        let c = container("account-deletion-d7fb2e-db-1",
                          labels: ["com.docker.compose.project.working_dir": dir])
        let named = container("account-deletion-d7fb2e-db-2")   // same name shape, no label

        let r = AttributionEngine.resolveContainers(containers: [c, named], sessions: [])
        #expect(r[c.id]?.key == .orphan(repo: "reader-app", worktree: "account-deletion-d7fb2e"))
        #expect(r[named.id]?.key == .unattributed)
    }

    @Test("A compose project outside any worktree is unattributed, not guessed at")
    func composeOutsideWorktree() {
        let c = container("some-app-db-1", labels: [
            "com.docker.compose.project.working_dir": "/Users/USER/git_repositories/some-app"])
        let r = AttributionEngine.resolveContainers(containers: [c], sessions: [])
        #expect(r[c.id]?.key == .unattributed)
    }

    // MARK: - tier B, testcontainers

    @Test("Testcontainers containers cluster by session id and stay unattributed")
    func testcontainersCluster() {
        // Mapping a cluster to a Claude session needs the process holding a socket to
        // ryuk's published port. That is a stretch goal, so the cluster is grouped and
        // reported honestly rather than attached to a plausible-looking session.
        let c = container("strange_borg", labels: [
            "org.testcontainers": "true",
            "org.testcontainers.session-id": "30ec6daa-a485-44c2-8556-3210cf4f1390"])
        let r = AttributionEngine.resolveContainers(containers: [c], sessions: [])
        #expect(r[c.id]?.key == .unattributed)
        #expect(r[c.id]?.clusterID == "30ec6daa-a485-44c2-8556-3210cf4f1390")
        #expect(r[c.id]?.tier == .containerLabel)
    }

    @Test("A ryuk reaper joins its own cluster despite carrying no session-id label")
    func ryukJoinsItsCluster() {
        // Testcontainers does not put the session id on the reaper as a label; it puts it
        // in the reaper's name, in a format the library itself emits. Reading it there is
        // the only way to show a database and the thing that will clean it up as one unit,
        // which is the unit a person actually decides about.
        let db = container("strange_borg", labels: [
            "org.testcontainers": "true",
            "org.testcontainers.session-id": "30ec6daa-a485-44c2-8556-3210cf4f1390"])
        let ryuk = container("testcontainers-ryuk-30ec6daa-a485-44c2-8556-3210cf4f1390", labels: [
            "org.testcontainers": "true", "org.testcontainers.ryuk": "true"])

        let r = AttributionEngine.resolveContainers(containers: [db, ryuk], sessions: [])
        #expect(r[ryuk.id]?.clusterID == r[db.id]?.clusterID)
        #expect(r[ryuk.id]?.key == .unattributed)
    }

    @Test("A ryuk reaper with an unreadable name is unattributed rather than mis-clustered")
    func ryukWithoutParsableName() {
        let ryuk = container("hopeful_lamarr",
                             labels: ["org.testcontainers": "true", "org.testcontainers.ryuk": "true"])
        let r = AttributionEngine.resolveContainers(containers: [ryuk], sessions: [])
        #expect(r[ryuk.id]?.key == .unattributed)
        #expect(r[ryuk.id]?.clusterID == nil)
    }

    // MARK: - tier C

    @Test("A container with no labels is unattributed and carries no cluster")
    func noLabels() {
        // Started by a bare `docker run --name`. Nothing on it says who wanted it.
        let c = container("sp-chatroom-pg")
        let r = AttributionEngine.resolveContainers(containers: [c], sessions: [])
        #expect(r[c.id]?.key == .unattributed)
        #expect(r[c.id]?.tier == .unresolved)
        #expect(r[c.id]?.clusterID == nil)
    }

    // MARK: - against the reference capture

    @Test("The capture's thirteen containers split four live, three orphaned, six unplaced")
    func fixtureContainerSplit() throws {
        let containers = try Fixture.containers()
        let r = AttributionEngine.resolveContainers(containers: containers,
                                                    sessions: try Fixture.sessions())
        #expect(r.count == 13)

        let live = r.values.filter { if case .session = $0.key { return true } else { return false } }
        let orphaned = r.values.filter { if case .orphan = $0.key { return true } else { return false } }
        let unplaced = r.values.filter { $0.key == .unattributed }

        #expect(live.count == 4)
        #expect(orphaned.count == 3)
        #expect(unplaced.count == 6)   // 5 testcontainers plus the bare `docker run`
    }

    @Test("The capture's five testcontainers form three clusters, reapers included")
    func fixtureTestcontainersClusters() throws {
        let r = AttributionEngine.resolveContainers(containers: try Fixture.containers(),
                                                    sessions: try Fixture.sessions())
        let clusters = Set(r.values.compactMap(\.clusterID))
        #expect(clusters.count == 3)

        // Two of the three clusters have their reaper still running, so those show as two
        // containers each and the third as one.
        let sizes = clusters.map { id in r.values.filter { $0.clusterID == id }.count }.sorted()
        #expect(sizes == [1, 2, 2])
    }

    @Test("Every container in the capture is placed somewhere")
    func fixtureNoContainerDropped() throws {
        let containers = try Fixture.containers()
        let r = AttributionEngine.resolveContainers(containers: containers,
                                                    sessions: try Fixture.sessions())
        for c in containers {
            #expect(r[c.id] != nil, "container \(c.name) fell out of the accounting")
        }
    }
}
