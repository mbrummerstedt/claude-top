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
            for group in snapshot.sessions {
                lines.append(row(group, asOf: snapshot.machine.capturedAt, width: width))
                lines += detailRows(for: group, limit: 3).map { kindRow($0, width: width) }
            }
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

        if !snapshot.containerGroups.isEmpty {
            let containers = snapshot.containerGroups.reduce(0) { $0 + $1.containers.count }
            lines.append("DOCKER (\(containers) containers, cpu is inside the VM)")
            // Two columns rather than one run-on string: the project is what you type
            // at docker, and the owner is what tells you whether you may.
            // Sized to its own content rather than inherited from the group rows: a
            // project name and an owner on one line need more room than a worktree label
            // does, and truncating the owner is what makes the row useless.
            let projectWidth = min(30, max(12, snapshot.containerGroups
                                            .map(\.project.count).max() ?? 12))
            let ownerWidth = min(46, max(16, snapshot.containerGroups.map {
                ($0.label.isEmpty ? 12 : $0.label.count) + ($0.isReapable ? 13 : 0)
            }.max() ?? 16))
            let dockerWidth = projectWidth + ownerWidth + 6
            for group in snapshot.containerGroups {
                let owner = (group.label.isEmpty ? "unattributed" : group.label)
                    + (group.isReapable ? "  (stoppable)" : "")
                lines.append(pad("  " + truncate(group.project, to: projectWidth),
                                 to: projectWidth + 4)
                             + pad(truncate(owner, to: ownerWidth),
                                   to: max(0, dockerWidth - projectWidth - 4))
                             + right(group.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "?", 6)
                             + right(group.rssBytes.map(formatBytes) ?? "?", 8)
                             + right("\(group.containers.count)", 6))
            }
            let stoppable = snapshot.containerGroups.filter(\.isReapable)
            if !stoppable.isEmpty {
                let count = stoppable.reduce(0) { $0 + $1.containers.count }
                lines.append("  \(count) container\(count == 1 ? "" : "s") in "
                             + "\(stoppable.count) abandoned "
                             + "project\(stoppable.count == 1 ? "" : "s") can be stopped")
            }
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
            // What the group is made of. An agent deciding what to cap or stop needs the
            // kinds and their pids, not just a total.
            if !group.breakdown.isEmpty {
                row["breakdown"] = group.breakdown.map { kind -> [String: Any] in
                    [
                        "name": kind.name,
                        "count": kind.count,
                        "cpuPercent": kind.cpuPercent ?? NSNull(),
                        "rssBytes": kind.rssBytes,
                        "pids": kind.pids,
                    ]
                }
            }
            if let started = group.oldestProcessStartedAt {
                row["oldestProcessStartedAt"] = iso8601.string(from: started)
                row["ageSeconds"] = Int(snapshot.machine.capturedAt.timeIntervalSince(started))
            }
            return row
        }

        let dockerProjects: [[String: Any]] = snapshot.containerGroups.map { group in
            [
                "project": group.project,
                "key": group.key.storageKey,
                "kind": group.key.kind,
                "label": group.label,
                "containerCount": group.containers.count,
                "containerIds": group.containers.map(\.id),
                "containerNames": group.containers.map(\.name),
                // Docker's own figures, which describe the inside of the virtual machine.
                // Deliberately named apart from the host `cpuPercent` on a group so the
                // two are never added together by a consumer.
                "vmCpuPercent": group.cpuPercent ?? NSNull(),
                "vmRssBytes": group.rssBytes ?? NSNull(),
                // A Compose stack in a worktree whose session is gone. Never a live
                // session's stack, never a Testcontainers cluster.
                "stoppable": group.isReapable,
            ]
        }

        let document: [String: Any] = [
            "version": jsonVersion,
            "dockerProjects": dockerProjects,
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

/// What the live view knows about itself.
public struct LiveViewStatus: Sendable {
    public let refreshInterval: TimeInterval
    /// This process's own CPU across the last interval. The design notes argued against a
    /// live view on the grounds that it would compete for the cores you are trying to
    /// free; showing the number settles that by measurement rather than by assertion.
    public let ownCPUPercent: Double?
    public let ownRSSBytes: UInt64
    public let rosterSource: Roster.Source

    public init(refreshInterval: TimeInterval, ownCPUPercent: Double?,
                ownRSSBytes: UInt64, rosterSource: Roster.Source) {
        self.refreshInterval = refreshInterval; self.ownCPUPercent = ownCPUPercent
        self.ownRSSBytes = ownRSSBytes; self.rosterSource = rosterSource
    }
}

extension Renderer {

    /// How many rows each block gets, decided before anything is drawn.
    ///
    /// Sessions are the headline but orphans are the part a person can act on without
    /// costing anyone their work, so orphans and the system block are given their rows
    /// first and sessions take what is left. Observed at load 91 with 21 sessions: the
    /// orphan block had been squeezed to two rows and "and 2 more", which is the wrong
    /// thing to hide at exactly the moment it matters.
    static func allocateRows(available: Int, sessions: Int, orphans: Int,
                             docker: Int, everythingElse: Int)
        -> (sessions: Int, orphans: Int, docker: Int, everythingElse: Int) {
        // A heading and a trailing blank line, per block that appears at all.
        let overhead = 2
        func cost(_ rows: Int) -> Int { rows == 0 ? 0 : rows + overhead }

        var orphanRows = min(orphans, 8)
        var dockerRows = min(docker, 5)
        var elseRows = min(everythingElse, 6)
        var sessionRows = min(sessions, max(0, available - cost(orphanRows) - cost(dockerRows)
                                            - cost(elseRows) - (sessions > 0 ? overhead : 0)))

        // Still over, which happens on a short terminal. Give back in reverse order of
        // how much the row is worth reading.
        while cost(sessionRows) + cost(orphanRows) + cost(dockerRows) + cost(elseRows)
                > available {
            if elseRows > 1 { elseRows -= 1 }
            else if sessionRows > 1 { sessionRows -= 1 }
            else if dockerRows > 1 { dockerRows -= 1 }
            else if orphanRows > 1 { orphanRows -= 1 }
            else if elseRows > 0 { elseRows = 0 }
            else if dockerRows > 0 { dockerRows = 0 }
            else if sessionRows > 0 { sessionRows = 0 }
            else if orphanRows > 0 { orphanRows = 0 }
            else { break }
        }
        return (sessionRows, orphanRows, dockerRows, elseRows)
    }

    /// One full-screen frame, built to fit exactly the terminal it is going into.
    ///
    /// Both dimensions are hard limits. A line wider than the terminal wraps and pushes
    /// everything below it down a row, so the next redraw paints over the wrong lines;
    /// a frame taller than the terminal scrolls, and a view that scrolls while it
    /// redraws cannot be read at all.
    public static func liveFrame(_ snapshot: Snapshot, width: Int, height: Int,
                                 status: LiveViewStatus) -> String {
        var lines: [String] = []
        let machine = snapshot.machine

        let ratio = machine.oversubscription
        var header = "load \(String(format: "%.1f", machine.loadAverage1))"
            + "  \(machine.cpuCount) cores"
        if ratio > 1 { header += "  \(String(format: "%.1f", ratio))x" }
        let memory = "mem \(String(format: "%.1f", Double(machine.memUsedBytes) / 1_073_741_824))"
            + "/\(String(format: "%.0f", Double(machine.memTotalBytes) / 1_073_741_824))G"
        lines.append(fit(header, memory, width: width))

        if case .cached(let age) = status.rosterSource {
            lines.append(clip("session list is cached (\(Int(age))s old), "
                              + "reaping is disabled until it refreshes", width))
        } else if status.rosterSource == .unavailable {
            lines.append(clip("session list unavailable, sessions below may be live", width))
        }
        lines.append("")

        let orphans = snapshot.orphans
        let rosterIsKnown = status.rosterSource != .unavailable
        let footerRows = 2
        // Lines, not groups. A heavy session brings sub-rows with it, and allocating by
        // group count left no budget for them, so they were silently never drawn.
        func lineCost(_ groups: [AttributionGroup]) -> Int {
            groups.reduce(0) { $0 + 1 + detailRows(for: $1, limit: 2).count }
        }
        let allocation = allocateRows(available: max(0, height - lines.count - footerRows),
                                      sessions: lineCost(snapshot.sessions),
                                      orphans: lineCost(orphans),
                                      docker: snapshot.containerGroups.count,
                                      everythingElse: lineCost(snapshot.everythingElse))

        func section(_ title: String, _ groups: [AttributionGroup], rows: Int,
                     summary: String? = nil, showAge: Bool = false) {
            guard !groups.isEmpty, rows > 0 else { return }
            lines.append(clip(summary.map { "\(title)  \($0)" } ?? title, width))

            // One row gives way to the count when there is more than fits, so the number
            // is never itself the thing that got cut.
            let footer = groups.count > rows ? 1 : 0
            var used = 0
            var rendered = 0

            for group in groups {
                guard used + footer < rows else { break }
                lines.append(liveRow(group, width: width, showAge: showAge,
                                     asOf: machine.capturedAt))
                used += 1
                rendered += 1

                // What the heavy ones are made of. Two lines at most: the point is to
                // name the thing worth stopping, not to list every process.
                for kind in detailRows(for: group, limit: 2) {
                    guard used + footer < rows else { break }
                    lines.append(kindRow(kind, width: width))
                    used += 1
                }
            }
            if groups.count > rendered {
                lines.append(clip("  and \(groups.count - rendered) more", width))
            }
            lines.append("")
        }

        section("CLAUDE SESSIONS", snapshot.sessions, rows: allocation.sessions)

        if rosterIsKnown {
            // Processes, memory and containers rather than a CPU percentage: an idle
            // orphan reads as 0% and is still holding a Postgres and 200 MB.
            let processes = orphans.reduce(0) { $0 + $1.pids.count }
            let containers = orphans.reduce(0) { $0 + $1.containerIDs.count }
            let bytes = orphans.reduce(UInt64(0)) { $0 + $1.rssBytes }
            var summary = "\(processes) processes, \(formatBytes(bytes))"
            if containers > 0 { summary += ", \(containers) containers" }
            section("ORPHANED", orphans, rows: allocation.orphans,
                    summary: summary + " free to reclaim", showAge: true)
        } else {
            // Without a roster, a stamped process whose session is simply unlisted
            // resolves to an orphan. These may be the sessions in front of you. The rows
            // stay, because the resources are real; the word "orphaned" and the
            // invitation to stop them do not.
            section("UNIDENTIFIED", orphans, rows: allocation.orphans,
                    summary: "no session list, these may be live", showAge: true)
        }

        dockerSection(snapshot.containerGroups, rows: allocation.docker, width: width,
                      into: &lines)

        section("EVERYTHING ELSE", snapshot.everythingElse, rows: allocation.everythingElse)

        while lines.count < height - footerRows { lines.append("") }

        let cost = status.ownCPUPercent.map { "\(Int($0.rounded()))%" } ?? "?"
        lines.append(clip("claude-top \(cost) cpu, \(formatBytes(status.ownRSSBytes)), "
                          + "every \(Int(status.refreshInterval))s"
                          + (snapshot.unreadableProcessCount > 0
                             ? "  ·  \(snapshot.unreadableProcessCount) processes not inspectable"
                             : ""), width))
        let offerReap = !orphans.isEmpty && status.rosterSource == .live
        lines.append(clip("q quit" + (offerReap ? "  ·  claude-top --reap" : ""), width))

        return lines.prefix(height).joined(separator: "\n")
    }

    /// Containers by the project that brought them up, and who owns that project.
    ///
    /// The CPU column is qualified because Docker reports a share of the virtual
    /// machine's CPUs, not of this Mac's. On this machine the containers totalled 0.4%
    /// while the VM itself cost 149% on the host, and putting those two in one column
    /// would invite exactly the wrong conclusion about where the time went.
    private static func dockerSection(_ groups: [ContainerGroup], rows: Int, width: Int,
                                      into lines: inout [String]) {
        guard !groups.isEmpty, rows > 0 else { return }

        let containers = groups.reduce(0) { $0 + $1.containers.count }
        var heading = "DOCKER  \(containers) containers in \(groups.count) "
            + "project\(groups.count == 1 ? "" : "s")  ·  cpu is inside the VM"

        // The cheapest resources on the machine to get back: a stack a dead worktree left
        // running, which nobody is using and which nothing else depends on. Live stacks
        // and Testcontainers clusters are never counted here.
        let stoppable = groups.filter(\.isReapable)
        if !stoppable.isEmpty {
            let count = stoppable.reduce(0) { $0 + $1.containers.count }
            let freed = stoppable.allSatisfy { $0.rssBytes != nil }
                ? " holding " + formatBytes(stoppable.reduce(UInt64(0)) { $0 + ($1.rssBytes ?? 0) })
                : ""
            heading += "\n\(count) container\(count == 1 ? "" : "s") in "
                + "\(stoppable.count) abandoned project\(stoppable.count == 1 ? "" : "s")"
                + freed + " can be stopped"
        }
        for line in heading.split(separator: "\n") { lines.append(clip(String(line), width)) }

        let shown = groups.count > rows ? max(1, rows - 1) : rows
        for group in groups.prefix(shown) {
            let cpu = group.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "?"
            let memory = group.rssBytes.map(formatBytes) ?? "?"
            let right = self.right(cpu, 6) + self.right(memory, 7)
                + self.right("\(group.containers.count)c", 5)
            let room = max(4, width - right.count - 2)
            // The project on the left, who owns it on the right, because "whose is this"
            // is the question a container row exists to answer.
            var owner = group.label.isEmpty ? "unattributed" : group.label
            if group.isReapable { owner += "  (stoppable)" }
            let name = truncate(group.project, to: max(8, (room - 5) / 2))
            lines.append(pad("  " + name + "  " + truncate(owner, to: room - name.count - 6),
                             to: room) + right)
        }
        if groups.count > shown {
            lines.append(clip("  and \(groups.count - shown) more", width))
        }
        lines.append("")
    }

    /// The frame shown while the first sample is still being gathered.
    ///
    /// Load and memory come from `sysctl` and are free; attribution is not. At load 89 a
    /// cold sample takes twelve seconds of wall time on this machine, and twelve seconds
    /// of blank screen is how someone concludes the tool is part of the problem.
    public static func liveFrameCollecting(_ machine: MachineInfo, width: Int,
                                           height: Int) -> String {
        let ratio = machine.oversubscription
        var header = "load \(String(format: "%.1f", machine.loadAverage1))"
            + "  \(machine.cpuCount) cores"
        if ratio > 1 { header += "  \(String(format: "%.1f", ratio))x" }
        let memory = "mem \(String(format: "%.1f", Double(machine.memUsedBytes) / 1_073_741_824))"
            + "/\(String(format: "%.0f", Double(machine.memTotalBytes) / 1_073_741_824))G"

        var lines = [fit(header, memory, width: width), "",
                     clip("reading the process table…", width)]
        while lines.count < height - 1 { lines.append("") }
        lines.append(clip("q quit", width))
        return lines.prefix(height).joined(separator: "\n")
    }

    /// The kinds worth naming under a group's row.
    ///
    /// Only for groups heavy enough to be worth acting on: half a core is the same
    /// threshold the store uses to decide a group is worth keeping detail for. A group
    /// running one of everything gets nothing, because the row already said that.
    static func detailRows(for group: AttributionGroup, limit: Int) -> [ProcessKind] {
        guard (group.cpuPercent ?? 0) >= 50,
              group.breakdown.contains(where: { $0.count > 1 }) || group.breakdown.count > 1
        else { return [] }
        return Array(group.breakdown.prefix(limit))
    }

    private static func kindRow(_ kind: ProcessKind, width: Int) -> String {
        let cpu = kind.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "?"
        let right = self.right(cpu, 6) + self.right(formatBytes(kind.rssBytes), 7) + "     "
        let room = max(4, width - right.count - 2)
        let name = kind.count > 1 ? "\(kind.count)x \(kind.name)" : kind.name
        return pad("    └ " + truncate(name, to: room - 6), to: room) + right
    }

    private static func liveRow(_ group: AttributionGroup, width: Int, showAge: Bool,
                                asOf: Date) -> String {
        let cpu = group.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "?"
        var right = right(cpu, 6) + right(formatBytes(group.rssBytes), 7)
            + right("\(group.pids.count)p", 5)
        if group.containerIDs.isEmpty { right += "     " }
        else { right += self.right("\(group.containerIDs.count)c", 5) }
        if showAge {
            right += self.right(group.oldestProcessStartedAt
                                .map { formatDuration(asOf.timeIntervalSince($0)) } ?? "", 5)
        }

        let room = max(4, width - right.count - 2)
        return pad("  " + truncate(displayLabel(group), to: room - 2), to: room) + right
    }

    /// Left text and right text on one line, with the left giving way first.
    private static func fit(_ left: String, _ right: String, width: Int) -> String {
        guard left.count + right.count + 2 <= width else {
            return clip(left, width)
        }
        return left + String(repeating: " ", count: width - left.count - right.count) + right
    }

    private static func clip(_ text: String, _ width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width))
    }

    /// Middles removed rather than tails, because a worktree name is distinguished by
    /// both ends and `miinto-simple-dynamic-pricing::revenue-sh` tells you less than
    /// `miinto-simple…revenue-share-page` does.
    static func truncate(_ text: String, to width: Int) -> String {
        guard width > 3, text.count > width else {
            return width <= 3 ? String(text.prefix(max(0, width))) : text
        }
        let head = (width - 1) / 2
        let tail = width - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}
