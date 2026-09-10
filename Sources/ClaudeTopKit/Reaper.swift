import Foundation

public struct ReapOutcome: Sendable, Equatable {
    public let terminated: [Int32]
    public let killed: [Int32]
    public let survived: [Int32]
    public let containersStopped: [String]

    public init(terminated: [Int32], killed: [Int32], survived: [Int32],
                containersStopped: [String]) {
        self.terminated = terminated; self.killed = killed
        self.survived = survived; self.containersStopped = containersStopped
    }
}

/// Carrying out a reap plan.
///
/// The plan decides what; this decides how, and the how is fixed: `SIGTERM`, wait, and
/// only then insist. A `SIGKILL` opening move gives a Postgres no chance to close cleanly
/// and gives a test runner no chance to remove its temporary directories.
///
/// The signalling function is injectable so that the escalation can be tested without
/// anything on the machine being signalled.
public struct Reaper {

    public typealias Signaller = @Sendable (Int32, Int32) -> Bool
    public typealias LivenessCheck = @Sendable (Int32) -> Bool

    private let signaller: Signaller
    private let isAlive: LivenessCheck
    private let stopContainer: @Sendable (String) -> Bool
    private let logURL: URL
    private let now: @Sendable () -> Date

    public static var defaultLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/state/reap.log")
    }

    public init(signaller: @escaping Signaller = { kill($0, $1) == 0 },
                isAlive: @escaping LivenessCheck = { kill($0, 0) == 0 },
                stopContainer: @escaping @Sendable (String) -> Bool = Reaper.dockerStop,
                logURL: URL = Reaper.defaultLogURL,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.signaller = signaller
        self.isAlive = isAlive
        self.stopContainer = stopContainer
        self.logURL = logURL
        self.now = now
    }

    /// Signal everything in the plan, then check what is left and escalate only that.
    ///
    /// Signalling the whole set before waiting matters: a five-second grace period per
    /// process would take minutes across a worktree's leftovers, and the point of this is
    /// to give the machine back quickly.
    public func execute(_ plan: ReapPlan, gracePeriod: TimeInterval = 5,
                        sleeper: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) })
        -> ReapOutcome {
        guard !plan.isEmpty else {
            return ReapOutcome(terminated: [], killed: [], survived: [], containersStopped: [])
        }

        var terminated: [Int32] = []
        for target in plan.processes where signaller(target.pid, SIGTERM) {
            terminated.append(target.pid)
            append(log: "SIGTERM pid=\(target.pid) key=\(plan.key.storageKey) "
                        + "reason=\(target.reason) cmd=\(target.command.prefix(120))")
        }

        var killed: [Int32] = []
        var survived: [Int32] = []
        if !terminated.isEmpty {
            sleeper(gracePeriod)
            for pid in terminated where isAlive(pid) {
                if signaller(pid, SIGKILL) {
                    killed.append(pid)
                    append(log: "SIGKILL pid=\(pid) key=\(plan.key.storageKey) "
                                + "reason=did not exit within \(Int(gracePeriod))s of SIGTERM")
                } else {
                    survived.append(pid)
                }
            }
        }

        var stopped: [String] = []
        for target in plan.containers where stopContainer(target.containerID) {
            stopped.append(target.containerID)
            append(log: "STOP container=\(target.name) id=\(target.containerID) "
                        + "key=\(plan.key.storageKey) reason=\(target.reason)")
        }

        return ReapOutcome(terminated: terminated, killed: killed,
                           survived: survived, containersStopped: stopped)
    }

    /// Every signal is recorded with the reason the target was selected, so a reap can be
    /// audited afterwards rather than only trusted beforehand.
    private func append(log line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: now())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    public static let dockerStop: @Sendable (String) -> Bool = { id in
        guard let docker = Shell.locate("docker") else { return false }
        return Shell.run(docker, ["stop", id], timeout: 15) != nil
    }
}
