import Foundation

/// The seam the whole test suite hangs off.
///
/// Pure function over listings, no I/O. Collectors (libproc, KERN_PROCARGS2, docker,
/// `claude agents --json`) live elsewhere and feed this. Every attribution rule is then
/// testable against `Tests/Fixtures/` without touching the live machine.
///
/// Not implemented yet. See docs/IMPLEMENTATION-PLAN.md phase 1.4, and write the failing
/// test before the code.
public enum AttributionEngine {

    /// Resolve every process and container to an `AttributionKey`.
    ///
    /// Cascade, first hit wins:
    ///   1. env stamp        — `CLAUDE_CODE_MESSAGING_SOCKET` names the spawning session
    ///   2. process tree     — ppid walk from a live session root
    ///   3. worktree path    — PWD, or vnode path, under `.claude/worktrees/`
    ///   4. container label  — compose `working_dir`, or testcontainers `session-id`
    ///
    /// A stamped process whose session PID is absent from `sessions` is an orphan, not a
    /// system process. That is the case that matters: on the reference fixture, five dead
    /// sessions still had children running, some for 22 hours.
    public static func attribute(
        processes: [ProcessSample],
        environments: [Int32: ProcessEnvironment],
        containers: [ContainerInfo],
        sessions: [SessionInfo],
        cpuPercents: [Int32: Double],
        machine: MachineInfo
    ) -> Snapshot {
        let byProcess = resolveProcesses(processes: processes, environments: environments,
                                         sessions: sessions)
        let byContainer = resolveContainers(containers: containers, sessions: sessions)

        let processByPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let containerByID = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var members: [AttributionKey: (pids: [Int32], containers: [String], tier: AttributionTier)] = [:]
        for (pid, placed) in byProcess {
            var entry = members[placed.key] ?? ([], [], .unresolved)
            entry.pids.append(pid)
            entry.tier = min(entry.tier, placed.tier)
            members[placed.key] = entry
        }
        for (id, placed) in byContainer {
            var entry = members[placed.key] ?? ([], [], .unresolved)
            entry.containers.append(id)
            entry.tier = min(entry.tier, placed.tier)
            members[placed.key] = entry
        }

        // An empty map means the interval was unusable, not that nothing ran. Zero would
        // rank a busy session at the bottom of the list, which is the worst possible
        // answer to give someone deciding what to stop.
        let intervalUsable = !cpuPercents.isEmpty

        let groups: [AttributionGroup] = members.map { key, entry in
            let pids = entry.pids.sorted()
            let containerIDs = entry.containers.sorted()

            let rss = pids.reduce(UInt64(0)) { $0 + (processByPID[$1]?.rssBytes ?? 0) }
            let cpu = intervalUsable
                ? pids.reduce(0.0) { $0 + (cpuPercents[$1] ?? 0) }
                : nil

            // Containers report unknown as a whole when docker could not answer, rather
            // than summing the ones that did into a figure that looks complete.
            let stats = containerIDs.compactMap { containerByID[$0] }
            let containerCPU = stats.allSatisfy { $0.cpuPercent != nil } && !stats.isEmpty
                ? stats.reduce(0.0) { $0 + ($1.cpuPercent ?? 0) }
                : nil
            let containerRSS = stats.allSatisfy { $0.rssBytes != nil } && !stats.isEmpty
                ? stats.reduce(UInt64(0)) { $0 + ($1.rssBytes ?? 0) }
                : nil

            return AttributionGroup(
                key: key,
                label: label(for: key, sessions: sessions, machine: machine),
                tier: entry.tier,
                cpuPercent: cpu, rssBytes: rss,
                containerCPUPercent: containerCPU, containerRSSBytes: containerRSS,
                pids: pids, containerIDs: containerIDs,
                oldestProcessStartedAt: pids.compactMap { processByPID[$0]?.startedAt }.min(),
                sessionPID: sessionPID(for: key, sessions: sessions),
                promptPreview: promptPreview(for: key, sessions: sessions))
        }

        return Snapshot(machine: machine,
                        groups: disambiguate(groups).sorted(by: ordered),
                        containerGroups: containerGroups(containers: containers,
                                                         sessions: sessions))
    }

    /// Sessions started from the same directory produce the same label, and several
    /// running from home all read as `~`. A row you cannot tell apart from three others
    /// is not something you can act on, so colliding labels get a short discriminator.
    private static func disambiguate(_ groups: [AttributionGroup]) -> [AttributionGroup] {
        // Counted on the label together with the prompt, because that pair is what the
        // terminal actually shows. Two home-directory sessions opened with different
        // sentences already read as different rows, and adding a hash to both would be
        // noise on top of an answer.
        func identity(_ group: AttributionGroup) -> String {
            group.label + (group.promptPreview ?? "")
        }
        let counts = groups.reduce(into: [String: Int]()) { $0[identity($1), default: 0] += 1 }
        guard counts.values.contains(where: { $0 > 1 }) else { return groups }

        return groups.map { group in
            guard counts[identity(group), default: 0] > 1 else { return group }
            let discriminator: String
            switch group.key {
            case .session(let uuid): discriminator = String(uuid.prefix(6))
            case .orphan(_, let worktree): discriminator = String(worktree.suffix(6))
            case .system, .unattributed: return group
            }
            return AttributionGroup(
                key: group.key, label: "\(group.label) (\(discriminator))", tier: group.tier,
                cpuPercent: group.cpuPercent, rssBytes: group.rssBytes,
                containerCPUPercent: group.containerCPUPercent,
                containerRSSBytes: group.containerRSSBytes,
                pids: group.pids, containerIDs: group.containerIDs,
                oldestProcessStartedAt: group.oldestProcessStartedAt,
                sessionPID: group.sessionPID, promptPreview: group.promptPreview)
        }
    }

    private static func sessionPID(for key: AttributionKey, sessions: [SessionInfo]) -> Int32? {
        guard case .session(let uuid) = key else { return nil }
        return sessions.first { $0.sessionID == uuid }?.pid
    }

    private static func promptPreview(for key: AttributionKey,
                                      sessions: [SessionInfo]) -> String? {
        guard case .session(let uuid) = key else { return nil }
        return sessions.first { $0.sessionID == uuid }?.promptPreview
    }

    /// Live sessions, then the leftovers of sessions that are gone, then everything else,
    /// each block heaviest first. The blocks answer "which of my sessions is this" before
    /// "what is using the most CPU", because the first question is the one a person opens
    /// this tool with.
    private static func ordered(_ a: AttributionGroup, _ b: AttributionGroup) -> Bool {
        func rank(_ key: AttributionKey) -> Int {
            switch key {
            case .session: return 0
            case .orphan: return 1
            case .system: return 2
            case .unattributed: return 3
            }
        }
        let (ra, rb) = (rank(a.key), rank(b.key))
        if ra != rb { return ra < rb }
        let (ca, cb) = (a.cpuPercent ?? -1, b.cpuPercent ?? -1)
        if ca != cb { return ca > cb }
        if a.rssBytes != b.rssBytes { return a.rssBytes > b.rssBytes }
        return a.label < b.label
    }

    /// Tiers 1 to 3 of the cascade, plus the tier-4 system fallback. One entry per input
    /// process, always: a process the engine cannot place is still reported, as
    /// `.system(.other)`, rather than dropped from the totals.
    public static func resolveProcesses(
        processes: [ProcessSample],
        environments: [Int32: ProcessEnvironment],
        sessions: [SessionInfo]
    ) -> [Int32: ProcessAttribution] {
        let liveByPID = Dictionary(sessions.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var liveByWorktree: [WorktreeID: SessionInfo] = [:]
        for s in sessions {
            if let id = worktreeID(forPath: s.cwd) { liveByWorktree[id] = s }
        }

        let orphanKeys = orphanKeysForDeadSessions(environments: environments, live: liveByPID)
        var out: [Int32: ProcessAttribution] = [:]
        out.reserveCapacity(processes.count)

        // Tier 1. The stamp is authoritative: it survives reparenting and it survives the
        // session dying, which is precisely when the other tiers stop being able to help.
        for proc in processes {
            guard let spawner = environments[proc.pid]?.spawningSessionPID else { continue }
            let key: AttributionKey = liveByPID[spawner]
                .map { .session(uuid: $0.sessionID) }
                ?? orphanKeys[spawner]
                ?? .orphan(repo: "", worktree: "session-\(spawner)")
            out[proc.pid] = ProcessAttribution(pid: proc.pid, key: key, tier: .envStamp)
        }

        // Tier 2. Walk to the nearest ancestor that is already placed, or that is a live
        // session root. This is what catches anything re-exec'd through a shim, which
        // loses the environment but keeps its parent.
        let parents = Dictionary(processes.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        for proc in processes where out[proc.pid] == nil {
            if let key = ancestorKey(of: proc.pid, parents: parents,
                                     placed: out, liveByPID: liveByPID) {
                out[proc.pid] = ProcessAttribution(pid: proc.pid, key: key, tier: .processTree)
            }
        }

        // Tier 3. Working directory. Catches the vite and tsx watchers that carry neither
        // a stamp nor a live ancestor but never left the worktree they were started in.
        for proc in processes where out[proc.pid] == nil {
            guard let pwd = environments[proc.pid]?.pwd,
                  let id = worktreeID(forPath: pwd) else { continue }
            let key: AttributionKey = liveByWorktree[id]
                .map { .session(uuid: $0.sessionID) }
                ?? .orphan(repo: id.repo, worktree: id.worktree)
            out[proc.pid] = ProcessAttribution(pid: proc.pid, key: key, tier: .worktreePath)
        }

        // Tier 4. Everything the cascade could not place is still reported, so the totals
        // add up and so the largest consumer on the machine cannot hide in a gap.
        for proc in processes where out[proc.pid] == nil {
            out[proc.pid] = ProcessAttribution(
                pid: proc.pid,
                key: .system(family: systemFamily(forCommand: proc.command)),
                tier: .unresolved)
        }

        return out
    }

    /// A worktree, identified the way both a live session and its leftovers see it.
    struct WorktreeID: Hashable {
        let repo: String
        let worktree: String
    }

    /// The full directory name is kept, hash suffix and all, so two worktrees that differ
    /// only by suffix never collide into one group. The suffix is dropped for display.
    static func worktreeID(forPath path: String) -> WorktreeID? {
        guard let marker = path.range(of: worktreeMarker),
              let repo = path[path.startIndex..<marker.lowerBound].split(separator: "/").last,
              let worktree = path[marker.upperBound...].split(separator: "/").first
        else { return nil }
        return WorktreeID(repo: String(repo), worktree: String(worktree))
    }

    /// One orphan key per dead session, chosen once so that every child of that session
    /// lands in the same group even if some of them have since moved elsewhere on disk.
    /// Two dead sessions in the same worktree deliberately collapse together: the person
    /// reading the output has one directory to clean up, not two.
    private static func orphanKeysForDeadSessions(
        environments: [Int32: ProcessEnvironment],
        live: [Int32: SessionInfo]
    ) -> [Int32: AttributionKey] {
        var members: [Int32: [Int32]] = [:]
        for (pid, env) in environments {
            guard let spawner = env.spawningSessionPID, live[spawner] == nil else { continue }
            members[spawner, default: []].append(pid)
        }

        var keys: [Int32: AttributionKey] = [:]
        for (spawner, pids) in members {
            // Sorted so the choice of worktree does not depend on dictionary ordering.
            let candidates = ([spawner] + pids).sorted()
            let found = candidates.lazy
                .compactMap { environments[$0]?.pwd }
                .compactMap(worktreeID(forPath:))
                .first
            keys[spawner] = found.map { AttributionKey.orphan(repo: $0.repo, worktree: $0.worktree) }
                // Nothing left to place it by. Still an orphan, keyed by the session that
                // spawned it, because "a Claude session died here" is real information and
                // filing it under system processes is how it stays invisible.
                ?? .orphan(repo: "", worktree: "session-\(spawner)")
        }
        return keys
    }

    /// Nearest placed ancestor, or the session whose root process is an ancestor.
    private static func ancestorKey(
        of pid: Int32,
        parents: [Int32: Int32],
        placed: [Int32: ProcessAttribution],
        liveByPID: [Int32: SessionInfo]
    ) -> AttributionKey? {
        var current = pid
        var seen: Set<Int32> = []
        // The process table is sampled while it mutates, so a cycle can be observed even
        // though it cannot exist. A hang here would stall every later sampler tick.
        while seen.insert(current).inserted, current > 1 {
            if let live = liveByPID[current] { return .session(uuid: live.sessionID) }
            if current != pid, let known = placed[current] { return known.key }
            guard let parent = parents[current] else { return nil }
            current = parent
        }
        return nil
    }

    /// Tier 4 for containers: compose `working_dir`, then Testcontainers clustering, then
    /// honest failure. A tier-C container is never reapable by anything.
    public static func resolveContainers(
        containers: [ContainerInfo],
        sessions: [SessionInfo]
    ) -> [String: ContainerAttribution] {
        var liveByWorktree: [WorktreeID: SessionInfo] = [:]
        for s in sessions {
            if let id = worktreeID(forPath: s.cwd) { liveByWorktree[id] = s }
        }

        var out: [String: ContainerAttribution] = [:]
        out.reserveCapacity(containers.count)

        for c in containers {
            // Tier A. The compose label points at the directory the project was brought
            // up from, which is frequently a subdirectory of the worktree rather than its
            // root, so it is resolved to a worktree rather than compared for equality.
            if let dir = c.composeWorkingDir {
                if let id = worktreeID(forPath: dir) {
                    let key: AttributionKey = liveByWorktree[id]
                        .map { .session(uuid: $0.sessionID) }
                        ?? .orphan(repo: id.repo, worktree: id.worktree)
                    out[c.id] = ContainerAttribution(containerID: c.id, key: key,
                                                     tier: .containerLabel)
                } else {
                    // A compose project that is not in a worktree at all. It belongs to
                    // someone, but nothing here says to whom.
                    out[c.id] = ContainerAttribution(containerID: c.id, key: .unattributed,
                                                     tier: .unresolved)
                }
                continue
            }

            // Tier B. Grouped, and honestly unplaced. Reaching a Claude session from here
            // means finding the process holding a socket to ryuk's published port, which
            // is a stretch goal rather than something to approximate.
            if let cluster = testcontainersCluster(of: c) {
                out[c.id] = ContainerAttribution(containerID: c.id, key: .unattributed,
                                                 tier: .containerLabel, clusterID: cluster)
                continue
            }

            // Tier C. Nothing on it says who wanted it, so nothing may decide it is
            // disposable.
            out[c.id] = ContainerAttribution(containerID: c.id, key: .unattributed, tier: .unresolved)
        }
        return out
    }

    /// The Testcontainers session a container belongs to.
    ///
    /// The library labels the containers it starts but not the reaper it starts alongside
    /// them; on the reaper the session id appears only in the name, in a format the
    /// library itself emits. Reading it there is what lets a database and the thing that
    /// will clean it up show as one unit, which is the unit a person decides about. This
    /// is the single place a name is parsed, and it is not a precedent: a compose project
    /// whose name happens to embed a worktree hash is still attributed from its label.
    static func testcontainersCluster(of container: ContainerInfo) -> String? {
        if let id = container.testcontainersSessionID { return id }
        guard container.isTestcontainersReaper else { return nil }
        let prefix = "testcontainers-ryuk-"
        guard container.name.hasPrefix(prefix) else { return nil }
        let id = String(container.name.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Containers grouped by the project that brought them up, tied to the session or
    /// worktree that owns it.
    ///
    /// The grouping key is the Compose project rather than the worktree, because two
    /// stacks in one worktree are two things you start and stop separately. A
    /// Testcontainers cluster groups by its session id, so a database and the reaper that
    /// will clean it up read as one unit. Anything else is a group of one, named after
    /// itself, and stays unattributed.
    public static func containerGroups(containers: [ContainerInfo],
                                       sessions: [SessionInfo]) -> [ContainerGroup] {
        guard !containers.isEmpty else { return [] }
        let placed = resolveContainers(containers: containers, sessions: sessions)

        var order: [String] = []
        var members: [String: [ContainerInfo]] = [:]
        for container in containers {
            let project = container.composeProject
                ?? placed[container.id]?.clusterID.map { "testcontainers \($0.prefix(8))" }
                ?? container.name
            if members[project] == nil { order.append(project) }
            members[project, default: []].append(container)
        }

        let groups = order.map { project -> ContainerGroup in
            let inGroup = members[project] ?? []
            // The group's identity comes from whichever member the cascade could place.
            // A Compose stack agrees across its containers; a Testcontainers cluster is
            // unattributed either way.
            let key = inGroup.compactMap { placed[$0.id]?.key }
                .first { $0 != .unattributed } ?? .unattributed

            // Summed only when Docker answered for every member. A partial sum looks
            // complete and is wrong, which is worse than saying nothing.
            let cpu = inGroup.allSatisfy { $0.cpuPercent != nil }
                ? inGroup.reduce(0.0) { $0 + ($1.cpuPercent ?? 0) } : nil
            let rss = inGroup.allSatisfy { $0.rssBytes != nil }
                ? inGroup.reduce(UInt64(0)) { $0 + ($1.rssBytes ?? 0) } : nil

            return ContainerGroup(
                project: project, key: key,
                label: label(for: key, sessions: sessions,
                             machine: MachineInfo(cpuCount: 0, memTotalBytes: 0,
                                                  loadAverage1: 0, capturedAt: Date(),
                                                  homeDirectory: "")),
                containers: inGroup, cpuPercent: cpu, rssBytes: rss)
        }

        return groups.sorted {
            if ($0.cpuPercent ?? -1) != ($1.cpuPercent ?? -1) {
                return ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
            }
            if ($0.rssBytes ?? 0) != ($1.rssBytes ?? 0) { return ($0.rssBytes ?? 0) > ($1.rssBytes ?? 0) }
            return $0.project < $1.project
        }
    }

    /// What a reap of `target` would select, and why it selected each thing.
    ///
    /// Narrow by construction. Selection is by env stamp for processes and by the compose
    /// `working_dir` label for containers, and by nothing else. A path match or a ppid
    /// walk could cross into a session that is still working, which is the one failure
    /// this tool must never have.
    public static func reapPlan(
        for target: AttributionKey,
        processes: [ProcessSample],
        environments: [Int32: ProcessEnvironment],
        containers: [ContainerInfo],
        roster: Roster,
        keepMarkedWorktrees: Set<String> = []
    ) -> ReapPlan {
        // Nothing is stopped on a roster that was not read just now. A failed read used
        // to look exactly like "no sessions are running", which resolved every live
        // session to an orphan and put it on the kill list. `claude agents --json` takes
        // longer than its timeout precisely when the machine is loaded, which is the only
        // time anyone runs this.
        guard roster.allowsReaping else {
            return ReapPlan(key: target, processes: [], containers: [],
                            refusal: .rosterNotLive)
        }
        let sessions = roster.sessions

        // Only work a Claude session is responsible for is reapable. System families and
        // the unattributed bucket are reported so the totals add up, and that is all.
        switch target {
        case .system, .unattributed:
            return ReapPlan(key: target, processes: [], containers: [])
        case .session, .orphan:
            break
        }

        let targetWorktree = worktree(of: target, sessions: sessions)

        if let wt = targetWorktree,
           keepMarkedWorktrees.contains(where: { worktreeID(forPath: $0) == wt }) {
            return ReapPlan(key: target, processes: [], containers: [], refusal: .keepFile)
        }

        let attribution = resolveProcesses(processes: processes, environments: environments,
                                           sessions: sessions)

        // Env stamp only. A process resolved by its path might be the person's own editor
        // sitting in the worktree, and one resolved by its parent might have been adopted
        // from somewhere else entirely. Neither is a good enough reason to signal it.
        //
        // The narrowness is deliberate and it costs something: unstamped children are not
        // signalled directly. In practice signalling the parent is what stops them, and a
        // Postgres postmaster shuts its workers down more cleanly than anything reaching
        // past it could.
        var processTargets: [ReapTarget] = []
        for proc in processes {
            guard let placed = attribution[proc.pid],
                  placed.key == target,
                  placed.tier == .envStamp,
                  let spawner = environments[proc.pid]?.spawningSessionPID
            else { continue }
            processTargets.append(ReapTarget(
                pid: proc.pid, command: proc.command,
                reason: "CLAUDE_CODE_MESSAGING_SOCKET names session \(spawner)"))
        }

        // Compose label only. A testcontainers cluster has its own reaper and racing it
        // achieves nothing, and an unlabelled container is never eligible for anything.
        var containerTargets: [ReapComposeTarget] = []
        if let wt = targetWorktree {
            for c in containers {
                guard let dir = c.composeWorkingDir, worktreeID(forPath: dir) == wt else { continue }
                containerTargets.append(ReapComposeTarget(
                    containerID: c.id, name: c.name, workingDirectory: dir,
                    reason: "compose working_dir is \(wt.repo)::\(wt.worktree)"))
            }
        }

        return ReapPlan(key: target, processes: processTargets.sorted { $0.pid < $1.pid },
                        containers: containerTargets.sorted { $0.containerID < $1.containerID })
    }

    /// The worktree a key owns, when it owns one. An orphan keyed only by its dead
    /// session's pid owns no directory, so nothing on disk can be matched against it.
    private static func worktree(of key: AttributionKey,
                                 sessions: [SessionInfo]) -> WorktreeID? {
        switch key {
        case .session(let uuid):
            return sessions.first { $0.sessionID == uuid }
                .flatMap { worktreeID(forPath: $0.cwd) }
        case .orphan(let repo, let worktree):
            return repo.isEmpty ? nil : WorktreeID(repo: repo, worktree: worktree)
        case .system, .unattributed:
            return nil
        }
    }

    /// Family from the executable path only. Deliberately not from the whole command
    /// line: a shell script that merely mentions `docker` in an argument is not Docker,
    /// and the reference capture contains exactly that.
    public static func systemFamily(forCommand command: String) -> SystemFamily {
        for (prefix, family) in bundleFamilies where command.hasPrefix(prefix) { return family }

        // Docker's helpers do not all live inside the bundle. Match the executable's own
        // name, never a word in the arguments: the reference capture holds shell
        // one-liners mentioning `docker`, and filing those under Docker would inflate the
        // largest bucket on the machine with things that are not Docker.
        let executable = command.prefix { $0 != " " }
        let name = executable.split(separator: "/").last.map(String.init) ?? ""
        if name.hasPrefix("com.docker.") { return .docker }

        return .other
    }

    private static let bundleFamilies: [(String, SystemFamily)] = [
        ("/Applications/Google Chrome.app/", .chrome),
        ("/Applications/Docker.app/", .docker),
        ("/Applications/Claude.app/", .claudeDesktop),
    ]

    /// Human-readable name for a key, given the machine it was captured on.
    public static func label(for key: AttributionKey, sessions: [SessionInfo],
                             machine: MachineInfo) -> String {
        switch key {
        case .session(let uuid):
            guard let s = sessions.first(where: { $0.sessionID == uuid }) else {
                return "session \(uuid.prefix(8))"
            }
            if s.cwd == machine.homeDirectory { return "~" }
            return worktreeLabel(forPath: s.cwd) ?? "session \(uuid.prefix(8))"

        case .orphan(let repo, let worktree):
            if repo.isEmpty { return "orphaned \(worktree)" }
            if worktree.isEmpty { return repo }
            return "\(repo)::\(strippingWorktreeHash(worktree))"

        case .system(let family):
            switch family {
            case .docker: return "Docker"
            case .chrome: return "Chrome"
            case .claudeDesktop: return "Claude desktop app"
            case .other: return "Other processes"
            }

        case .unattributed:
            return "Unattributed"
        }
    }

    /// Interval CPU percentage from two snapshots' cumulative CPU times.
    ///
    /// One entry per PID in `later`. An empty result means the interval itself was
    /// unusable, which a caller renders as unknown rather than as zero: a missing entry
    /// carries the same meaning as a nil `ContainerInfo.cpuPercent`.
    public static func cpuPercents(
        earlier: [ProcessSample], earlierAt: Date,
        later: [ProcessSample], laterAt: Date
    ) -> [Int32: Double] {
        let elapsed = laterAt.timeIntervalSince(earlierAt)
        guard elapsed > 0 else { return [:] }

        let baseline = Dictionary(earlier.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        var out: [Int32: Double] = [:]
        out.reserveCapacity(later.count)
        for proc in later {
            let consumed: TimeInterval
            let over: TimeInterval

            if let was = baseline[proc.pid], isSameProcess(was, proc) {
                consumed = proc.cpuTime - was.cpuTime
                over = elapsed
            } else {
                // Either newly spawned or a recycled PID. Both are measured from this
                // process's own start, never diffed against whatever held the PID before:
                // on a machine at load 55 PIDs recycle within minutes, and that diff
                // would come out negative.
                consumed = proc.cpuTime
                let sinceBirth = laterAt.timeIntervalSince(proc.startedAt)
                over = sinceBirth > 0 && sinceBirth < elapsed ? sinceBirth : elapsed
            }

            out[proc.pid] = consumed > 0 ? (consumed / over) * 100 : 0
        }
        return out
    }

    /// Same PID plus same start time. The start time is what distinguishes a long-lived
    /// process from a new one that inherited its PID.
    private static func isSameProcess(_ a: ProcessSample, _ b: ProcessSample) -> Bool {
        // One second of tolerance, because a start time that has been through the SQLite
        // store has lost its sub-second precision.
        abs(a.startedAt.timeIntervalSince(b.startedAt)) < 1
    }

    /// `<repo>::<worktree>` for a path under `<repo>/.claude/worktrees/<worktree>`,
    /// otherwise the basename. Used for both session and orphan labels, so a dead
    /// session's leftovers line up with the session that spawned them.
    public static func worktreeLabel(forPath path: String) -> String? {
        let trimmed = path.hasSuffix("/") ? String(path.reversed().drop { $0 == "/" }.reversed()) : path
        guard !trimmed.isEmpty else { return nil }

        guard let marker = trimmed.range(of: worktreeMarker) else {
            let base = trimmed.split(separator: "/").last
            return base.map(String.init)
        }
        guard let repo = trimmed[trimmed.startIndex..<marker.lowerBound]
                .split(separator: "/").last,
              let worktree = trimmed[marker.upperBound...]
                .split(separator: "/").first
        else { return nil }

        return "\(repo)::\(strippingWorktreeHash(String(worktree)))"
    }

    static let worktreeMarker = "/.claude/worktrees/"

    /// Worktree directories carry a six-hex-character suffix appended by the tooling that
    /// created them. It disambiguates the directory, not the work, so it is dropped for
    /// display while the full directory name stays in the attribution key.
    static func strippingWorktreeHash(_ name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return name }
        let suffix = name[name.index(after: dash)...]
        guard suffix.count == 6,
              suffix.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return name }
        return String(name[name.startIndex..<dash])
    }
}
