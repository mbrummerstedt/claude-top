import SwiftUI
import ServiceManagement
import ClaudeTopKit

/// The menu bar companion to the CLI. A view over ClaudeTopKit with no logic of its own.
///
/// While it is open it owns sampling and the LaunchAgent stands down, so there is never a
/// second writer. The claim is released on quit and expires on its own if the app is
/// killed.
@main
struct ClaudeTopApp: App {
    @StateObject private var model = ResourceModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model).frame(width: 420)
        } label: {
            // Short by necessity: the menu bar is shared with everything else. The
            // oversubscription ratio says more per character than a raw load does,
            // because it already accounts for how many cores this machine has.
            Text(model.menuBarTitle)
                .monospacedDigit()
                .foregroundStyle(model.menuBarSeverity)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Sampling starts when the app launches, not when its popover is first opened. An ambient
/// monitor that only measures while you are looking at it has no history to show the
/// moment you go looking for one, which is the moment it exists for.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { ResourceModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hands the store back to the LaunchAgent rather than leaving it stood down until
        // the claim expires.
        MainActor.assumeIsolated { ResourceModel.shared.stop() }
    }
}

// MARK: - model

/// What the popover is currently showing. Reaping is a sequence of screens rather than a
/// button, for the same reason it is in the terminal: a kill path needs the whole list in
/// front of you before anything happens.
enum PanelState {
    case overview
    case checking
    case confirming([ReapProposal])
    case refused(String)
    case finished([(label: String, outcome: ReapOutcome)])
}

@MainActor
final class ResourceModel: ObservableObject {
    static let shared = ResourceModel()

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var rosterSource: Roster.Source = .unavailable
    @Published private(set) var ownCPUPercent: Double?
    @Published var state: PanelState = .overview

    private var ticker: Task<Void, Never>?
    private let collector = IncrementalCollector()
    private var previous: [ProcessSample] = []
    private var previousAt = Date()
    let interval: TimeInterval = 15

    /// The number Activity Monitor puts at the bottom of its window. A load average in
    /// the menu bar says nothing a developer can act on, and beside a row reading 115% it
    /// invites comparing two different denominators.
    var menuBarTitle: String {
        guard let cpu = snapshot?.systemCPU else { return "—" }
        return "\(Int(cpu.busyPercent.rounded()))%"
    }

    /// Amber once the machine is more than half committed, red when it is nearly full or
    /// the queue is longer than the core count.
    var menuBarSeverity: Color {
        guard let snapshot, let cpu = snapshot.systemCPU else { return .secondary }
        if cpu.busyPercent > 85 || snapshot.queuedThreads > Double(snapshot.machine.cpuCount) * 2 {
            return .red
        }
        if cpu.busyPercent > 55 { return .orange }
        return .primary
    }

    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(self?.interval ?? 15))
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        SamplerCoordinator.release()
    }

    // MARK: - starting with the machine

    /// Registered through `SMAppService`, so it appears in System Settings under Login
    /// Items and can be revoked there. A hand-written LaunchAgent would start the app just
    /// as well and would be invisible to anyone looking for what runs at login.
    var startsAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setStartsAtLogin(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemProblem = nil
        } catch {
            // Registration fails for a bundle macOS will not vouch for, which includes one
            // run out of a build directory. Saying so beats a toggle that silently
            // springs back.
            loginItemProblem = "\(error.localizedDescription). "
                + "Move ClaudeTop.app into /Applications and try again."
        }
        objectWillChange.send()
    }

    @Published var loginItemProblem: String?

    private func tick() async {
        // Paused while a confirmation is on screen. A list that changes under the cursor
        // is a list you cannot agree to.
        if case .confirming = state { return }

        let collected = await collect()
        guard let (snapshot, sample, cpu) = collected else { return }

        self.snapshot = snapshot
        self.rosterSource = sample.roster.source
        self.ownCPUPercent = cpu[getpid()]

        // Claimed before writing rather than at launch, so a crash between the two never
        // leaves a claim with no sampler behind it.
        try? SamplerCoordinator.claim(pid: getpid())
        if let store = try? ResourceStore(path: ResourceStore.defaultPath) {
            try? store.write(snapshot, processes: sample.processes, cpuPercents: cpu)
            try? store.writeBaseline(sample.processes, at: sample.processesReadAt)
            // The clock an unattended reap reads. Only meaningful when the roster was
            // actually read: recording from a failed read would start a clock on sessions
            // that are alive.
            if sample.roster.allowsReaping {
                try? store.recordOrphans(snapshot.orphans.map(\.key),
                                         at: sample.processesReadAt)
            }
        }
    }

    /// Sampling reads process environments and shells out to docker. On the main actor
    /// that would freeze the popover for seconds at a time.
    private func collect() async -> (Snapshot, RawSample, [Int32: Double])? {
        let baseline = previous
        let baselineAt = previousAt
        let collector = self.collector

        let result = await Task.detached(priority: .utility) {
            () -> (Snapshot, RawSample, [Int32: Double])? in
            let containers = ContainerCollector.current(timeout: 5)
            let roster = SessionRoster.live()
            let sample = collector.collect(containers: containers, roster: roster)
            let cpu = AttributionEngine.cpuPercents(
                earlier: baseline, earlierAt: baselineAt,
                later: sample.processes, laterAt: sample.processesReadAt)
            return (Sampler.attribute(sample, cpuPercents: cpu), sample, cpu)
        }.value

        if let result {
            previous = result.1.processes
            previousAt = result.1.processesReadAt
        }
        return result
    }

    // MARK: - stopping things

    /// Builds the list of what would be stopped, from readings taken now.
    ///
    /// Everything is re-read rather than reused from the last tick. Acting on a list
    /// fifteen seconds old means a session started since then looks abandoned, and a pid
    /// recycled since then points at something else entirely.
    func prepareReap(only key: AttributionKey? = nil) async {
        state = .checking
        guard let (snapshot, sample, _) = await collect() else {
            state = .refused("Could not read the machine just now. Nothing was stopped.")
            return
        }

        // A cached roster cannot tell "this session exited" from "this session was not
        // listed", and that difference decides whether live work lands on a kill list.
        guard sample.roster.allowsReaping else {
            state = .refused("The session list could not be read just now, so every live "
                             + "session would look abandoned. Nothing was stopped. Check "
                             + "that `claude agents --json` responds, then try again.")
            return
        }

        let keep = Reaper.keepMarkedWorktrees(in: sample)
        let candidates = key.map { wanted in snapshot.orphans.filter { $0.key == wanted } }
            ?? snapshot.orphans
        let proposals: [ReapProposal] = candidates.compactMap { group in
            let plan = AttributionEngine.reapPlan(
                for: group.key, processes: sample.processes,
                environments: sample.environments, containers: sample.containers,
                roster: sample.roster, keepMarkedWorktrees: keep)
            guard !plan.isEmpty else { return nil }
            return ReapProposal(plan: plan, label: group.label,
                                age: group.oldestProcessStartedAt.map {
                                    sample.machine.capturedAt.timeIntervalSince($0)
                                })
        }
        state = .confirming(proposals)
    }

    /// Acts on exactly the plans that were shown, never on a fresh reading. Nothing may
    /// join the list after it has been agreed to.
    func carryOut(_ proposals: [ReapProposal]) async {
        state = .checking
        let results = await Task.detached(priority: .userInitiated) {
            let reaper = Reaper()
            return proposals.map { (label: $0.label, outcome: reaper.execute($0.plan)) }
        }.value
        state = .finished(results)
    }
}

// MARK: - the popover

struct Panel: View {
    @ObservedObject var model: ResourceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .overview:   Overview(model: model)
            case .checking:   Busy()
            case .confirming(let proposals): Confirm(model: model, proposals: proposals)
            case .refused(let reason):       Message(title: "Nothing was stopped",
                                                     detail: reason, model: model)
            case .finished(let results):     Finished(results: results, model: model)
            }
        }
        .padding(12)
    }
}

struct Overview: View {
    @ObservedObject var model: ResourceModel

    var body: some View {
        if let snapshot = model.snapshot {
            MachineHeader(snapshot: snapshot)

            if case .cached(let age) = model.rosterSource {
                Note("Session list is \(Int(age))s old. Stopping is disabled until it refreshes.")
            } else if model.rosterSource == .unavailable {
                Note("Session list unavailable. Rows below may be live sessions.")
            }

            // Abandoned work comes first. It is the only thing on this panel you can act
            // on without costing anybody their session, which makes it the reason to open
            // the panel at all.
            if !snapshot.orphans.isEmpty {
                Divider()
                Abandoned(snapshot: snapshot, model: model)
            }

            Divider()
            Block("Sessions", snapshot.sessions, asOf: snapshot.machine.capturedAt)
            Block("Everything else", snapshot.everythingElse,
                  asOf: snapshot.machine.capturedAt)

            if !snapshot.containerGroups.isEmpty {
                DockerBlock(groups: snapshot.containerGroups)
            }
        } else {
            Text("Taking the first reading…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        }

        Divider()
        Footer(model: model)
    }
}

/// Worktrees whose session has exited, and what they are still holding.
struct Abandoned: View {
    let snapshot: Snapshot
    @ObservedObject var model: ResourceModel

    private var processes: Int { snapshot.orphans.reduce(0) { $0 + $1.pids.count } }
    private var containers: Int { snapshot.orphans.reduce(0) { $0 + $1.containerIDs.count } }
    private var memory: UInt64 { snapshot.orphans.reduce(0) { $0 + $1.rssBytes } }
    private var canStop: Bool { model.rosterSource == .live }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("ABANDONED").font(.caption2.bold()).foregroundStyle(.secondary)
                Text("no session is using these")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("\(processes)p · \(Renderer.formatBytes(memory))"
                     + (containers > 0 ? " · \(containers)c" : ""))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }

            // Oldest first. How long something has sat untouched is the strongest
            // argument for stopping it, stronger than any resource figure.
            ForEach(byAge, id: \.key) { group in
                AbandonedRow(group: group, snapshot: snapshot, canStop: canStop) {
                    Task { await model.prepareReap(only: group.key) }
                }
            }

            if canStop, snapshot.orphans.count > 1 {
                Button {
                    Task { await model.prepareReap() }
                } label: {
                    Text("Stop all \(processes) processes"
                         + (containers > 0 ? " and \(containers) containers" : "") + "…")
                }
                .controlSize(.small)
            }
        }
    }

    private var byAge: [AttributionGroup] {
        snapshot.orphans.sorted {
            ($0.oldestProcessStartedAt ?? .distantFuture)
                < ($1.oldestProcessStartedAt ?? .distantFuture)
        }
    }
}

struct AbandonedRow: View {
    let group: AttributionGroup
    let snapshot: Snapshot
    let canStop: Bool
    let stop: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(group.label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let started = group.oldestProcessStartedAt {
                    Text(Renderer.formatDuration(
                        snapshot.machine.capturedAt.timeIntervalSince(started)))
                        .foregroundStyle(.orange)
                }
                Text(holdings).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                if canStop {
                    Button("Stop", action: stop)
                        .controlSize(.mini)
                        .opacity(hovering ? 1 : 0.55)
                }
            }
            .font(.caption)

            // What it is, so stopping it is a decision rather than a leap. A worktree
            // holding a Postgres and four uvicorn workers is a different thing from one
            // holding a stalled shell.
            if let kinds = detail {
                Text("    \(kinds)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .onHover { hovering = $0 }
    }

    private var holdings: String {
        var parts: [String] = []
        if !group.pids.isEmpty { parts.append("\(group.pids.count)p") }
        if !group.containerIDs.isEmpty { parts.append("\(group.containerIDs.count)c") }
        if group.rssBytes > 0 { parts.append(Renderer.formatBytes(group.rssBytes)) }
        return parts.joined(separator: " · ")
    }

    private var detail: String? {
        let kinds = group.breakdown.prefix(3).map {
            $0.count > 1 ? "\($0.count)x \($0.name)" : $0.name
        }
        if kinds.isEmpty { return group.containerIDs.isEmpty ? nil : "containers only" }
        return kinds.joined(separator: ", ")
    }
}

struct MachineHeader: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The same lines the CLI prints, from one implementation, so the two cannot
            // drift into disagreeing about the machine.
            let lines = Renderer.headlines(snapshot)
            if let first = lines.first {
                Text(first).font(.title3.monospacedDigit())
            }
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(index == 0 ? .secondary : .tertiary)
            }
        }
    }
}

/// Green up to capacity, amber to twice it, red past that. Twice the core count is also
/// where the worker cap engages, so the colour and the guardrail agree.
func severity(_ oversubscription: Double) -> Color {
    if oversubscription > 2 { return .red }
    if oversubscription > 1 { return .orange }
    return .green
}

struct Block: View {
    let title: String
    let groups: [AttributionGroup]
    let asOf: Date
    var showAge = false

    init(_ title: String, _ groups: [AttributionGroup], asOf: Date, showAge: Bool = false) {
        self.title = title; self.groups = groups; self.asOf = asOf; self.showAge = showAge
    }

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                ForEach(groups.prefix(6), id: \.key) { group in
                    Row(group: group, asOf: asOf, showAge: showAge)
                }
                if groups.count > 6 {
                    Text("and \(groups.count - 6) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct Row: View {
    let group: AttributionGroup
    let asOf: Date
    let showAge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if showAge, let started = group.oldestProcessStartedAt {
                    Text(Renderer.formatDuration(asOf.timeIntervalSince(started)))
                        .foregroundStyle(.tertiary)
                }
                Text(group.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "?")
                    .monospacedDigit().frame(width: 46, alignment: .trailing)
                Text(Renderer.formatBytes(group.rssBytes))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.caption)

            // What a heavy group is made of, the same rule the terminal uses.
            ForEach(Array(Renderer.detailRows(for: group, limit: 2).enumerated()),
                    id: \.offset) { _, kind in
                Text("    └ \(kind.count > 1 ? "\(kind.count)x " : "")\(kind.name)  "
                     + (kind.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "?"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The prompt identifies a session that has no worktree to be named after. It is shown
    /// and never stored, the same line the terminal holds.
    private var label: String {
        guard let prompt = group.promptPreview, !group.label.contains("::") else {
            return group.label
        }
        return "\(group.label) \"\(prompt)\""
    }
}

struct DockerBlock: View {
    let groups: [ContainerGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DOCKER  ·  CPU IS INSIDE THE VM")
                .font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(groups.prefix(4), id: \.project) { group in
                HStack(spacing: 6) {
                    Text(group.project).lineLimit(1).truncationMode(.middle)
                    Text(group.label.isEmpty ? "unattributed" : group.label)
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    if group.isReapable {
                        Text("stoppable").font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 6)
                    Text(group.rssBytes.map(Renderer.formatBytes) ?? "?")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Text("\(group.containers.count)c")
                        .monospacedDigit().foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
    }
}

struct Confirm: View {
    @ObservedObject var model: ResourceModel
    let proposals: [ReapProposal]

    private var processes: Int { proposals.reduce(0) { $0 + $1.processCount } }
    private var containers: Int { proposals.reduce(0) { $0 + $1.containerCount } }

    var body: some View {
        if proposals.isEmpty {
            Message(title: "Nothing to stop",
                    detail: "No processes carry the stamp of a session that has exited, "
                          + "and no Compose project belongs to a worktree without one.",
                    model: model)
        } else {
            Text("Stop \(processes) processes"
                 + (containers > 0 ? " and \(containers) containers" : "")
                 + " across \(proposals.count) worktrees?")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(proposals.enumerated()), id: \.offset) { _, proposal in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(proposal.label).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let age = proposal.age {
                                    Text(Renderer.formatDuration(age))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.caption.bold())
                            Text("\(proposal.processCount) processes"
                                 + (proposal.containerCount > 0
                                    ? ", \(proposal.containerCount) containers" : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                            // A count is not a list. What is actually being signalled
                            // gets named.
                            ForEach(proposal.plan.processes.prefix(4), id: \.pid) { target in
                                Text("    \(target.pid)  \(target.command)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            ForEach(proposal.plan.containers.prefix(3), id: \.containerID) {
                                Text("    container \($0.name)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Text("SIGTERM, 5s, then escalate. Every signal is written to "
                 + "~/.claude/state/reap.log")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Button("Cancel") { model.state = .overview }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stop them") {
                    Task { await model.carryOut(proposals) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct Finished: View {
    let results: [(label: String, outcome: ReapOutcome)]
    @ObservedObject var model: ResourceModel

    private var survivors: [Int32] { results.flatMap(\.outcome.survived) }

    var body: some View {
        Text("Done").font(.headline)
        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
            Text("\(result.label): \(result.outcome.terminated.count) signalled"
                 + (result.outcome.killed.isEmpty ? ""
                    : ", \(result.outcome.killed.count) escalated")
                 + (result.outcome.containersStopped.isEmpty ? ""
                    : ", \(result.outcome.containersStopped.count) containers stopped"))
                .font(.caption)
        }
        if !survivors.isEmpty {
            // A process that ignored both signals is a fact, not something to round away
            // into a success message.
            Text("Survived both signals: "
                 + survivors.map(String.init).joined(separator: ", "))
                .font(.caption).foregroundStyle(.orange)
        }
        Button("Back") { model.state = .overview }
    }
}

struct Message: View {
    let title: String
    let detail: String
    @ObservedObject var model: ResourceModel

    var body: some View {
        Text(title).font(.headline)
        Text(detail).font(.caption).foregroundStyle(.secondary)
        Button("Back") { model.state = .overview }
    }
}

struct Busy: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading the machine…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.orange)
    }
}

struct Footer: View {
    @ObservedObject var model: ResourceModel

    var body: some View {
        if let problem = model.loginItemProblem {
            Text(problem).font(.caption2).foregroundStyle(.orange)
        }
        HStack {
            Text(cost).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Toggle("Start at login", isOn: Binding(
                get: { model.startsAtLogin },
                set: { model.setStartsAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.caption2)
            Button("Quit") {
                model.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
    }

    private var cost: String {
        let own = model.ownCPUPercent.map { "\(Int($0.rounded()))%" } ?? "?"
        return "claude-top \(own) cpu, every \(Int(model.interval))s"
    }
}
