import Foundation

/// One pass over the machine, before any attribution is applied.
public struct RawSample: Sendable {
    public let processes: [ProcessSample]
    /// When the process table was read, which is not when the sample finished: the shell
    /// calls that follow can take a second. CPU intervals are measured against this.
    public let processesReadAt: Date
    public let environments: [Int32: ProcessEnvironment]
    public let containers: [ContainerInfo]
    /// False when no docker answered in time. Kept apart from an empty `containers`,
    /// which is a real answer.
    public let dockerAnswered: Bool
    public let roster: Roster
    public let machine: MachineInfo

    public var sessions: [SessionInfo] { roster.sessions }

    public init(processes: [ProcessSample], processesReadAt: Date,
                environments: [Int32: ProcessEnvironment], containers: [ContainerInfo],
                dockerAnswered: Bool = true,
                roster: Roster, machine: MachineInfo) {
        self.processes = processes; self.processesReadAt = processesReadAt
        self.environments = environments; self.containers = containers
        self.dockerAnswered = dockerAnswered
        self.roster = roster; self.machine = machine
    }
}

/// Collecting from the live machine.
///
/// Every optional source is allowed to fail independently. No `docker` means no container
/// rows, no `claude` means an empty roster and everything reads as an orphan, and a
/// wedged either means the same. The snapshot is always produced.
public enum Sampler {

    public static func collect(timeout: TimeInterval = 3) -> RawSample {
        let pids = ProcessTable.listPIDs()
        let (environments, commands, arguments) = ProcessEnvironmentReader.read(pids: pids)

        // Read last among the process work and timestamped immediately, so the interval
        // the CPU percentages are divided by is the one the counters actually span.
        let processes = ProcessTable.current(commands: commands, arguments: arguments)
        let readAt = Date()

        let listing = ContainerCollector.current(timeout: timeout)
        return RawSample(
            processes: processes,
            processesReadAt: readAt,
            environments: environments,
            containers: listing.containers,
            dockerAnswered: listing.answered,
            roster: SessionRoster.live(),
            machine: MachineProbe.current(capturedAt: readAt, processCount: pids.count))
    }

    /// A self-contained reading: a cheap process-table pass, a pause, then a full sample.
    ///
    /// The pause is what buys a real interval percentage. Only the process table is read
    /// twice, because the environment, the roster and the container labels do not change
    /// meaningfully across 700 milliseconds and reading them twice would double the cost
    /// of the one thing on this machine that must stay cheap.
    public static func snapshot(separatedBy interval: TimeInterval = 0.7) -> Snapshot {
        let baseline = ProcessTable.current()
        let baselineAt = Date()
        let baselineTicks = MachineProbe.cpuTicks()

        Thread.sleep(forTimeInterval: interval)

        let sample = collect()
        let cpu = AttributionEngine.cpuPercents(
            earlier: baseline, earlierAt: baselineAt,
            later: sample.processes, laterAt: sample.processesReadAt)

        return attribute(sample, cpuPercents: cpu, previousTicks: baselineTicks)
    }

    /// `previousTicks` are the kernel's CPU counters from the last reading. With them the
    /// snapshot can state how much of the machine's work happened in processes this user
    /// may not inspect, which on a busy Mac is most of the difference between this tool's
    /// numbers and Activity Monitor's.
    public static func attribute(_ sample: RawSample, cpuPercents: [Int32: Double],
                                 previousTicks: CPUTicks? = nil) -> Snapshot {
        let snapshot = AttributionEngine.attribute(
            processes: sample.processes,
            environments: sample.environments,
            containers: sample.containers,
            sessions: sample.sessions,
            cpuPercents: cpuPercents,
            machine: sample.machine,
            dockerAnswered: sample.dockerAnswered)

        guard let previousTicks, let ticks = sample.machine.cpuTicks,
              let systemCPU = AttributionEngine.systemCPU(earlier: previousTicks,
                                                          later: ticks)
        else { return snapshot }

        return Snapshot(machine: snapshot.machine, groups: snapshot.groups,
                        containerGroups: snapshot.containerGroups, systemCPU: systemCPU,
                        dockerAnswered: snapshot.dockerAnswered)
    }
}
