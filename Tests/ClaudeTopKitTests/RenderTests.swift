import Testing
import Foundation
@testable import ClaudeTopKit

/// What the terminal shows and what `--json` promises.
///
/// The JSON is a contract: the statusline, the hooks and any agent reading this all
/// consume it, so it is versioned and its field names do not move.
@Suite("Rendering")
struct RenderTests {

    private func machine(load: Double = 55.6, cores: Int = 10) -> MachineInfo {
        MachineInfo(cpuCount: cores, memTotalBytes: 17_179_869_184,
                    memUsedBytes: 10_737_418_240, loadAverage1: load,
                    capturedAt: Date(timeIntervalSince1970: 1_757_500_000),
                    homeDirectory: "/Users/USER", processCount: 700)
    }

    private func group(_ key: AttributionKey, _ label: String, cpu: Double?,
                       rss: UInt64 = 294_649_856, procs: Int = 7, containers: Int = 0,
                       age: TimeInterval? = nil) -> AttributionGroup {
        AttributionGroup(
            key: key, label: label, tier: .envStamp, cpuPercent: cpu, rssBytes: rss,
            pids: (0..<procs).map { Int32(100 + $0) },
            containerIDs: (0..<containers).map { "container-\($0)" },
            oldestProcessStartedAt: age.map { Date(timeIntervalSince1970: 1_757_500_000 - $0) })
    }

    private func snapshot(_ groups: [AttributionGroup], machine m: MachineInfo? = nil) -> Snapshot {
        Snapshot(machine: m ?? machine(), groups: groups)
    }

    // MARK: - text

    @Test("The headline is CPU, in the units Activity Monitor uses")
    func header() {
        // Load average is not a headline. It counts threads waiting rather than work
        // being done, nothing else on a Mac shows it, and beside a row reading 115% it
        // invites comparing two different denominators.
        let text = Renderer.text(Snapshot(machine: machine(), groups: [],
                                          systemCPU: SystemCPU(userPercent: 20,
                                                               systemPercent: 11)))
        #expect(text.contains("CPU 31%"))
        #expect(text.contains("3.1 of 10 cores busy"))
        #expect(text.contains("10.0 / 16.0 GB"))
    }

    @Test("A queue longer than the core count is explained in threads")
    func queueIsExplained() {
        // "load 55.6" means nothing to most people. "56 threads queued for 10 cores"
        // means exactly one thing.
        let text = Renderer.text(Snapshot(machine: machine(load: 55.6), groups: [],
                                          systemCPU: SystemCPU(userPercent: 20,
                                                               systemPercent: 11)))
        #expect(text.contains("56 threads queued"))
        #expect(text.contains("10 cores"))
    }

    @Test("A machine keeping up says nothing about queues")
    func healthyHeader() {
        let text = Renderer.text(Snapshot(machine: machine(load: 4.2), groups: [],
                                          systemCPU: SystemCPU(userPercent: 5,
                                                               systemPercent: 2)))
        #expect(!text.contains("queued"))
        #expect(text.contains("CPU 7%"))
    }

    private func gapSnapshot() -> Snapshot {
        let seen = AttributionGroup(key: .system(family: .other), label: "Other processes",
                                    tier: .unresolved, cpuPercent: 172, rssBytes: 0,
                                    pids: (0..<400).map { Int32(100 + $0) }, containerIDs: [])
        return Snapshot(
            machine: MachineInfo(cpuCount: 10, memTotalBytes: 17_179_869_184,
                                 memUsedBytes: 10_737_418_240, loadAverage1: 10,
                                 capturedAt: Date(), homeDirectory: "/Users/USER",
                                 processCount: 612),
            groups: [seen],
            systemCPU: SystemCPU(userPercent: 20.7, systemPercent: 10.7))
    }

    @Test("The share it cannot see is stated, not left as a discrepancy")
    func statesTheGap() {
        // The reason the numbers read as untrustworthy: the rows below cannot add up to
        // the headline, and a tool that shows both without saying so reads as broken.
        let text = Renderer.text(gapSnapshot())
        #expect(text.contains("1.7 of those cores"))
        #expect(text.contains("212 processes"))
    }

    /// The gap is a residual: machine total minus what this could measure. It holds the
    /// kernel's own time, other users' processes, and whatever the sampling window
    /// missed, and an unprivileged tool has no way to tell those apart. Naming it after
    /// one of them was wrong by a factor of four against `top` on the machine this was
    /// written on, and swung between 0.8 and 4.5 cores across three consecutive runs.
    @Test("The gap is called unaccounted, never blamed on other users' processes alone")
    func gapIsNotBlamedOnOneCause() {
        let text = Renderer.text(gapSnapshot())
        #expect(text.contains("unaccounted"))
        #expect(text.contains("kernel"))
        // The old wording. It asserted the whole residual sat in other users' processes.
        #expect(!text.contains("are in 212 processes"))
    }

    @Test("The gap is stated even when it is small")
    func gapStatedWhenSmall() {
        // It used to appear only above 20%, so on a quiet machine the rows silently
        // stopped adding up with nothing on screen to say why.
        let quiet = AttributionGroup(key: .system(family: .other), label: "Other processes",
                                     tier: .unresolved, cpuPercent: 48, rssBytes: 0,
                                     pids: [1, 2], containerIDs: [])
        let text = Renderer.text(Snapshot(machine: machine(load: 1), groups: [quiet],
                                          systemCPU: SystemCPU(userPercent: 4,
                                                               systemPercent: 1)))
        #expect(text.contains("unaccounted"))
    }

    @Test("The unit the rows are in is stated once, in Activity Monitor's terms")
    func rowUnitIsStated() {
        // The headline is a percentage of the whole machine and every row is a
        // percentage of one core. Both are what Activity Monitor shows, but it never
        // asks anyone to read them side by side. This does, so it says which is which.
        let text = Renderer.text(gapSnapshot())
        #expect(text.contains("100% is one core"))
    }

    @Test("With no reading of the machine the headline says unknown, not zero")
    func noSystemReading() {
        #expect(Renderer.text(snapshot([])).contains("CPU —"))
    }

    @Test("Sessions, orphans and everything else each get their own block")
    func blocks() {
        let text = Renderer.text(snapshot([
            group(.session(uuid: "a"), "reader-app::terms-page", cpu: 291),
            group(.orphan(repo: "feed-service", worktree: "ui-improvements-053b29"),
                  "feed-service::ui-improvements", cpu: 3, age: 17 * 3600),
            group(.system(family: .docker), "Docker", cpu: 271, containers: 13),
        ]))
        #expect(text.contains("CLAUDE SESSIONS"))
        #expect(text.contains("ORPHANED"))
        #expect(text.contains("EVERYTHING ELSE"))
        #expect(text.contains("reader-app::terms-page"))
        #expect(text.contains("feed-service::ui-improvements"))
    }

    @Test("An empty block is left out rather than printed empty")
    func emptyBlocksOmitted() {
        let text = Renderer.text(snapshot([group(.session(uuid: "a"), "a", cpu: 1)]))
        #expect(text.contains("CLAUDE SESSIONS"))
        #expect(!text.contains("ORPHANED"))
    }

    @Test("Nothing running at all says so instead of printing bare headings")
    func nothingToShow() {
        let text = Renderer.text(snapshot([]))
        #expect(text.contains("nothing attributed"))
    }

    // MARK: - what a row costs, including in Docker

    private func orphanWithContainer() -> Snapshot {
        // The shape that made the whole panel read as free: no surviving host process,
        // so the CPU column is a truthful zero, while a compose project left behind by
        // the same worktree is still burning a core inside the VM.
        let idle = AttributionGroup(
            key: .orphan(repo: "enumstudio", worktree: "i-1338"),
            label: "enumstudio::enumstudio-i-1338", tier: .containerLabel,
            cpuPercent: 0, rssBytes: 0,
            containerCPUPercent: 24, containerRSSBytes: 9_437_184,
            pids: [], containerIDs: ["c1"])
        return snapshot([idle])
    }

    @Test("An orphan whose containers are working does not read as costing nothing")
    func orphanContainerCPUIsShown() {
        let text = Renderer.text(orphanWithContainer())
        #expect(text.contains("24%"))
    }

    @Test("Container CPU has its own column, because it is not host CPU")
    func containerCPUHasItsOwnColumn() {
        // It is measured inside the VM against the VM's own clock. Adding it to a host
        // percentage would produce a number that is not a share of anything.
        let text = Renderer.text(orphanWithContainer())
        #expect(text.contains("DOCKER CPU"))
    }

    @Test("A group with no containers leaves the container column empty, not zero")
    func noContainersReadsAsNothing() {
        // Zero would say docker was asked and answered none. Nothing was asked.
        let text = Renderer.text(snapshot([group(.session(uuid: "a"), "r::w", cpu: 12)]))
        let row = text.split(separator: "\n").first { $0.contains("r::w") } ?? ""
        #expect(row.contains("—"))
    }

    @Test("Every section ends in a total, so the columns can be read as columns")
    func sectionsHaveTotals() {
        let text = Renderer.text(snapshot([
            group(.session(uuid: "a"), "reader-app::terms-page", cpu: 291, procs: 4),
            group(.session(uuid: "b"), "reader-app::search", cpu: 9, procs: 2),
            group(.orphan(repo: "feed", worktree: "ui-053b29"), "feed::ui", cpu: 3, procs: 1),
            group(.system(family: .docker), "Docker", cpu: 271, containers: 13),
        ]))
        #expect(text.contains("TOTAL"))
        // 291 + 9, the two sessions, and nothing from the orphan or the docker bucket.
        #expect(text.contains("300%"))
    }

    @Test("The orphan total carries the container cost the individual rows carry")
    func orphanTotalIncludesContainers() {
        let text = Renderer.text(orphanWithContainer())
        let total = text.split(separator: "\n").first { $0.contains("TOTAL") } ?? ""
        #expect(total.contains("24%"))
    }

    @Test("Docker's host row and the container list are said not to be additive")
    func dockerRelationshipIsStated() {
        // Two measurements of overlapping work under one word. The host row is the VM
        // process; the container figures are measured inside that VM, so they are a
        // breakdown of part of it rather than anything to add to it.
        let text = Renderer.text(Snapshot(
            machine: machine(),
            groups: [group(.system(family: .docker), "Docker", cpu: 271, containers: 2)],
            containerGroups: [ContainerGroup(
                project: "proj", key: .session(uuid: "a"), label: "r::w",
                containers: [ContainerInfo(id: "c1", name: "pg", image: "postgres",
                                           labels: [:], cpuPercent: 14,
                                           rssBytes: 33_554_432)],
                cpuPercent: 14, rssBytes: 33_554_432)]))
        #expect(text.contains("already"))
        #expect(text.contains("not extra to it"))
    }

    /// Found live: at load 38 on the machine this was written on, `docker ps` took 48
    /// seconds to answer. The collector times out at 3, correctly, and the screen then
    /// said every session had 0 containers while 26 were running. An empty listing means
    /// "docker did not answer" and "there are none" at once, and printing the first as a
    /// zero is the same defect as naming the unaccounted cores after one of their causes.
    @Test("Docker not answering reads as unknown, never as no containers")
    func dockerSilenceIsNotZero() {
        let text = Renderer.text(Snapshot(
            machine: machine(),
            groups: [group(.session(uuid: "a"), "reader-app::terms", cpu: 12)],
            dockerAnswered: false))
        let row = text.split(separator: "\n").first { $0.contains("reader-app::terms") } ?? ""
        #expect(row.contains("?"))
        #expect(!row.contains("0"))
        #expect(text.contains("docker did not answer"))
    }

    @Test("Docker answering with nothing still reads as none")
    func dockerAnsweredNone() {
        let text = Renderer.text(snapshot([group(.session(uuid: "a"), "r::w", cpu: 12)]))
        #expect(!text.contains("docker did not answer"))
    }

    @Test("An orphan shows how long it has been running unattended")
    func orphanAge() {
        // The number that decides whether it is worth stopping.
        let text = Renderer.text(snapshot([
            group(.orphan(repo: "platform", worktree: "qa-testing-a538f6"),
                  "platform::qa-testing", cpu: 0, age: 21 * 3600),
        ]))
        #expect(text.contains("21h"))
    }

    @Test("The orphan age column is labelled like every other column")
    func orphanAgeHasAHeading() {
        // It is the figure that decides whether something is worth stopping, and it sat
        // past the last heading with nothing saying what it was.
        let text = Renderer.text(snapshot([
            group(.orphan(repo: "platform", worktree: "qa-a538f6"), "platform::qa",
                  cpu: 0, age: 21 * 3600),
        ]))
        let heading = text.split(separator: "\n").first { $0.hasPrefix("ORPHANED") } ?? ""
        #expect(heading.contains("AGE"))
    }

    @Test("Unknown CPU prints as unknown, never as zero")
    func unknownCPU() {
        // Zero would rank a busy session at the bottom of the list. Asserted against the
        // row rather than the whole page, which now carries a legend reading "100% is
        // one core".
        let text = Renderer.text(snapshot([group(.session(uuid: "a"), "a", cpu: nil)]))
        let row = text.split(separator: "\n").first { $0.hasPrefix("  a ") } ?? ""
        #expect(row.contains("?"))
        #expect(!row.contains("0%"))
    }

    @Test("The output says how much of the machine it could not inspect")
    func unreadableFootnote() {
        let text = Renderer.text(snapshot([group(.session(uuid: "a"), "a", cpu: 1, procs: 3)]))
        #expect(text.contains("697"), "should account for the processes it could not read")
    }

    @Test("Memory is scaled so the column stays readable")
    func memoryFormatting() {
        #expect(Renderer.formatBytes(294_649_856) == "281M")
        #expect(Renderer.formatBytes(2_469_606_195) == "2.3G")
        #expect(Renderer.formatBytes(31_457_280) == "30M")
        #expect(Renderer.formatBytes(512) == "0M")
    }

    @Test("Durations are scaled the way a person reads them")
    func durationFormatting() {
        #expect(Renderer.formatDuration(45) == "45s")
        #expect(Renderer.formatDuration(3600) == "1h")
        #expect(Renderer.formatDuration(21 * 3600) == "21h")
        #expect(Renderer.formatDuration(50 * 3600) == "2d")
    }

    // MARK: - json

    @Test("The JSON carries a version, so a consumer can tell what it is reading")
    func jsonVersion() throws {
        let parsed = try #require(try JSONSerialization.jsonObject(
            with: Data(Renderer.json(snapshot([])).utf8)) as? [String: Any])
        #expect(parsed["version"] as? Int == 1)
    }

    @Test("The JSON describes the machine including what it could not see")
    func jsonMachine() throws {
        let parsed = try #require(try JSONSerialization.jsonObject(
            with: Data(Renderer.json(snapshot([])).utf8)) as? [String: Any])
        let m = try #require(parsed["machine"] as? [String: Any])
        #expect(m["cpuCount"] as? Int == 10)
        #expect(m["loadAverage1"] as? Double == 55.6)
        #expect(m["processCount"] as? Int == 700)
        #expect(m["unreadableProcessCount"] as? Int == 700)
    }

    @Test("Each group says whether it can safely be stopped")
    func jsonReapability() throws {
        // The field an agent acts on. A system family or an unattributed container is
        // reported for honesty and is never something to stop.
        let json = Renderer.json(snapshot([
            group(.session(uuid: "a"), "a", cpu: 1),
            group(.orphan(repo: "r", worktree: "w-123456"), "r::w", cpu: 1),
            group(.system(family: .docker), "Docker", cpu: 1),
            group(.unattributed, "Unattributed", cpu: 1),
        ]))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                  as? [String: Any])
        let groups = try #require(parsed["groups"] as? [[String: Any]])
        #expect(groups.map { $0["reapable"] as? Bool } == [true, true, false, false])
        #expect(groups.map { $0["kind"] as? String }
                == ["session", "orphan", "system", "unattributed"])
    }

    @Test("Unknown CPU is null in the JSON, never zero")
    func jsonUnknownIsNull() throws {
        let json = Renderer.json(snapshot([group(.session(uuid: "a"), "a", cpu: nil)]))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                  as? [String: Any])
        let groups = try #require(parsed["groups"] as? [[String: Any]])
        #expect(groups[0]["cpuPercent"] is NSNull)
    }

    @Test("Keys and pids are present so a consumer can act without guessing")
    func jsonActionableFields() throws {
        let json = Renderer.json(snapshot([group(.session(uuid: "local_abc"), "a", cpu: 1, procs: 3)]))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                  as? [String: Any])
        let group = try #require((parsed["groups"] as? [[String: Any]])?.first)
        #expect(group["key"] as? String == "session:local_abc")
        #expect((group["pids"] as? [Int])?.count == 3)
        #expect(group["tier"] as? String == "envStamp")
    }

    @Test("The JSON is stable enough to diff between runs")
    func jsonDeterministic() {
        let s = snapshot([group(.session(uuid: "a"), "a", cpu: 1),
                          group(.system(family: .chrome), "Chrome", cpu: 2)])
        #expect(Renderer.json(s) == Renderer.json(s))
    }

    @Test("Docker projects reach the JSON with their own figures and a stoppable flag")
    func jsonDockerProjects() throws {
        // The field an agent acts on when it wants resources back without touching
        // anyone's running work.
        let stack = ContainerGroup(
            project: "feed-stack",
            key: .orphan(repo: "feed-service", worktree: "ui-improvements-053b29"),
            label: "feed-service::ui-improvements",
            containers: [ContainerInfo(id: "c1", name: "feed-postgres-1", image: "postgres:17",
                                       labels: ["com.docker.compose.project.working_dir":
                                                 "/Users/USER/git_repositories/f/.claude/worktrees/w-123456"],
                                       cpuPercent: 2, rssBytes: 50_000_000)],
            cpuPercent: 2, rssBytes: 50_000_000)

        let json = Renderer.json(Snapshot(machine: machine(), groups: [],
                                          containerGroups: [stack]))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                  as? [String: Any])
        let projects = try #require(parsed["dockerProjects"] as? [[String: Any]])
        #expect(projects.first?["project"] as? String == "feed-stack")
        #expect(projects.first?["stoppable"] as? Bool == true)
        #expect(projects.first?["vmRssBytes"] as? Int == 50_000_000)
        #expect((projects.first?["containerNames"] as? [String]) == ["feed-postgres-1"])
    }

    @Test("The VM figures are named apart from the host figures")
    func jsonKeepsVMFiguresDistinct() throws {
        // Docker reports a share of the virtual machine's CPUs. A consumer that added
        // them to a host percentage would be adding two different denominators.
        let json = Renderer.json(Snapshot(machine: machine(), groups: [], containerGroups: []))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                  as? [String: Any])
        #expect(parsed["dockerProjects"] as? [[String: Any]] != nil)
        #expect(!json.contains("\"cpuPercent\" : 0,"), "host and VM figures must stay named apart")
    }

    @Test("The JSON carries the headline figures, not just the rows")
    func jsonCarriesMachineTotals() {
        // Without these a hook reading --json can sum the rows but cannot say what share
        // of the machine that is, nor how much went unaccounted, so it cannot reproduce
        // the header or judge how far to trust its own total.
        let json = Renderer.json(gapSnapshot())
        let parsed = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let machine = parsed["machine"] as! [String: Any]
        #expect(machine["busyPercent"] as? Double != nil)
        #expect(abs((machine["busyCores"] as? Double ?? 0) - 3.14) < 0.01)
        #expect(abs((machine["unaccountedCores"] as? Double ?? 0) - 1.42) < 0.01)
    }

    // MARK: - statusline

    @Test("The statusline shows machine load and this session's own share, in one currency")
    func statusline() {
        // `load 55.6/10` counts threads against cores. Putting `291%` beside it asks a
        // prompt to carry two denominators with no room to say which is which, and 291
        // next to 10 reads as a machine on fire. The same figure in cores is directly
        // comparable to the number it sits next to.
        let line = Renderer.statusline(snapshot([
            group(.session(uuid: "mine"), "reader-app::terms-page", cpu: 291),
            group(.session(uuid: "other"), "other", cpu: 4),
        ]), sessionID: "mine")
        #expect(line.contains("55.6/10"))
        #expect(line.contains("2.9 cores"))
        #expect(!line.contains("291%"))
    }

    @Test("The statusline warns when the machine is oversubscribed")
    func statuslineWarns() {
        let busy = Renderer.statusline(snapshot([]), sessionID: nil)
        #expect(busy.contains("⚠"))

        let calm = Renderer.statusline(snapshot([], machine: machine(load: 4.2)), sessionID: nil)
        #expect(!calm.contains("⚠"))
    }

    @Test("A session with no attribution yet reports no share rather than a wrong one")
    func statuslineUnknownSession() {
        let line = Renderer.statusline(snapshot([]), sessionID: "not-here")
        #expect(!line.contains("self"))
    }
}
