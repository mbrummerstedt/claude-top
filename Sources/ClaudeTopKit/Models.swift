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

    public init(pid: Int32, ppid: Int32, rssBytes: UInt64,
                cpuTime: TimeInterval, startedAt: Date, command: String) {
        self.pid = pid; self.ppid = ppid; self.rssBytes = rssBytes
        self.cpuTime = cpuTime; self.startedAt = startedAt; self.command = command
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
///
/// The `name` field of that JSON is the user's opening prompt. It is deliberately absent
/// here: it must not be persisted, logged, or written into a fixture.
public struct SessionInfo: Sendable {
    public let pid: Int32
    public let cwd: String
    public let sessionID: String
    public let startedAt: Date

    public init(pid: Int32, cwd: String, sessionID: String, startedAt: Date) {
        self.pid = pid; self.cwd = cwd; self.sessionID = sessionID; self.startedAt = startedAt
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
    public var testcontainersSessionID: String? { labels["org.testcontainers.session-id"] }
    public var isTestcontainersReaper: Bool { labels["org.testcontainers.ryuk"] == "true" }
}

public struct MachineInfo: Sendable {
    public let cpuCount: Int
    public let memTotalBytes: UInt64
    public let loadAverage1: Double
    public let capturedAt: Date
    /// Passed in rather than read, so attribution stays a pure function and a fixture
    /// captured on one machine still labels correctly when replayed on another.
    public let homeDirectory: String

    public init(cpuCount: Int, memTotalBytes: UInt64, loadAverage1: Double,
                capturedAt: Date, homeDirectory: String = NSHomeDirectory()) {
        self.cpuCount = cpuCount; self.memTotalBytes = memTotalBytes
        self.loadAverage1 = loadAverage1; self.capturedAt = capturedAt
        self.homeDirectory = homeDirectory
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
public struct AttributionGroup: Sendable {
    public let key: AttributionKey
    public let label: String
    public let tier: AttributionTier
    public let cpuPercent: Double
    public let rssBytes: UInt64
    public let pids: [Int32]
    public let containerIDs: [String]

    public init(key: AttributionKey, label: String, tier: AttributionTier,
                cpuPercent: Double, rssBytes: UInt64, pids: [Int32], containerIDs: [String]) {
        self.key = key; self.label = label; self.tier = tier
        self.cpuPercent = cpuPercent; self.rssBytes = rssBytes
        self.pids = pids; self.containerIDs = containerIDs
    }
}

public struct Snapshot: Sendable {
    public let machine: MachineInfo
    public let groups: [AttributionGroup]

    public init(machine: MachineInfo, groups: [AttributionGroup]) {
        self.machine = machine; self.groups = groups
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
public struct ReapPlan: Sendable, Equatable {
    public let key: AttributionKey
    public let processes: [ReapTarget]
    public let containers: [ReapComposeTarget]
    /// Set when a `.claude-top-keep` file exempted the worktree, so the CLI can say why
    /// an obvious candidate produced nothing.
    public let exemptedByKeepFile: Bool

    public init(key: AttributionKey, processes: [ReapTarget],
                containers: [ReapComposeTarget], exemptedByKeepFile: Bool = false) {
        self.key = key; self.processes = processes
        self.containers = containers; self.exemptedByKeepFile = exemptedByKeepFile
    }

    public var isEmpty: Bool { processes.isEmpty && containers.isEmpty }
}
