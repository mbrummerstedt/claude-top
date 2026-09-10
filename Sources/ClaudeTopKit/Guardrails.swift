import Foundation

/// The hooks: the same engine driven by Claude Code's lifecycle rather than by a terminal.
///
/// Pure functions, so what they would do to a command is testable without a machine under
/// load and without running anything. A hook that rewrites commands has to be provably
/// conservative, because the cost of a wrong rewrite is a command that does not run.
public enum Guardrails {

    /// Load past this multiple of the core count is where a machine stops keeping up.
    public static let oversubscriptionThreshold = 2.0

    /// How many workers a test runner may have on a machine already in trouble.
    ///
    /// A quarter of the cores, which is two on a ten-core laptop. A single `vitest` run
    /// defaults to one worker per core and can saturate a machine on its own: the
    /// reference capture caught nine of them at roughly 29% each.
    public static func workerCap(loadAverage1: Double, cpuCount: Int) -> Int? {
        guard cpuCount > 0,
              loadAverage1 > Double(cpuCount) * oversubscriptionThreshold
        else { return nil }
        return max(1, cpuCount / 4)
    }

    /// The command with a worker cap applied, or nil to leave it exactly as it is.
    ///
    /// nil is the common answer and the safe one. It is returned when the machine is
    /// coping, when no recognised runner is being invoked, when the author already chose
    /// a cap, and whenever the runner cannot be identified with certainty.
    public static func cappedCommand(_ command: String, loadAverage1: Double,
                                     cpuCount: Int) -> String? {
        guard let cap = workerCap(loadAverage1: loadAverage1, cpuCount: cpuCount) else {
            return nil
        }

        // Rewrite only the segment holding the runner, so a build step or an echo either
        // side of it survives untouched.
        var segments = split(command)
        var rewroteSomething = false

        for index in segments.indices {
            guard case .command(let text) = segments[index],
                  let runner = runner(in: text),
                  let rewritten = apply(cap: cap, to: text, runner: runner)
            else { continue }
            segments[index] = .command(rewritten)
            rewroteSomething = true
        }

        guard rewroteSomething else { return nil }
        return segments.map(\.text).joined()
    }

    // MARK: - recognising a runner

    enum Runner {
        case nodeTestRunner   // vitest and jest both take --maxWorkers
        case pytestXdist      // -n, from the xdist plugin
    }

    /// The runner a command segment actually invokes, if any.
    ///
    /// Decided from the executable position, never from the command text: rewriting a
    /// `grep vitest` because the word appears in it would be worse than doing nothing.
    /// This is the same rule that keeps a shell script mentioning `docker` out of the
    /// Docker bucket.
    static func runner(in segment: String) -> Runner? {
        var tokens = segment.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        // Step past package runners until the real executable is in front.
        let wrappers: Set<String> = ["npx", "pnpm", "yarn", "bun", "npm", "uv", "poetry",
                                     "exec", "run", "dlx", "x", "env", "time"]
        while let first = tokens.first.map({ ($0 as NSString).lastPathComponent }),
              wrappers.contains(first) {
            tokens.removeFirst()
        }

        guard let executable = tokens.first.map({ ($0 as NSString).lastPathComponent })
        else { return nil }

        switch executable {
        case "vitest", "jest":
            return .nodeTestRunner
        case "pytest", "py.test":
            // `-n` comes from pytest-xdist. Adding it to a pytest without that plugin
            // turns a passing suite into an argument error, so only a command already
            // asking for parallelism is touched.
            return tokens.contains("-n") ? .pytestXdist : nil
        default:
            return nil
        }
    }

    private static func apply(cap: Int, to segment: String, runner: Runner) -> String? {
        // The spacing around a segment is what holds the line together once the segments
        // are joined back up, so it is set aside and restored rather than normalised.
        let core = segment.trimmingCharacters(in: .whitespaces)
        guard let start = segment.range(of: core)?.lowerBound,
              let end = segment.range(of: core, options: .backwards)?.upperBound
        else { return nil }
        let leading = String(segment[segment.startIndex..<start])
        let trailing = String(segment[end...])

        let rewritten: String
        switch runner {
        case .nodeTestRunner:
            // Someone who wrote a cap knows something this does not.
            guard !core.contains("--maxWorkers") else { return nil }
            rewritten = core + " --maxWorkers=\(cap)"

        case .pytestXdist:
            var tokens = core.split(separator: " ").map(String.init)
            guard let flag = tokens.firstIndex(of: "-n"), flag + 1 < tokens.count else {
                return nil
            }
            // `-n auto` asks for one worker per core, which is the case this exists for.
            // An explicit smaller number is left alone: someone already decided to use
            // less of the machine than this would allow.
            if let existing = Int(tokens[flag + 1]), existing <= cap { return nil }
            tokens[flag + 1] = "\(cap)"
            rewritten = tokens.joined(separator: " ")
        }

        return leading + rewritten + trailing
    }

    // MARK: - splitting a command line

    /// A command, or the operator between two of them. Operators are kept so the line can
    /// be put back together exactly as it came in apart from the segment that changed.
    enum Segment {
        case command(String)
        case separator(String)

        var text: String {
            switch self {
            case .command(let text), .separator(let text): return text
            }
        }
    }

    static func split(_ command: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var index = command.startIndex

        func flush() {
            if !current.isEmpty { segments.append(.command(current)); current = "" }
        }

        while index < command.endIndex {
            let remainder = command[index...]
            if let separator = ["&&", "||", ";", "|"].first(where: { remainder.hasPrefix($0) }) {
                flush()
                segments.append(.separator(separator))
                index = command.index(index, offsetBy: separator.count)
            } else {
                current.append(command[index])
                index = command.index(after: index)
            }
        }
        flush()
        return segments
    }

    // MARK: - the session start warning

    /// What to say when a session opens on a machine that is already struggling, or nil
    /// when it is coping.
    ///
    /// nil most of the time is the point. A hook that speaks every session is a hook
    /// people turn off, and then it is not there on the day it matters.
    public static func sessionStartWarning(_ snapshot: Snapshot) -> String? {
        let machine = snapshot.machine
        guard machine.oversubscription > oversubscriptionThreshold else { return nil }

        var lines = [
            "This machine is already oversubscribed: load "
                + "\(String(format: "%.1f", machine.loadAverage1)) across \(machine.cpuCount) cores "
                + "(\(String(format: "%.1f", machine.oversubscription))x). "
                + "Expect commands to be slow, and prefer not to start anything parallel.",
        ]

        // Labels only. A prompt preview would become model context and may be written
        // into a transcript, so it stays in the terminal where it was shown.
        let worst = snapshot.groups.prefix(5).filter { ($0.cpuPercent ?? 0) > 0 }
        if !worst.isEmpty {
            lines.append("")
            lines.append("Using the most CPU right now:")
            for group in worst {
                lines.append("  \(group.label)  \(Int((group.cpuPercent ?? 0).rounded()))%")
            }
        }

        let orphans = snapshot.orphans
        if !orphans.isEmpty {
            let processes = orphans.reduce(0) { $0 + $1.pids.count }
            let containers = orphans.reduce(0) { $0 + $1.containerIDs.count }
            lines.append("")
            lines.append("\(processes) processes and \(containers) containers belong to sessions "
                         + "that have exited, across \(orphans.count) worktrees. Stopping those "
                         + "costs nobody their work: `claude-top --reap --dry-run` lists them.")
        }

        return lines.joined(separator: "\n")
    }
}
