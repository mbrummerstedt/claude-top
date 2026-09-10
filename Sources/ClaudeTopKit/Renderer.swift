import Foundation

/// Turning a snapshot into the three things this tool emits: a table for a person, JSON
/// for a program, and one line for a prompt.
///
/// Kept pure so all three are testable without a machine under load, and so the shapes
/// they promise are pinned by tests rather than by whatever a formatter happened to do.
public enum Renderer {

    /// Bumped only when a field is removed or changes meaning. Adding a field does not
    /// bump it, so a consumer written today keeps working.
    public static let jsonVersion = 1

    // MARK: - the table

    public static func text(_ snapshot: Snapshot) -> String {
        // Sized to the longest label present rather than fixed, because a worktree name
        // truncated mid-word is the one column a person actually reads.
        let width = min(72, max(40, (snapshot.groups.map { displayLabel($0).count }.max() ?? 0) + 4))
        var lines: [String] = [header(snapshot.machine), ""]

        if snapshot.groups.isEmpty {
            lines.append("nothing attributed — no readable processes or containers")
        }

        if !snapshot.sessions.isEmpty {
            lines.append(columnHeading("CLAUDE SESSIONS", width: width))
            lines += snapshot.sessions.map { row($0, asOf: snapshot.machine.capturedAt, width: width) }
            lines.append("")
        }

        if !snapshot.orphans.isEmpty {
            let orphans = snapshot.orphans
            let cpu = orphans.compactMap(\.cpuPercent).reduce(0, +)
            let rss = orphans.reduce(UInt64(0)) { $0 + $1.rssBytes }
            let processes = orphans.reduce(0) { $0 + $1.pids.count }
            let containers = orphans.reduce(0) { $0 + $1.containerIDs.count }
            lines.append(pad("ORPHANED (worktrees with no live session)", to: width)
                         + right(format(cpu: cpu), 6) + right(formatBytes(rss), 8)
                         + right("\(processes)", 6) + right("\(containers)", 8))
            lines += orphans.map { row($0, asOf: snapshot.machine.capturedAt, width: width, showAge: true) }
            lines.append("")
        }

        if !snapshot.everythingElse.isEmpty {
            lines.append("EVERYTHING ELSE")
            lines += snapshot.everythingElse.map { row($0, asOf: snapshot.machine.capturedAt, width: width) }
            lines.append("")
        }

        // Said out loud rather than left as an unexplained gap. macOS grants task info
        // only for your own processes, so a third of a Mac is not visible here, and a
        // breakdown that quietly omits it is the sort of number this tool replaces.
        if snapshot.unreadableProcessCount > 0 {
            lines.append("\(snapshot.unreadableProcessCount) processes belong to other users "
                         + "and cannot be inspected")
        }

        return lines.joined(separator: "\n")
    }

    private static func header(_ machine: MachineInfo) -> String {
        var load = "load \(String(format: "%.1f", machine.loadAverage1)) (\(machine.cpuCount) cores"
        if machine.oversubscription > 1.2 {
            load += ", \(String(format: "%.1f", machine.oversubscription))x oversubscribed"
        }
        load += ")"

        let used = String(format: "%.1f", Double(machine.memUsedBytes) / 1_073_741_824)
        let total = String(format: "%.1f", Double(machine.memTotalBytes) / 1_073_741_824)
        return "\(load)   mem \(used)/\(total) GB"
    }

    private static func columnHeading(_ title: String, width: Int) -> String {
        pad(title, to: width) + right("CPU", 6) + right("RAM", 8)
            + right("PROC", 6) + right("DOCKER", 8)
    }

    /// Ages are measured from when the snapshot was taken, not from now. A sample read
    /// back out of the store through `--since` is history, and dating it against the
    /// current clock would report an age that grows every time it is printed.
    private static func row(_ group: AttributionGroup, asOf: Date, width: Int,
                            showAge: Bool = false) -> String {
        var line = pad("  " + displayLabel(group), to: width)
            + right(format(cpu: group.cpuPercent), 6)
            + right(formatBytes(group.rssBytes), 8)
            + right("\(group.pids.count)", 6)
            + right("\(group.containerIDs.count)", 8)

        if showAge, let started = group.oldestProcessStartedAt {
            line += right(formatDuration(asOf.timeIntervalSince(started)), 6)
        }
        return line
    }

    /// A worktree name is the better handle when there is one: it is what the person
    /// chose when they started the work. The prompt is the fallback for a session started
    /// somewhere with no worktree to be named after, where the alternative is four rows
    /// reading `~` that nobody can tell apart.
    private static func displayLabel(_ group: AttributionGroup) -> String {
        guard let prompt = group.promptPreview, !group.label.contains("::") else {
            return group.label
        }
        return "\(group.label) \"\(prompt)\""
    }

    /// A missing percentage is unknown, and unknown prints as unknown. Zero would read as
    /// idle and sort to the bottom, which is the worst answer to give someone deciding
    /// what to stop.
    private static func format(cpu: Double?) -> String {
        guard let cpu else { return "?" }
        return "\(Int(cpu.rounded()))%"
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1fG", gigabytes) }
        return "\(bytes / 1_048_576)M"
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 86400 { return "\(Int(seconds / 86400))d" }
        if seconds >= 3600 { return "\(Int(seconds / 3600))h" }
        if seconds >= 60 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds))s"
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? String(text.prefix(width - 1)) + " "
                            : text + String(repeating: " ", count: width - text.count)
    }

    private static func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? text
                            : String(repeating: " ", count: width - text.count) + text
    }

    // MARK: - json

    /// The contract the statusline, the hooks, and anything else automating this consume.
    /// Every group says whether it can safely be stopped and which PIDs that would mean,
    /// so a caller can act without re-deriving any of it.
    public static func json(_ snapshot: Snapshot) -> String {
        // Built here rather than kept as a shared static: a date formatter is not
        // Sendable, and rendering happens once per invocation so the allocation is free.
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]

        let machine: [String: Any] = [
            "cpuCount": snapshot.machine.cpuCount,
            "loadAverage1": snapshot.machine.loadAverage1,
            "oversubscription": snapshot.machine.oversubscription,
            "memUsedBytes": snapshot.machine.memUsedBytes,
            "memTotalBytes": snapshot.machine.memTotalBytes,
            "processCount": snapshot.machine.processCount,
            "unreadableProcessCount": snapshot.unreadableProcessCount,
        ]

        let groups: [[String: Any]] = snapshot.groups.map { group in
            var row: [String: Any] = [
                "key": group.key.storageKey,
                "kind": group.key.kind,
                "label": group.label,
                "tier": group.tier.name,
                "cpuPercent": group.cpuPercent ?? NSNull(),
                "rssBytes": group.rssBytes,
                "processCount": group.pids.count,
                "containerCount": group.containerIDs.count,
                "containerCpuPercent": group.containerCPUPercent ?? NSNull(),
                "containerRssBytes": group.containerRSSBytes ?? NSNull(),
                "reapable": group.isReapable,
                "pids": group.pids,
                "containerIds": group.containerIDs,
            ]
            if let started = group.oldestProcessStartedAt {
                row["oldestProcessStartedAt"] = iso8601.string(from: started)
                row["ageSeconds"] = Int(snapshot.machine.capturedAt.timeIntervalSince(started))
            }
            return row
        }

        let document: [String: Any] = [
            "version": jsonVersion,
            "capturedAt": iso8601.string(from: snapshot.machine.capturedAt),
            "machine": machine,
            "groups": groups,
        ]

        // Sorted keys so two runs can be diffed against each other.
        guard let data = try? JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // MARK: - statusline

    /// One line for the prompt, so the climb is visible before it becomes a crisis. This
    /// is the part Activity Monitor structurally cannot provide, because it has no concept
    /// of "this session".
    public static func statusline(_ snapshot: Snapshot, sessionID: String?) -> String {
        let machine = snapshot.machine
        let warning = machine.oversubscription > 1.5 ? "⚠ " : ""
        var line = "\(warning)load \(String(format: "%.1f", machine.loadAverage1))/\(machine.cpuCount)"

        if let sessionID,
           let mine = snapshot.groups.first(where: { $0.key == .session(uuid: sessionID) }),
           let cpu = mine.cpuPercent {
            line += "  self \(Int(cpu.rounded()))%"
        }
        return line
    }
}

extension AttributionTier {
    /// Stable names, because they appear in `--json`.
    public var name: String {
        switch self {
        case .envStamp: return "envStamp"
        case .processTree: return "processTree"
        case .worktreePath: return "worktreePath"
        case .containerLabel: return "containerLabel"
        case .unresolved: return "unresolved"
        }
    }
}
