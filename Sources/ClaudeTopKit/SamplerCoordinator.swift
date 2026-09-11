import Foundation

/// A running sampler's claim on the store.
public struct SamplerOwner: Codable, Sendable, Equatable {
    public let pid: Int32
    /// Refreshed on every tick. A claim that stops moving is a claim from something that
    /// is still running but no longer sampling, and it must not hold the file forever.
    public let heartbeat: Date

    public init(pid: Int32, heartbeat: Date) {
        self.pid = pid; self.heartbeat = heartbeat
    }
}

/// Deciding which process writes ticks.
///
/// While the app is open it samples in-process and the LaunchAgent stands down. Two
/// samplers writing at once would interleave two different CPU baselines into one table,
/// which produces nonsense percentages rather than merely duplicate rows, and would double
/// the cost of the thing that exists to reduce cost.
public enum SamplerCoordinator {

    /// A claim older than this belongs to something that has stopped sampling, whatever
    /// its process is still doing. Four missed fifteen-second ticks.
    public static let staleAfter: TimeInterval = 60

    public static var defaultPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/state/claude-top-sampler-owner.json")
    }

    /// Whether this process should stand down and write nothing.
    ///
    /// Every way of being unsure resolves to "sample anyway". Missing history is a worse
    /// failure than a duplicated tick: a stood-down sampler that is wrong about who owns
    /// the file leaves nothing behind at all.
    public static func shouldYield(to owner: SamplerOwner?, selfPID: Int32, now: Date,
                                   isAlive: (Int32) -> Bool) -> Bool {
        guard let owner, owner.pid != selfPID else { return false }

        let age = now.timeIntervalSince(owner.heartbeat)
        // A claim from the future means a clock change, or a file written by something
        // that is not this. Neither is a reason to trust it.
        guard age >= 0, age < staleAfter else { return false }

        return isAlive(owner.pid)
    }

    public static func owner(at path: URL = defaultPath) -> SamplerOwner? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(SamplerOwner.self, from: data)
    }

    public static func claim(pid: Int32, at date: Date = Date(),
                             path: URL = defaultPath) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(SamplerOwner(pid: pid, heartbeat: date))
        try data.write(to: path, options: .atomic)
    }

    public static func release(at path: URL = defaultPath) {
        try? FileManager.default.removeItem(at: path)
    }

    /// Convenience for the CLI: read the file, ask the kernel, decide.
    public static func shouldYieldNow(path: URL = defaultPath) -> Bool {
        shouldYield(to: owner(at: path), selfPID: getpid(), now: Date(),
                    isAlive: { kill($0, 0) == 0 })
    }
}
