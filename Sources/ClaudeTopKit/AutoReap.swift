import Foundation

/// Stopping things with nobody watching.
///
/// Every other reap path here puts a list in front of a person first. This one does not,
/// so the question it must answer is not "is this abandoned" but "has this been abandoned
/// long enough that nothing could still want it".
///
/// Process age cannot answer that. A session that exited a minute ago can own a process
/// three days old, and a rule based on process age would take it instantly. What counts is
/// how long a worktree has been continuously observed with no session behind it, which no
/// single sample can see and which therefore has to be remembered across runs.
public enum AutoReap {

    /// Nothing is stopped unattended before this much continuous abandonment. Long enough
    /// that a lunch break, a rebuild, or a laptop lid cannot look like abandonment.
    public static let defaultQuarantine: TimeInterval = 8 * 3600

    /// How many groups one unattended run may stop.
    ///
    /// An unattended thing that can stop forty groups in a single pass is one bad rule
    /// away from stopping forty it should not have. A ceiling keeps the blast radius of
    /// any future mistake small enough to notice and to recover from, and the backlog is
    /// worked through over successive runs.
    public static let defaultLimit = 3

    /// Which abandoned worktrees have waited long enough, longest first.
    public static func eligible(orphans: [AttributionGroup],
                                orphanedSince: [String: Date],
                                quarantine: TimeInterval,
                                now: Date,
                                limit: Int = defaultLimit) -> [AttributionGroup] {
        // A quarantine of zero removes the only thing making this safe, which is far more
        // likely to be a mistake than an intention.
        guard quarantine > 0, limit > 0 else { return [] }

        return orphans.compactMap { group -> (AttributionGroup, Date)? in
            // Belt and braces. `orphans` should hold only orphans; this makes a mistake
            // upstream survivable rather than fatal.
            guard case .orphan = group.key,
                  let since = orphanedSince[group.key.storageKey]
            else { return nil }

            let abandoned = now.timeIntervalSince(since)
            // A record from the future is a clock change or a file written by something
            // else. Neither is a reason to stop anything.
            guard abandoned >= quarantine else { return nil }
            return (group, since)
        }
        .sorted { $0.1 < $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    /// What an unattended run takes from one orphan.
    ///
    /// The quarantine stands in for a question nothing can answer directly, which is
    /// whether anyone could still come back to this worktree. A worktree deleted from disk
    /// answers it. No session can start there again and compose cannot bring the stack
    /// back without the project files that went with it, so its containers are taken on
    /// the first run that sees them and removed rather than stopped.
    ///
    /// Processes still wait. A deleted directory says the stack is finished with, not that
    /// a process which started there has finished its work.
    public static func plan(_ plan: ReapPlan, quarantineElapsed: Bool) -> ReapPlan {
        let containers = plan.containers.map { target -> ReapComposeTarget in
            guard worktreeIsDeleted(containing: target.workingDirectory) else { return target }
            return ReapComposeTarget(containerID: target.containerID, name: target.name,
                                     workingDirectory: target.workingDirectory,
                                     reason: target.reason + ", worktree deleted",
                                     remove: true)
        }
        if quarantineElapsed {
            return ReapPlan(key: plan.key, processes: plan.processes, containers: containers,
                            refusal: plan.refusal)
        }
        return ReapPlan(key: plan.key, processes: [], containers: containers.filter(\.remove))
    }

    /// A worktree that was deleted, as opposed to one that cannot be seen right now.
    ///
    /// Only `ENOENT` on the worktree itself counts, and only while the directory that held
    /// it is still there. An unmounted disk fails a `stat` the same way a deletion does,
    /// and a folder this process may not read fails it with a different error. Neither
    /// means the stack is finished with.
    static func worktreeIsDeleted(containing path: String) -> Bool {
        guard let root = AttributionEngine.worktreeRoot(forPath: path) else { return false }
        var info = stat()
        guard stat((root as NSString).deletingLastPathComponent, &info) == 0 else { return false }
        return stat(root, &info) != 0 && errno == ENOENT
    }
}
