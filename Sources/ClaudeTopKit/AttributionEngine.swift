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
        fatalError("not implemented — see docs/IMPLEMENTATION-PLAN.md 1.4")
    }

    /// Interval CPU percentage from two snapshots' cumulative CPU times.
    ///
    /// Must tolerate PIDs appearing and disappearing between samples, and a non-monotonic
    /// wall clock. Returns one entry per PID present in `later`.
    public static func cpuPercents(
        earlier: [ProcessSample], earlierAt: Date,
        later: [ProcessSample], laterAt: Date
    ) -> [Int32: Double] {
        fatalError("not implemented — see docs/IMPLEMENTATION-PLAN.md 1.6")
    }

    /// `<repo>::<worktree>` for a path under `<repo>/.claude/worktrees/<worktree>`,
    /// otherwise the basename. Used for both session and orphan labels, so a dead
    /// session's leftovers line up with the session that spawned them.
    public static func worktreeLabel(forPath path: String) -> String? {
        fatalError("not implemented — see docs/IMPLEMENTATION-PLAN.md 1.3")
    }
}
