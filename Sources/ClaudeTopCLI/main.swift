import Foundation
import ClaudeTopKit

// claude-top: per-session resource attribution for Claude Code.
//
// Deliberately not a full-screen auto-refreshing TUI. At load 55 the thing you open to
// diagnose the problem should not be competing for the cores you are trying to free, and
// `top` already exists.

let arguments = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { arguments.contains(name) }

func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let next = arguments[index + 1]
    return next.hasPrefix("--") ? nil : next
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("claude-top: \(message)\n".utf8))
    exit(1)
}

let usage = """
claude-top — which Claude Code session is using your machine

USAGE
  claude-top                    two samples 700ms apart, then the table
  claude-top --json             the same snapshot as JSON, for hooks and agents
  claude-top --watch [seconds]  full-screen live view, redraws in place (default 5s)
  claude-top --since <duration> history from the rolling 24h store, e.g. 20m, 2h
  claude-top --sample           one sampler tick written to the store; what launchd runs
  claude-top --statusline       one line for a shell prompt
  claude-top --hook <event>     pre-tool-use or session-start; see docs/HOOKS.md
  claude-top --reap             stop the leftovers of sessions that are gone
      --dry-run                 show what would be stopped and stop nothing
      --yes                     skip the confirmation, for scripts that already decided

ATTRIBUTION
  Four tiers, first hit wins: the CLAUDE_CODE_MESSAGING_SOCKET stamp, then the process
  tree, then the worktree path, then Docker Compose and Testcontainers labels. Anything
  resolving to a worktree with no live session is an orphan. Anything resolving to
  nothing is reported as unattributed rather than guessed at.

  Only your own processes can be inspected; macOS does not permit reading another user's.
  The output says how many it could not see.
"""

/// Duration suffixes as a person writes them at a prompt.
func parseDuration(_ text: String) -> TimeInterval? {
    let units: [(Character, Double)] = [("s", 1), ("m", 60), ("h", 3600), ("d", 86400)]
    guard let suffix = text.last else { return nil }
    if let unit = units.first(where: { $0.0 == suffix }) {
        return Double(text.dropLast()).map { $0 * unit.1 }
    }
    return Double(text)
}

func openStore() -> ResourceStore? {
    try? ResourceStore(path: ResourceStore.defaultPath)
}

// MARK: - commands

if flag("--help") || flag("-h") {
    print(usage)
    exit(0)
}

if flag("--version") {
    print("claude-top 0.1.0 (json contract v\(Renderer.jsonVersion))")
    exit(0)
}

if let event = value("--hook") {
    // Hooks run on Claude Code's schedule, not a person's. Both of these are on paths
    // that must stay cheap: the pre-tool-use one runs before every single Bash call, so
    // it reads the load through sysctl and never samples.
    //
    // A hook that fails is a hook that blocks work, so anything unexpected here exits 0
    // and says nothing. Declining to act is always a safe answer for both of them.
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] ?? [:]

    switch event {
    case "pre-tool-use":
        guard payload["tool_name"] as? String == "Bash",
              var toolInput = payload["tool_input"] as? [String: Any],
              let command = toolInput["command"] as? String
        else { exit(0) }

        let machine = MachineProbe.current()
        guard let capped = Guardrails.cappedCommand(command,
                                                    loadAverage1: machine.loadAverage1,
                                                    cpuCount: machine.cpuCount)
        else { exit(0) }

        toolInput["command"] = capped
        // Said out loud. A hook that silently rewrites what you asked for is a hook you
        // stop trusting the first time you notice.
        let cap = Guardrails.workerCap(loadAverage1: machine.loadAverage1,
                                       cpuCount: machine.cpuCount) ?? 1
        let load = String(format: "%.1f", machine.loadAverage1)
        let reason = "claude-top: load \(load) on \(machine.cpuCount) cores, "
            + "capped test workers to \(cap)"
        emit([
            "systemMessage": reason,
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "updatedInput": toolInput,
            ],
        ])

    case "session-start":
        // Reads the newest stored row when the sampler has been running, and otherwise
        // falls back to load alone. Sampling here would add a four second pause to every
        // session start, on the machine least able to afford it.
        let snapshot = recentStoredSnapshot() ?? Snapshot(machine: MachineProbe.current(),
                                                          groups: [])
        guard let warning = Guardrails.sessionStartWarning(snapshot) else { exit(0) }
        emit([
            "hookSpecificOutput": [
                "hookEventName": "SessionStart",
                "additionalContext": warning,
            ],
        ])

    default:
        fail("unknown hook '\(event)'. Expected pre-tool-use or session-start.")
    }
    exit(0)
}

func emit(_ document: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: document),
          let text = String(data: data, encoding: .utf8)
    else { exit(0) }
    print(text)
}

/// The newest stored tick, if the sampler has run recently enough for it to describe the
/// machine as it is now rather than as it was.
func recentStoredSnapshot(within age: TimeInterval = 300) -> Snapshot? {
    guard let store = openStore(), let latest = try? store.latest(),
          Date().timeIntervalSince(latest.timestamp) < age
    else { return nil }

    return Snapshot(
        machine: MachineInfo(cpuCount: latest.cpuCount, memTotalBytes: latest.memTotalBytes,
                             memUsedBytes: latest.memUsedBytes,
                             loadAverage1: latest.loadAverage1, capturedAt: latest.timestamp),
        groups: latest.groups.map {
            AttributionGroup(key: $0.key, label: $0.label, tier: .envStamp,
                             cpuPercent: $0.cpuPercent, rssBytes: $0.rssBytes,
                             pids: Array(repeating: 0, count: $0.processCount),
                             containerIDs: Array(repeating: "", count: $0.containerCount),
                             sessionPID: $0.sessionPID)
        })
}

if flag("--statusline") {
    // Reads the newest stored row rather than sampling, so it costs one indexed query.
    // It runs on every prompt and has to stay far under the time a person would notice.
    guard let store = openStore(), let latest = try? store.latest() else {
        print("")
        exit(0)
    }
    let snapshot = Snapshot(
        machine: MachineInfo(cpuCount: latest.cpuCount, memTotalBytes: latest.memTotalBytes,
                             memUsedBytes: latest.memUsedBytes,
                             loadAverage1: latest.loadAverage1, capturedAt: latest.timestamp),
        groups: latest.groups.map {
            AttributionGroup(key: $0.key, label: $0.label, tier: .envStamp,
                             cpuPercent: $0.cpuPercent, rssBytes: $0.rssBytes,
                             pids: Array(repeating: 0, count: $0.processCount),
                             containerIDs: Array(repeating: "", count: $0.containerCount),
                             sessionPID: $0.sessionPID)
        })

    // Identified by the session pid in this process's own socket path, which is the same
    // anchor the cascade uses for everything else. Not by CLAUDE_CODE_HOST_SESSION_ID:
    // that is a `local_<uuid>` and the roster's session ids are bare uuids, so matching
    // the two would silently never find anything.
    let ownSessionPID = ProcessInfo.processInfo.environment["CLAUDE_CODE_MESSAGING_SOCKET"]
        .flatMap { ProcessEnvironment(pid: 0, messagingSocket: $0, hostSessionID: nil,
                                      entrypoint: nil, pwd: nil).spawningSessionPID }
    let ownKey = snapshot.groups.first { $0.sessionPID != nil && $0.sessionPID == ownSessionPID }
    if case .session(let uuid)? = ownKey?.key {
        print(Renderer.statusline(snapshot, sessionID: uuid))
    } else {
        print(Renderer.statusline(snapshot, sessionID: nil))
    }
    exit(0)
}

if flag("--sample") {
    // One tick, then exit. A short-lived process rather than a resident daemon: nothing
    // sits in RAM between ticks and a crash self-heals on the next one.
    // The app samples in-process while it is open. Two writers would interleave two
    // different CPU baselines into one table, which yields nonsense percentages rather
    // than merely duplicate rows.
    if SamplerCoordinator.shouldYieldNow() { exit(0) }

    guard let store = openStore() else { fail("cannot open \(ResourceStore.defaultPath)") }

    let sample = Sampler.collect()
    let previous = try? store.baseline()
    let cpu = previous.map {
        AttributionEngine.cpuPercents(earlier: $0.processes, earlierAt: $0.readAt,
                                      later: sample.processes, laterAt: sample.processesReadAt)
    } ?? [:]

    let snapshot = Sampler.attribute(sample, cpuPercents: cpu)
    do {
        try store.write(snapshot, processes: sample.processes, cpuPercents: cpu)
        try store.writeBaseline(sample.processes, at: sample.processesReadAt)
    } catch {
        fail("\(error)")
    }
    exit(0)
}

if let duration = value("--since") {
    guard let seconds = parseDuration(duration) else { fail("cannot read duration '\(duration)'") }
    guard let store = openStore() else { fail("cannot open \(ResourceStore.defaultPath)") }

    let history = (try? store.history(since: Date().addingTimeInterval(-seconds))) ?? []
    guard !history.isEmpty else {
        print("no samples in the last \(duration). Is the sampler installed? "
              + "See Scripts/install-agent.sh")
        exit(0)
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    for tick in history {
        let worst = tick.groups
            .filter { $0.key.kind == "session" || $0.key.kind == "orphan" }
            .max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
        let busiest = worst.map { "\($0.label) \(Int(($0.cpuPercent ?? 0).rounded()))%" } ?? "-"
        print("\(formatter.string(from: tick.timestamp))  "
              + "load \(String(format: "%5.1f", tick.loadAverage1))  \(busiest)")
    }
    exit(0)
}

if flag("--reap") {
    let snapshot = Sampler.snapshot()
    let sample = Sampler.collect()

    // Only the leftovers of sessions that are gone. A live session's own processes are
    // never candidates here: stopping those is the session's business, not this tool's.
    let plans = snapshot.orphans.map { group in
        AttributionEngine.reapPlan(
            for: group.key, processes: sample.processes, environments: sample.environments,
            containers: sample.containers, roster: sample.roster,
            keepMarkedWorktrees: Reaper.keepMarkedWorktrees(in: sample))
    }

    // Said plainly rather than reported as "nothing found". A roster that could not be
    // read makes every live session look abandoned, so refusing is the whole point, and
    // a refusal that looks like an empty result teaches the wrong thing.
    if let refused = plans.first(where: { $0.refusal == .rosterNotLive }) {
        _ = refused
        let age: String
        switch sample.roster.source {
        case .cached(let seconds): age = "the last one is \(Int(seconds))s old"
        case .unavailable: age = "there is no recent one to fall back on"
        case .live: age = ""
        }
        fail("refusing to reap: the session roster could not be read just now, and \(age). "
             + "Without it every live session looks abandoned. Try again, or check "
             + "`claude agents --json` responds.")
    }

    let actionable = plans.filter { !$0.isEmpty }
    for kept in plans where kept.refusal == .keepFile {
        let label = AttributionEngine.label(for: kept.key, sessions: sample.sessions,
                                            machine: sample.machine)
        print("skipping \(label): exempted by a .claude-top-keep file")
    }

    guard !actionable.isEmpty else {
        print("nothing to reap: no orphaned processes carrying a dead session's stamp")
        exit(0)
    }

    for plan in actionable {
        let label = AttributionEngine.label(for: plan.key, sessions: sample.sessions,
                                            machine: sample.machine)
        print("\(label)  \(plan.processes.count) processes, "
              + "\(plan.containers.count) containers")
        for target in plan.processes {
            print("    pid \(target.pid)  \(target.command.prefix(70))")
        }
        for target in plan.containers {
            print("    container \(target.name)")
        }
    }

    if flag("--dry-run") {
        print("\ndry run, nothing was stopped")
        exit(0)
    }

    if !flag("--yes") {
        // Defaults to no. Anything other than an explicit yes stops here.
        print("\nstop all of the above? [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
            print("nothing was stopped")
            exit(0)
        }
    }

    let reaper = Reaper()
    for plan in actionable {
        let outcome = reaper.execute(plan)
        print("\(plan.key.storageKey): "
              + "\(outcome.terminated.count) signalled, \(outcome.killed.count) escalated, "
              + "\(outcome.containersStopped.count) containers stopped")
    }
    exit(0)
}

// MARK: - the default reading

if flag("--watch") {
    // A full-screen view that redraws in place. Cheap by construction: see LiveView.
    LiveView.run(interval: value("--watch").flatMap(Double.init) ?? 5)
    exit(0)
}

let snapshot = Sampler.snapshot()
print(flag("--json") ? Renderer.json(snapshot) : Renderer.text(snapshot))
