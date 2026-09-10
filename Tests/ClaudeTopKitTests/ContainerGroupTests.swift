import Testing
import Foundation
@testable import ClaudeTopKit

/// Containers rolled up into the thing a person thinks in: a project.
///
/// Nobody reasons about `bpb-replay-postgres-1`. They reason about "the stack my
/// device-identify worktree brought up", which is three containers that live and die
/// together. A single `Docker` row hides all of that, and it is consistently the largest
/// consumer on this machine.
@Suite("Container groups")
struct ContainerGroupTests {

    private func container(_ name: String, project: String? = nil, workingDir: String? = nil,
                           cluster: String? = nil, ryuk: Bool = false,
                           cpu: Double? = nil, rss: UInt64? = nil) -> ContainerInfo {
        var labels: [String: String] = [:]
        if let project { labels["com.docker.compose.project"] = project }
        if let workingDir { labels["com.docker.compose.project.working_dir"] = workingDir }
        if let cluster { labels["org.testcontainers.session-id"] = cluster }
        if ryuk { labels["org.testcontainers.ryuk"] = "true"; labels["org.testcontainers"] = "true" }
        return ContainerInfo(id: "id-" + name, name: name, image: "postgres:17",
                             labels: labels, cpuPercent: cpu, rssBytes: rss)
    }

    private let worktree = "/Users/USER/git_repositories/tradebot/.claude/worktrees/device-identify-2186f8"

    private func roster(_ sessions: [SessionInfo] = []) -> [SessionInfo] { sessions }

    private func session(_ pid: Int32, _ cwd: String, uuid: String) -> SessionInfo {
        SessionInfo(pid: pid, cwd: cwd, sessionID: uuid, startedAt: Date())
    }

    @Test("A compose stack is one group, not three rows")
    func composeStackIsOneGroup() {
        let groups = AttributionEngine.containerGroups(
            containers: [container("tb-web-1", project: "tb-replay", workingDir: worktree),
                         container("tb-server-1", project: "tb-replay", workingDir: worktree),
                         container("tb-postgres-1", project: "tb-replay", workingDir: worktree)],
            sessions: roster())
        #expect(groups.count == 1)
        #expect(groups.first?.project == "tb-replay")
        #expect(groups.first?.containers.count == 3)
    }

    @Test("A stack in a live session's worktree is labelled with that session")
    func stackTiedToLiveSession() {
        let groups = AttributionEngine.containerGroups(
            containers: [container("tb-web-1", project: "tb-replay", workingDir: worktree)],
            sessions: [session(100, worktree, uuid: "uuid-a")])
        #expect(groups.first?.key == .session(uuid: "uuid-a"))
        #expect(groups.first?.label == "tradebot::device-identify")
    }

    @Test("A stack whose session is gone is labelled as the orphan it is")
    func stackTiedToOrphan() {
        // The 47-hour Postgres nobody remembers starting, and now you can see which
        // worktree it came from.
        let groups = AttributionEngine.containerGroups(
            containers: [container("tb-postgres-1", project: "tb-replay", workingDir: worktree)],
            sessions: roster())
        #expect(groups.first?.key == .orphan(repo: "tradebot", worktree: "device-identify-2186f8"))
        #expect(groups.first?.label == "tradebot::device-identify")
    }

    @Test("Separate projects stay separate even in the same worktree")
    func separateProjects() {
        let groups = AttributionEngine.containerGroups(
            containers: [container("a-db-1", project: "stack-a", workingDir: worktree),
                         container("b-db-1", project: "stack-b", workingDir: worktree)],
            sessions: roster())
        #expect(Set(groups.map(\.project)) == ["stack-a", "stack-b"])
    }

    @Test("A testcontainers cluster is one group including its reaper")
    func testcontainersCluster() {
        let groups = AttributionEngine.containerGroups(
            containers: [container("strange_borg", cluster: "30ec6daa"),
                         container("testcontainers-ryuk-30ec6daa", ryuk: true)],
            sessions: roster())
        #expect(groups.count == 1)
        #expect(groups.first?.containers.count == 2)
        #expect(groups.first?.key == .unattributed)
        #expect(groups.first?.project.contains("30ec6daa") == true)
    }

    @Test("A container started by hand is its own group and stays unattributed")
    func bareContainer() {
        let groups = AttributionEngine.containerGroups(
            containers: [container("sp-chatroom-pg")], sessions: roster())
        #expect(groups.count == 1)
        #expect(groups.first?.project == "sp-chatroom-pg")
        #expect(groups.first?.key == .unattributed)
    }

    @Test("Figures are summed when docker answered for every container")
    func summedFigures() {
        let groups = AttributionEngine.containerGroups(
            containers: [container("a", project: "p", workingDir: worktree, cpu: 1.5, rss: 100),
                         container("b", project: "p", workingDir: worktree, cpu: 2.5, rss: 200)],
            sessions: roster())
        #expect(groups.first?.cpuPercent == 4.0)
        #expect(groups.first?.rssBytes == 300)
    }

    @Test("One unknown container makes the group's figure unknown, not smaller")
    func partialFiguresAreUnknown() {
        // `docker stats` returned dashes for every column during the reference capture.
        // Summing the containers that answered would look complete and be wrong.
        let groups = AttributionEngine.containerGroups(
            containers: [container("a", project: "p", workingDir: worktree, cpu: 1.5, rss: 100),
                         container("b", project: "p", workingDir: worktree)],
            sessions: roster())
        #expect(groups.first?.cpuPercent == nil)
        #expect(groups.first?.rssBytes == nil)
    }

    @Test("Groups come back heaviest first")
    func orderedByWeight() {
        let groups = AttributionEngine.containerGroups(
            containers: [container("small", project: "small", workingDir: worktree,
                                   cpu: 1, rss: 100),
                         container("big", project: "big", workingDir: worktree,
                                   cpu: 90, rss: 900)],
            sessions: roster())
        #expect(groups.map(\.project) == ["big", "small"])
    }

    @Test("Nothing running yields nothing, rather than an empty heading")
    func noContainers() {
        #expect(AttributionEngine.containerGroups(containers: [], sessions: roster()).isEmpty)
    }

    @Test("Every container in the reference capture lands in exactly one group")
    func fixtureCoverage() throws {
        let containers = try Fixture.containers()
        let groups = AttributionEngine.containerGroups(
            containers: containers, sessions: try Fixture.sessions())
        let placed = groups.flatMap { $0.containers.map(\.id) }
        #expect(placed.count == 13)
        #expect(Set(placed).count == 13)
        // Seven compose containers across their projects, three testcontainers clusters,
        // and the one bare `docker run`.
        #expect(groups.contains { $0.project.contains("30ec6daa") })
        #expect(groups.contains { $0.project == "sp-chatroom-pg" })
    }
}
