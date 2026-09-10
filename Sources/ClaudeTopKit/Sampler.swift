import Foundation

/// One pass over the machine, before any attribution is applied.
public struct RawSample: Sendable {
    public let processes: [ProcessSample]
    /// When the process table was read, which is not when the sample finished: the shell
    /// calls that follow can take a second. CPU intervals are measured against this.
    public let processesReadAt: Date
    public let environments: [Int32: ProcessEnvironment]
    public let containers: [ContainerInfo]
    public let sessions: [SessionInfo]
    public let machine: MachineInfo

    public init(processes: [ProcessSample], processesReadAt: Date,
                environments: [Int32: ProcessEnvironment], containers: [ContainerInfo],
                sessions: [SessionInfo], machine: MachineInfo) {
        self.processes = processes; self.processesReadAt = processesReadAt
        self.environments = environments; self.containers = containers
        self.sessions = sessions; self.machine = machine
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
        let (environments, commands) = ProcessEnvironmentReader.read(pids: pids)

        // Read last among the process work and timestamped immediately, so the interval
        // the CPU percentages are divided by is the one the counters actually span.
        let processes = ProcessTable.current(commands: commands)
        let readAt = Date()

        return RawSample(
            processes: processes,
            processesReadAt: readAt,
            environments: environments,
            containers: ContainerCollector.current(timeout: timeout),
            sessions: SessionRoster.live(timeout: timeout),
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

        Thread.sleep(forTimeInterval: interval)

        let sample = collect()
        let cpu = AttributionEngine.cpuPercents(
            earlier: baseline, earlierAt: baselineAt,
            later: sample.processes, laterAt: sample.processesReadAt)

        return attribute(sample, cpuPercents: cpu)
    }

    public static func attribute(_ sample: RawSample, cpuPercents: [Int32: Double]) -> Snapshot {
        AttributionEngine.attribute(
            processes: sample.processes,
            environments: sample.environments,
            containers: sample.containers,
            sessions: sample.sessions,
            cpuPercents: cpuPercents,
            machine: sample.machine)
    }
}
