import Foundation

/// One group a reap would stop, with the name and age a person needs to judge it.
public struct ReapProposal: Sendable {
    public let plan: ReapPlan
    public let label: String
    /// How long the oldest member has been running unattended. The strongest argument for
    /// stopping something is that nothing has touched it since yesterday.
    public let age: TimeInterval?

    public init(plan: ReapPlan, label: String, age: TimeInterval?) {
        self.plan = plan; self.label = label; self.age = age
    }

    public var processCount: Int { plan.processes.count }
    public var containerCount: Int { plan.containers.count }
}

extension Renderer {

    /// The screen between a keystroke and a signal.
    ///
    /// Everything that would be stopped, named, before anything is. What is rendered here
    /// is exactly what gets signalled: the plan is built once, shown, and acted on, and is
    /// never rebuilt in between, so nothing can join the list after it has been read.
    public static func reapConfirmation(_ proposals: [ReapProposal], width: Int,
                                        height: Int) -> String {
        guard !proposals.isEmpty else {
            return box(["Nothing to stop.",
                        "",
                        "No processes carry the stamp of a session that has exited, and no",
                        "Compose project belongs to a worktree without one."],
                       footer: "any key  back", width: width, height: height)
        }

        let processes = proposals.reduce(0) { $0 + $1.processCount }
        let containers = proposals.reduce(0) { $0 + $1.containerCount }

        var body: [String] = [
            "Stop \(processes) process\(processes == 1 ? "" : "es")"
                + (containers > 0 ? " and \(containers) container\(containers == 1 ? "" : "s")"
                                  : "")
                + " across \(proposals.count) worktree\(proposals.count == 1 ? "" : "s")?",
            "",
        ]

        // The totals are stated above the list on purpose. The list is what gets cut when
        // the screen is short, and the number is the part you cannot afford to lose.
        let footer = "y  stop them        any other key  cancel"
        let method = "SIGTERM, 5s, then escalate  ·  every signal is written to "
            + "~/.claude/state/reap.log"
        var remaining = height - body.count - 4

        for proposal in proposals {
            guard remaining > 1 else { break }
            var headline = "  \(proposal.label)  \(proposal.processCount) processes"
            if proposal.containerCount > 0 {
                headline += ", \(proposal.containerCount) containers"
            }
            if let age = proposal.age { headline += "  \(formatDuration(age))" }
            body.append(clip(headline, width))
            remaining -= 1

            // A count is not a list. What is actually being signalled gets named, as far
            // as the screen allows.
            for target in proposal.plan.processes {
                guard remaining > 1 else { break }
                body.append(clip("      \(target.pid)  "
                                 + truncate(target.command, to: max(10, width - 14)), width))
                remaining -= 1
            }
            for target in proposal.plan.containers {
                guard remaining > 1 else { break }
                body.append(clip("      container \(target.name)", width))
                remaining -= 1
            }
        }

        let listed = body.filter { $0.hasPrefix("      ") }.count
        if listed < processes + containers {
            body.append(clip("  and \(processes + containers - listed) more, all counted "
                             + "in the total above", width))
        }

        return box(body, footer: footer, method: method, width: width, height: height)
    }

    /// Why a reap is not going to happen, said plainly.
    ///
    /// A refusal that looks like an empty result teaches the wrong thing, and the case
    /// this exists for is the roster failing, which must never read as "all clear".
    public static func reapRefusal(_ reason: String, width: Int, height: Int) -> String {
        box(["Not stopping anything.", "", reason],
            footer: "any key  back", width: width, height: height)
    }

    /// What actually happened, including whatever survived it.
    public static func reapOutcome(_ results: [(label: String, outcome: ReapOutcome)],
                                   width: Int, height: Int) -> String {
        var body: [String] = []
        var survivors: [Int32] = []

        for result in results {
            var line = "  \(result.label)  \(result.outcome.terminated.count) signalled"
            if !result.outcome.killed.isEmpty {
                line += ", \(result.outcome.killed.count) escalated"
            }
            if !result.outcome.containersStopped.isEmpty {
                line += ", \(result.outcome.containersStopped.count) containers stopped"
            }
            body.append(clip(line, width))
            survivors += result.outcome.survived
        }

        if !survivors.isEmpty {
            // A process that ignored both signals is a fact, not something to round away
            // into a success message.
            body.append("")
            body.append(clip("survived both signals: "
                             + survivors.map(String.init).joined(separator: ", "), width))
        }

        return box(["Done.", ""] + body, footer: "any key  back",
                   width: width, height: height)
    }

    /// A full-screen panel that fills the terminal exactly, like every other frame.
    private static func box(_ body: [String], footer: String, method: String? = nil,
                            width: Int, height: Int) -> String {
        var lines = body.map { clip($0, width) }
        while lines.count < height - (method == nil ? 1 : 2) { lines.append("") }
        if let method { lines.append(clip(method, width)) }
        lines.append(clip(footer, width))
        return lines.prefix(height).joined(separator: "\n")
    }
}
