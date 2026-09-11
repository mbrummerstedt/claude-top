import Foundation

/// What a process or container is charged to.
///
/// `unattributed` is a first-class outcome, not a failure. The point of this tool is
/// deciding what to kill, so a confidently wrong attribution is worse than an honest
/// blank. Never widen a tier to make the output look tidier.
public enum AttributionKey: Hashable, Sendable {
    case session(uuid: String)
    case orphan(repo: String, worktree: String)
    case system(family: SystemFamily)
    case unattributed
}

public enum SystemFamily: String, Hashable, Sendable {
    case docker
    case chrome
    case claudeDesktop
    case other
}

/// Which rule assigned an `AttributionKey`. Kept on every row so the CLI can explain
/// itself and so tests can assert the cascade order rather than only the outcome.
public enum AttributionTier: Int, Comparable, Sendable {
    case envStamp = 0        // CLAUDE_CODE_MESSAGING_SOCKET, survives session death
    case processTree = 1     // ppid walk from a live session root
    case worktreePath = 2    // PWD or vnode path under .claude/worktrees/
    case containerLabel = 3  // compose working_dir, or testcontainers session-id
    /// No rule fired. Named `unresolved` rather than `none` because `x?.tier == .unresolved`
    /// compiles against `Optional.none` and silently asks a different question.
    case unresolved = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct ProcessSample: Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let rssBytes: UInt64
    /// Cumulative user + system CPU time. The interval percentage comes from diffing
    /// this between two snapshots. `ps` %cpu is a lifetime average and must not be used
    /// for ranking.
    public let cpuTime: TimeInterval
    public let startedAt: Date
    public let command: String
    /// argv as the kernel handed it over, before it was joined for display.
    ///
    /// Kept because joining loses the only thing that separates one argument from the
    /// next: an executable path containing a space, of which a Mac has many, splits into
    /// nonsense when the joined string is taken apart again. Empty when argv could not be
    /// read, and callers fall back to splitting `command`.
    public let arguments: [String]

    public init(pid: Int32, ppid: Int32, rssBytes: UInt64,
                cpuTime: TimeInterval, startedAt: Date, command: String,
                arguments: [String] = []) {
        self.pid = pid; self.ppid = ppid; self.rssBytes = rssBytes
        self.cpuTime = cpuTime; self.startedAt = startedAt; self.command = command
        self.arguments = arguments
    }
}

/// The four environment variables the engine reads. Everything else a process holds is
/// discarded at the read, never retained and never written to disk: process environments
/// routinely contain API keys and database passwords.
public struct ProcessEnvironment: Sendable {
    public let pid: Int32
    public let messagingSocket: String?   // /tmp/cc-socks/<session-pid>.sock
    public let hostSessionID: String?     // local_<uuid>
    public let entrypoint: String?
    public let pwd: String?

    public init(pid: Int32, messagingSocket: String?, hostSessionID: String?,
                entrypoint: String?, pwd: String?) {
        self.pid = pid; self.messagingSocket = messagingSocket
        self.hostSessionID = hostSessionID; self.entrypoint = entrypoint; self.pwd = pwd
    }

    /// The spawning session's PID, parsed out of the messaging socket path.
    /// This is the attribution anchor and it survives both reparenting and session death.
    public var spawningSessionPID: Int32? {
        guard let s = messagingSocket,
              let name = s.split(separator: "/").last?.split(separator: ".").first
        else { return nil }
        return Int32(name)
    }
}

/// A live session, from `claude agents --json`.
public struct SessionInfo: Sendable {
    public let pid: Int32
    public let cwd: String
    public let sessionID: String
    public let startedAt: Date
    /// The opening prompt, which is the only thing that tells two sessions apart when
    /// both were started from a home directory and neither has a worktree to be named
    /// after.
    ///
    /// Display only, and only in the terminal table. It is never written to the database,
    /// never in `--json`, never in the reap log, and never in a fixture: it is the user's
    /// own words, and a file on disk outlives the terminal it was printed to.
    /// `PromptBoundaryTests` is what keeps that true.
    public let promptPreview: String?

    public init(pid: Int32, cwd: String, sessionID: String, startedAt: Date,
                promptPreview: String? = nil) {
        self.pid = pid; self.cwd = cwd; self.sessionID = sessionID
        self.startedAt = startedAt; self.promptPreview = promptPreview
    }
}

public struct ContainerInfo: Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let labels: [String: String]
    /// nil when `docker stats` timed out. Unknown is a valid state; a hung docker must
    /// never stall a sample tick.
    public let cpuPercent: Double?
    public let rssBytes: UInt64?

    public init(id: String, name: String, image: String, labels: [String: String],
                cpuPercent: Double?, rssBytes: UInt64?) {
        self.id = id; self.name = name; self.image = image; self.labels = labels
        self.cpuPercent = cpuPercent; self.rssBytes = rssBytes
    }

    public var composeWorkingDir: String? { labels["com.docker.compose.project.working_dir"] }
    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var testcontainersSessionID: String? { labels["org.testcontainers.session-id"] }
    public var isTestcontainersReaper: Bool { labels["org.testcontainers.ryuk"] == "true" }
}

public struct MachineInfo: Sendable {
    public let cpuCount: Int
    public let memTotalBytes: UInt64
    /// Active, wired and compressed. Memory was not the binding constraint on the
    /// reference machine (10 of 16 GB at load 55) but it is what people look at first.
    public let memUsedBytes: UInt64
    public let loadAverage1: Double
    public let capturedAt: Date
    /// Passed in rather than read, so attribution stays a pure function and a fixture
    /// captured on one machine still labels correctly when replayed on another.
    public let homeDirectory: String
    /// Every process the kernel listed, including the ones this user may not inspect.
    /// macOS allows reading task info only for your own processes, so roughly a third of
    /// a Mac's process table is invisible here. That costs nothing worth having: Claude
    /// spawns nothing as root, and a root daemon is not something a session could stop
    /// anyway. It is recorded so the output can say what it did not see instead of
    /// implying the breakdown is complete.
    public let processCount: Int
    /// The kernel's CPU counters at capture time, for diffing against the next reading.
    public let cpuTicks: CPUTicks?

    public init(cpuCount: Int, memTotalBytes: UInt64, memUsedBytes: UInt64 = 0,
                loadAverage1: Double, capturedAt: Date,
                homeDirectory: String = NSHomeDirectory(), processCount: Int = 0,
                cpuTicks: CPUTicks? = nil) {
        self.cpuCount = cpuCount; self.memTotalBytes = memTotalBytes
        self.memUsedBytes = memUsedBytes
        self.loadAverage1 = loadAverage1; self.capturedAt = capturedAt
        self.homeDirectory = homeDirectory; self.processCount = processCount
        self.cpuTicks = cpuTicks
    }

    public var oversubscription: Double {
        cpuCount > 0 ? loadAverage1 / Double(cpuCount) : 0
    }
}

/// One process, resolved. The tier is kept alongside the key so the CLI can explain why
/// something was charged where it was, and so tests assert the cascade order rather than
/// only its outcome.
public struct ProcessAttribution: Sendable, Equatable {
    public let pid: Int32
    public let key: AttributionKey
    public let tier: AttributionTier

    public init(pid: Int32, key: AttributionKey, tier: AttributionTier) {
        self.pid = pid; self.key = key; self.tier = tier
    }
}

public struct ContainerAttribution: Sendable, Equatable {
    public let containerID: String
    public let key: AttributionKey
    public let tier: AttributionTier
    /// Testcontainers session id, when this container belongs to such a cluster. Set even
    /// while the cluster itself is unattributed, because the cluster is the unit a person
    /// reasons about: a database and the reaper that will clean it up.
    public let clusterID: String?

    public init(containerID: String, key: AttributionKey, tier: AttributionTier,
                clusterID: String? = nil) {
        self.containerID = containerID; self.key = key
        self.tier = tier; self.clusterID = clusterID
    }
}

/// One attributed group, ready to render or store.
///
/// Process figures and container figures are kept apart on purpose. On macOS every
/// container runs inside Docker's virtual machine, so a container's CPU and memory are
/// already counted in `com.docker.krun`'s. Adding them into a session's totals would
/// count the same 2.3 GB twice and make attributed memory exceed what the machine has.
public struct AttributionGroup: Sendable {
    public let key: AttributionKey
    public let label: String
    /// The highest-priority rule that placed any member, so the CLI can say how much
    /// confidence the row deserves.
    public let tier: AttributionTier
    /// Process CPU across the sampling interval. nil when the interval itself was
    /// unusable, which is reported as unknown rather than as zero.
    public let cpuPercent: Double?
    public let rssBytes: UInt64
    /// Container CPU, when `docker stats` answered. Never added to `cpuPercent`.
    public let containerCPUPercent: Double?
    /// Container memory, when `docker stats` answered. Never added to `rssBytes`.
    public let containerRSSBytes: UInt64?
    public let pids: [Int32]
    public let containerIDs: [String]
    /// The live session's own process id, for `.session` keys. It is what lets a process
    /// recognise its own row: a session knows its pid from the socket path it was handed,
    /// and that anchor is the same one the whole cascade rests on.
    public let sessionPID: Int32?
    /// The session's opening prompt, for the terminal table only. Kept out of `label`
    /// deliberately, because `label` is stored and this must not be.
    public let promptPreview: String?
    /// What the group is made of, heaviest kind first. Empty for a group of one, where
    /// the row already says everything the breakdown would.
    public let breakdown: [ProcessKind]
    /// When the longest-running member started. For an orphan this is how long the
    /// leftovers have been running unattended, which is the fact that decides whether
    /// they are worth stopping: a watcher idle since yesterday is not coming back.
    public let oldestProcessStartedAt: Date?

    public init(key: AttributionKey, label: String, tier: AttributionTier,
                cpuPercent: Double?, rssBytes: UInt64,
                containerCPUPercent: Double? = nil, containerRSSBytes: UInt64? = nil,
                pids: [Int32], containerIDs: [String],
                oldestProcessStartedAt: Date? = nil, sessionPID: Int32? = nil,
                promptPreview: String? = nil, breakdown: [ProcessKind] = []) {
        self.key = key; self.label = label; self.tier = tier
        self.cpuPercent = cpuPercent; self.rssBytes = rssBytes
        self.containerCPUPercent = containerCPUPercent
        self.containerRSSBytes = containerRSSBytes
        self.pids = pids; self.containerIDs = containerIDs
        self.oldestProcessStartedAt = oldestProcessStartedAt
        self.sessionPID = sessionPID
        self.promptPreview = promptPreview
        self.breakdown = breakdown
    }

    /// Only sessions and their leftovers can be stopped by this tool. A system family or
    /// an unattributed container is reported so the totals are honest and for no other
    /// reason.
    public var isReapable: Bool {
        switch key {
        case .session, .orphan: return true
        case .system, .unattributed: return false
        }
    }
}

/// Groups are ordered the way they are read: live sessions first, then the leftovers of
/// sessions that are gone, then everything else, each block by CPU descending. That order
/// is part of the `--json` contract as much as it is a rendering choice.
public struct Snapshot: Sendable {
    public let machine: MachineInfo
    public let groups: [AttributionGroup]
    /// Containers rolled up by the project that brought them up. Separate from `groups`
    /// because a container is not a process: its figures come from Docker and describe
    /// the inside of a virtual machine, not this Mac's cores.
    public let containerGroups: [ContainerGroup]
    /// What the whole machine was doing, from the kernel's own counters. Present only
    /// when two readings were available to diff.
    public let systemCPU: SystemCPU?

    public init(machine: MachineInfo, groups: [AttributionGroup],
                containerGroups: [ContainerGroup] = [], systemCPU: SystemCPU? = nil) {
        self.machine = machine; self.groups = groups
        self.containerGroups = containerGroups; self.systemCPU = systemCPU
    }

    /// Everything this tool could place, in per-core units.
    public var attributedCPUPercent: Double {
        groups.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
    }

    /// The share of the machine's work that happened in processes this user may not
    /// inspect: the kernel, the window server, other users' daemons.
    ///
    /// Stated rather than left as a discrepancy for someone to find. On a busy Mac it is
    /// large, and a tool showing the smaller number without explaining it reads as wrong
    /// even when every figure in it is right.
    /// Cores doing work, from the kernel's own counters. The figure Activity Monitor
    /// puts at the bottom of its window, expressed as cores rather than as a percentage
    /// of the whole machine, because "3.9 of 10 cores" needs no conversion in your head.
    public var busyCores: Double? {
        systemCPU.map { $0.busyPercent / 100 * Double(machine.cpuCount) }
    }

    /// Cores this tool could actually account for. Below `busyCores` by whatever is
    /// happening in processes it may not inspect.
    public var visibleCores: Double { attributedCPUPercent / 100 }

    /// Threads runnable or waiting on the kernel, averaged over a minute. Above the core
    /// count it is the queue everything is stuck in, and it is the reason a machine can
    /// feel unusable while the CPU chart looks calm.
    public var queuedThreads: Double { machine.loadAverage1 }

    public var unaccountedCPUPercent: Double? {
        guard let systemCPU else { return nil }
        // The two are sampled over slightly different windows, so attribution can edge
        // past the machine total. A negative gap would be nonsense on screen.
        return max(0, systemCPU.busyPerCore(cpuCount: machine.cpuCount)
                      - attributedCPUPercent)
    }

    public var sessions: [AttributionGroup] {
        groups.filter { if case .session = $0.key { return true } else { return false } }
    }

    public var orphans: [AttributionGroup] {
        groups.filter { if case .orphan = $0.key { return true } else { return false } }
    }

    public var everythingElse: [AttributionGroup] {
        groups.filter {
            switch $0.key {
            case .session, .orphan: return false
            case .system, .unattributed: return true
            }
        }
    }

    /// Process memory only. Container memory is excluded because it is already inside the
    /// Docker VM process's, and this total is checked against what the machine has.
    public var attributedRSSBytes: UInt64 {
        groups.reduce(0) { $0 + $1.rssBytes }
    }

    public var attributedProcessCount: Int {
        groups.reduce(0) { $0 + $1.pids.count }
    }

    /// Processes the kernel listed that this user may not inspect: other users' and the
    /// system's. Reported rather than quietly dropped.
    public var unreadableProcessCount: Int {
        max(0, machine.processCount - attributedProcessCount)
    }
}

/// One process a reap would signal, carrying the reason it was selected. The reason is
/// written to `~/.claude/state/reap.log` alongside every kill, so that a reap can be
/// audited after the fact rather than only trusted before it.
public struct ReapTarget: Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let reason: String

    public init(pid: Int32, command: String, reason: String) {
        self.pid = pid; self.command = command; self.reason = reason
    }
}

public struct ReapComposeTarget: Sendable, Equatable {
    public let containerID: String
    public let name: String
    public let workingDirectory: String
    public let reason: String

    public init(containerID: String, name: String, workingDirectory: String, reason: String) {
        self.containerID = containerID; self.name = name
        self.workingDirectory = workingDirectory; self.reason = reason
    }
}

/// Deliberately inert. Producing the plan touches nothing; a caller decides whether to
/// act on it, and `--dry-run` prints one without acting.
public enum ReapRefusal: Sendable, Equatable {
    /// A `.claude-top-keep` file in the worktree.
    case keepFile
    /// The roster was cached or missing, so "this session is gone" was never established.
    case rosterNotLive
}

public struct ReapPlan: Sendable, Equatable {
    public let key: AttributionKey
    public let processes: [ReapTarget]
    public let containers: [ReapComposeTarget]
    /// Why an obvious candidate produced nothing, so the CLI can say so rather than
    /// looking as though it found nothing to do.
    public let refusal: ReapRefusal?

    public init(key: AttributionKey, processes: [ReapTarget],
                containers: [ReapComposeTarget], refusal: ReapRefusal? = nil) {
        self.key = key; self.processes = processes
        self.containers = containers; self.refusal = refusal
    }

    public var isEmpty: Bool { processes.isEmpty && containers.isEmpty }
}

extension AttributionKey {
    /// Stable string form, used as the SQLite primary key and as the `key` field in
    /// `--json`. Both are contracts that outlive a release, so the shape is fixed here
    /// rather than left to whatever a formatter happens to produce.
    public var storageKey: String {
        switch self {
        case .session(let uuid): return "session:\(uuid)"
        case .orphan(let repo, let worktree): return "orphan:\(repo)::\(worktree)"
        case .system(let family): return "system:\(family.rawValue)"
        case .unattributed: return "unattributed"
        }
    }

    /// The block this key belongs to, which is what the CLI groups by and what a consumer
    /// of `--json` filters on.
    public var kind: String {
        switch self {
        case .session: return "session"
        case .orphan: return "orphan"
        case .system: return "system"
        case .unattributed: return "unattributed"
        }
    }

    public init?(storageKey: String) {
        if storageKey == "unattributed" { self = .unattributed; return }
        guard let colon = storageKey.firstIndex(of: ":") else { return nil }
        let value = String(storageKey[storageKey.index(after: colon)...])
        switch storageKey[storageKey.startIndex..<colon] {
        case "session":
            self = .session(uuid: value)
        case "orphan":
            guard let separator = value.range(of: "::") else { return nil }
            self = .orphan(repo: String(value[value.startIndex..<separator.lowerBound]),
                           worktree: String(value[separator.upperBound...]))
        case "system":
            guard let family = SystemFamily(rawValue: value) else { return nil }
            self = .system(family: family)
        default:
            return nil
        }
    }
}

/// A tick read back out of the store.
public struct StoredSample: Sendable {
    public let timestamp: Date
    public let loadAverage1: Double
    public let cpuCount: Int
    public let memUsedBytes: UInt64
    public let memTotalBytes: UInt64
    public let groups: [StoredGroup]

    public init(timestamp: Date, loadAverage1: Double, cpuCount: Int,
                memUsedBytes: UInt64, memTotalBytes: UInt64, groups: [StoredGroup]) {
        self.timestamp = timestamp; self.loadAverage1 = loadAverage1
        self.cpuCount = cpuCount; self.memUsedBytes = memUsedBytes
        self.memTotalBytes = memTotalBytes; self.groups = groups
    }
}

public struct StoredGroup: Sendable {
    public let key: AttributionKey
    public let label: String
    public let cpuPercent: Double?
    public let rssBytes: UInt64
    public let processCount: Int
    public let containerCount: Int
    public let sessionPID: Int32?

    public init(key: AttributionKey, label: String, cpuPercent: Double?, rssBytes: UInt64,
                processCount: Int, containerCount: Int, sessionPID: Int32? = nil) {
        self.key = key; self.label = label; self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes; self.processCount = processCount
        self.containerCount = containerCount; self.sessionPID = sessionPID
    }
}

/// The session roster, together with where it came from.
///
/// The provenance is not bookkeeping. A roster that could not be read is not a roster
/// with no sessions in it, and the difference decides whether every live session on the
/// machine reads as an orphan. Carrying the two together makes that impossible to forget
/// at the call site.
public struct Roster: Sendable {
    public enum Source: Sendable, Equatable {
        /// Read just now. The only state that may authorise stopping anything.
        case live
        /// The last good read, reused because a fresh one failed.
        case cached(age: TimeInterval)
        /// Nothing to go on.
        case unavailable
    }

    public let sessions: [SessionInfo]
    public let source: Source

    public init(sessions: [SessionInfo], source: Source) {
        self.sessions = sessions; self.source = source
    }

    /// Good enough to show. A cached roster describes the machine a few minutes ago,
    /// which is worth looking at and worth labelling.
    public var isUsableForDisplay: Bool {
        switch source {
        case .live, .cached: return true
        case .unavailable: return false
        }
    }

    /// Good enough to kill by, which only a fresh read is.
    ///
    /// A session started since a cache was written is absent from it, so its processes
    /// would resolve as orphaned. That is acceptable in a list and unacceptable in a
    /// kill list.
    public var allowsReaping: Bool { source == .live }
}

/// Containers rolled up into the unit a person reasons about.
///
/// Nobody thinks about `bpb-replay-postgres-1`. They think about the stack a worktree
/// brought up, which is three containers that live and die together, and about whether
/// the session that started it still exists.
public struct ContainerGroup: Sendable {
    /// The Compose project, the Testcontainers session, or a lone container's own name.
    public let project: String
    public let key: AttributionKey
    /// The worktree or session this belongs to, or an honest blank.
    public let label: String
    public let containers: [ContainerInfo]
    /// As Docker reports it, which is a share of the virtual machine's CPUs and not of
    /// this Mac's. Never added to a host figure. nil when Docker could not answer for
    /// every container in the group.
    public let cpuPercent: Double?
    public let rssBytes: UInt64?

    public init(project: String, key: AttributionKey, label: String,
                containers: [ContainerInfo], cpuPercent: Double?, rssBytes: UInt64?) {
        self.project = project; self.key = key; self.label = label
        self.containers = containers; self.cpuPercent = cpuPercent; self.rssBytes = rssBytes
    }

    public var isReapable: Bool {
        // Same rule as everywhere else: a Compose project in a worktree whose session is
        // gone. Never a Testcontainers cluster, which has its own reaper, and never an
        // unlabelled container, which nothing can claim.
        if case .orphan = key { return containers.allSatisfy { $0.composeWorkingDir != nil } }
        return false
    }
}
