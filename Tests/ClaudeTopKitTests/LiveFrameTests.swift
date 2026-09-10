import Testing
import Foundation
@testable import ClaudeTopKit

/// The full-screen frame.
///
/// A live view has a fixed budget: whatever the terminal is. Anything that overflows it
/// scrolls, and a view that scrolls while it redraws is unreadable. So the frame is built
/// to a width and a height and is tested against both.
@Suite("Live frame")
struct LiveFrameTests {

    private func machine(load: Double = 43.1) -> MachineInfo {
        MachineInfo(cpuCount: 10, memTotalBytes: 17_179_869_184,
                    memUsedBytes: 12_884_901_888, loadAverage1: load,
                    capturedAt: Date(timeIntervalSince1970: 1_757_500_000),
                    homeDirectory: "/Users/USER", processCount: 700)
    }

    private func group(_ key: AttributionKey, _ label: String, cpu: Double?,
                       rss: UInt64 = 294_649_856, procs: Int = 7, containers: Int = 0,
                       age: TimeInterval? = nil) -> AttributionGroup {
        AttributionGroup(
            key: key, label: label, tier: .envStamp, cpuPercent: cpu, rssBytes: rss,
            pids: (0..<procs).map { Int32(100 + $0) },
            containerIDs: (0..<containers).map { "c\($0)" },
            oldestProcessStartedAt: age.map { Date(timeIntervalSince1970: 1_757_500_000 - $0) })
    }

    private func status(cost: Double? = 1.5,
                        source: Roster.Source = .live) -> LiveViewStatus {
        LiveViewStatus(refreshInterval: 5, ownCPUPercent: cost, ownRSSBytes: 12_582_912,
                       rosterSource: source)
    }

    private func frame(_ groups: [AttributionGroup], width: Int = 100, height: Int = 40,
                       status s: LiveViewStatus? = nil, load: Double = 43.1,
                       containers: [ContainerGroup] = []) -> String {
        Renderer.liveFrame(Snapshot(machine: machine(load: load), groups: groups,
                                    containerGroups: containers),
                           width: width, height: height, status: s ?? status())
    }

    private func containerGroup(_ project: String, label: String, key: AttributionKey,
                                count: Int = 3, cpu: Double? = 4, rss: UInt64? = 100_000_000)
        -> ContainerGroup {
        ContainerGroup(
            project: project, key: key, label: label,
            containers: (0..<count).map {
                // A real Compose stack carries the working_dir label, which is what makes
                // a group stoppable at all.
                ContainerInfo(id: "\(project)-\($0)", name: "\(project)-\($0)",
                              image: "postgres:17",
                              labels: ["com.docker.compose.project.working_dir":
                                        "/Users/USER/git_repositories/r/.claude/worktrees/w-123456"],
                              cpuPercent: nil, rssBytes: nil)
            },
            cpuPercent: cpu, rssBytes: rss)
    }

    @Test("No line is wider than the terminal")
    func fitsWidth() {
        // A line that wraps pushes everything below it down by one, and the next redraw
        // paints over the wrong rows.
        let lines = frame([
            group(.session(uuid: "a"),
                  "bet-placing-bot-v2::settings-tab-reorganization-and-cleanup", cpu: 279),
            group(.orphan(repo: "miinto-simple-dynamic-pricing",
                          worktree: "revenue-share-page-improvements-431cbc"),
                  "miinto-simple-dynamic-pricing::revenue-share-page-improvements",
                  cpu: 1, age: 86400),
        ], width: 60).split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            #expect(line.count <= 60, "line of \(line.count) chars: \(line)")
        }
    }

    @Test("The frame never exceeds the terminal height")
    func fitsHeight() {
        let many = (0..<60).map { group(.session(uuid: "s\($0)"), "repo::worktree-\($0)",
                                        cpu: Double(60 - $0)) }
        let lines = frame(many, height: 24).split(separator: "\n",
                                                  omittingEmptySubsequences: false)
        #expect(lines.count <= 24, "frame was \(lines.count) lines for a 24 line terminal")
    }

    @Test("When rows are dropped it says how many")
    func saysWhatItDropped() {
        // Silently showing the top eight of forty is how someone concludes the machine is
        // fine while the thing eating it is on the row below the fold.
        let many = (0..<40).map { group(.session(uuid: "s\($0)"), "repo::w\($0)",
                                        cpu: Double(40 - $0)) }
        #expect(frame(many, height: 20).contains("more"))
    }

    @Test("Orphans keep their rows when sessions would fill the screen")
    func orphansAreNotCrowdedOut() {
        // Observed at load 91 with 21 sessions: the orphan block was squeezed to two rows
        // and "and 2 more". Sessions are the headline, but orphans are the part you can
        // act on without costing anybody their work, so they get room first.
        let many = (0..<21).map { group(.session(uuid: "s\($0)"), "repo::session-\($0)",
                                        cpu: Double(60 - $0)) }
        let orphans = (0..<4).map { group(.orphan(repo: "r", worktree: "w\($0)"),
                                          "r::orphan-\($0)", cpu: 1, age: 86400) }
        let text = frame(many + orphans, height: 30)
        for index in 0..<4 {
            #expect(text.contains("r::orphan-\(index)"), "orphan \(index) was crowded out")
        }
    }

    @Test("A session with no worktree shows the prompt that identifies it")
    func promptShowsInTheLiveView() {
        // The static table already did this. The live view was reading the raw label, so
        // every home-directory session rendered as a bare `~`.
        let withPrompt = AttributionGroup(
            key: .session(uuid: "a"), label: "~", tier: .envStamp, cpuPercent: 12,
            rssBytes: 1024, pids: [1], containerIDs: [],
            promptPreview: "prune the build cache too")
        #expect(frame([withPrompt]).contains("prune the build cache"))
    }

    @Test("Docker is broken out by the project that brought the containers up")
    func dockerByProject() {
        // A single Docker row is consistently the largest consumer on this machine and
        // says nothing about which of eleven containers is responsible.
        let text = frame([], containers: [
            containerGroup("bpb-replay", label: "tradebot::device-identify",
                           key: .session(uuid: "a")),
            containerGroup("feed-stack", label: "feed-service::ui-improvements",
                           key: .orphan(repo: "feed-service", worktree: "ui-improvements-053b29")),
        ])
        #expect(text.contains("bpb-replay"))
        #expect(text.contains("tradebot::device-identify"))
        #expect(text.contains("feed-stack"))
    }

    @Test("Container CPU is labelled as the VM's, not this machine's")
    func dockerCPUIsQualified() {
        // Docker reports a share of the virtual machine's CPUs. On this machine the
        // containers totalled 0.4% while the VM cost 149% on the host, so presenting the
        // two in one column would invite exactly the wrong conclusion.
        let text = frame([], containers: [
            containerGroup("p", label: "r::w", key: .session(uuid: "a")),
        ])
        #expect(text.lowercased().contains("vm"))
    }

    @Test("A stack whose session is gone is marked as one you can stop")
    func stoppableStacksAreMarked() {
        // Shutting down a stack a dead worktree left behind is the cheapest resource you
        // can get back: nobody is using it and nothing else has to change.
        let text = frame([], containers: [
            containerGroup("live-stack", label: "r::live", key: .session(uuid: "a"),
                           rss: 200_000_000),
            containerGroup("dead-stack", label: "r::dead",
                           key: .orphan(repo: "r", worktree: "dead-123456"),
                           count: 2, rss: 300_000_000),
        ])
        #expect(text.contains("can be stopped"))
        #expect(text.contains("286M") || text.contains("300M") || text.contains("2 containers"))
    }

    @Test("A stack belonging to a live session is never offered")
    func liveStacksAreNotOffered() {
        // Stopping the database the session in front of you is talking to is the same
        // mistake as reaping its processes.
        let text = frame([], containers: [
            containerGroup("live-stack", label: "r::live", key: .session(uuid: "a")),
        ])
        #expect(!text.contains("can be stopped"))
    }

    @Test("A testcontainers cluster is never offered, however abandoned it looks")
    func testcontainersNeverOffered() {
        let text = frame([], containers: [
            ContainerGroup(project: "testcontainers 30ec6daa", key: .unattributed,
                           label: "", containers: [
                               ContainerInfo(id: "a", name: "strange_borg", image: "pg",
                                             labels: ["org.testcontainers": "true"],
                                             cpuPercent: 0, rssBytes: 50_000_000)],
                           cpuPercent: 0, rssBytes: 50_000_000),
        ])
        #expect(!text.contains("can be stopped"))
    }

    @Test("No containers means no Docker section")
    func noDockerSection() {
        #expect(!frame([group(.session(uuid: "a"), "r::w", cpu: 5)]).contains("DOCKER"))
    }

    @Test("A container group whose stats are unknown shows unknown")
    func unknownContainerStats() {
        let text = frame([], containers: [
            containerGroup("p", label: "r::w", key: .unattributed, cpu: nil, rss: nil),
        ])
        #expect(text.contains("?"))
    }

    @Test("A heavy session says what it is made of")
    func heavySessionBreakdown() {
        // The line the original design mocked up, and the difference between knowing a
        // session is heavy and knowing what to stop.
        let heavy = AttributionGroup(
            key: .session(uuid: "a"), label: "reader-app::terms-page", tier: .envStamp,
            cpuPercent: 291, rssBytes: 294_649_856,
            pids: Array(Int32(100)...Int32(108)), containerIDs: [],
            breakdown: [ProcessKind(name: "vitest", count: 9, cpuPercent: 287,
                                    rssBytes: 200_000_000, pids: [])])
        let text = frame([heavy])
        #expect(text.contains("9x vitest"))
        #expect(text.contains("287%"))
    }

    @Test("A session that is not busy is not taken apart")
    func quietSessionIsNotExpanded() {
        // Every group expanded is a screen of noise. Half a core is the threshold.
        let quiet = AttributionGroup(
            key: .session(uuid: "a"), label: "r::w", tier: .envStamp, cpuPercent: 4,
            rssBytes: 1024, pids: [1, 2], containerIDs: [],
            breakdown: [ProcessKind(name: "vitest", count: 2, cpuPercent: 4,
                                    rssBytes: 1024, pids: [])])
        #expect(!frame([quiet]).contains("vitest"))
    }

    @Test("A group running one of everything gets no breakdown")
    func nothingToSayIsNotSaid() {
        let varied = AttributionGroup(
            key: .session(uuid: "a"), label: "r::w", tier: .envStamp, cpuPercent: 200,
            rssBytes: 1024, pids: [1], containerIDs: [],
            breakdown: [ProcessKind(name: "node", count: 1, cpuPercent: 200,
                                    rssBytes: 1024, pids: [1])])
        #expect(!frame([varied]).contains("└"))
    }

    @Test("The header carries load, cores and oversubscription")
    func header() {
        let text = frame([])
        #expect(text.contains("43.1"))
        #expect(text.contains("10 cores"))
        #expect(text.contains("4.3x"))
    }

    @Test("The orphan summary is what would be reclaimed, in resources")
    func orphanSummary() {
        // Chosen by looking at a rendered dashboard: processes and memory and containers,
        // not a CPU percentage, because an idle orphan reads as 0% and still holds a
        // Postgres.
        let text = frame([
            group(.orphan(repo: "r", worktree: "w-1"), "r::w1", cpu: 0,
                  rss: 100_000_000, procs: 18, containers: 2, age: 86400),
            group(.orphan(repo: "r", worktree: "w-2"), "r::w2", cpu: 0,
                  rss: 83_000_000, procs: 23, containers: 1, age: 68400),
        ])
        #expect(text.contains("41 processes"))
        #expect(text.contains("3 containers"))
        #expect(text.contains("174M") || text.contains("175M"))
        #expect(text.contains("reclaim"))
    }

    @Test("With no orphans it does not offer to reclaim anything")
    func noOrphansNoOffer() {
        #expect(!frame([group(.session(uuid: "a"), "r::w", cpu: 10)]).contains("reclaim"))
    }

    @Test("The view reports its own cost")
    func ownCost() {
        // The design notes argued against a live view because at load 55 the thing you
        // open to diagnose the problem should not be competing for the cores you are
        // freeing. Showing what it costs is how that argument gets settled by measurement
        // rather than by assertion.
        let text = frame([], status: status(cost: 2.4))
        #expect(text.contains("claude-top"))
        #expect(text.contains("2%") || text.contains("2.4%"))
    }

    @Test("A roster that is not fresh is called out")
    func staleRosterIsVisible() {
        // Otherwise a cached roster silently mislabels live sessions as orphaned, which
        // is the failure this whole area exists to prevent.
        let text = frame([], status: status(source: .cached(age: 120)))
        #expect(text.lowercased().contains("cached") || text.lowercased().contains("stale"))
    }

    @Test("Without a roster, nothing is offered for reclaiming")
    func noReclaimOfferWithoutARoster() {
        // The dangerous display. With no roster every stamped process resolves to an
        // orphan, so the sessions you are working in right now appear under a heading
        // offering to free them. The rows still show, because the resources are real,
        // but nothing calls them abandoned and nothing invites stopping them.
        let text = frame([group(.orphan(repo: "r", worktree: "w-1"), "r::w1", cpu: 5,
                                procs: 18, age: 3600)],
                         status: status(source: .unavailable))
        #expect(!text.contains("reclaim"))
        #expect(!text.contains("--reap"))
        #expect(text.contains("r::w1"), "the resources are real and still worth showing")
    }

    @Test("Without a roster, orphans are not called orphans")
    func orphansAreNotNamedWithoutARoster() {
        let text = frame([group(.orphan(repo: "r", worktree: "w-1"), "r::w1", cpu: 5)],
                         status: status(source: .unavailable))
        #expect(!text.contains("ORPHANED"))
        #expect(text.uppercased().contains("UNIDENTIFIED"))
    }

    @Test("A live roster says nothing about itself")
    func liveRosterIsQuiet() {
        let text = frame([], status: status(source: .live))
        #expect(!text.lowercased().contains("cached"))
    }

    @Test("An unusable interval shows unknown rather than zero")
    func unknownCPU() {
        #expect(frame([group(.session(uuid: "a"), "r::w", cpu: nil)]).contains("?"))
    }

    @Test("The starting frame shows load immediately and fits the terminal")
    func collectingFrame() {
        let text = Renderer.liveFrameCollecting(machine(), width: 80, height: 24)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count <= 24)
        #expect(lines.allSatisfy { $0.count <= 80 })
        #expect(text.contains("43.1"), "load is free to read and must not wait for a sample")
        #expect(text.contains("4.3x"))
    }

    @Test("A narrow terminal still produces something legible")
    func veryNarrow() {
        let lines = frame([group(.session(uuid: "a"), "some-repo::some-worktree", cpu: 91)],
                          width: 40)
            .split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.allSatisfy { $0.count <= 40 })
        #expect(lines.contains { $0.contains("43.1") })
    }
}
