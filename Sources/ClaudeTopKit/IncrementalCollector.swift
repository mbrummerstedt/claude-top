import Foundation

/// Sampling repeatedly without paying for it repeatedly.
///
/// A cold sample reads the environment of every process on the machine, six hundred
/// `sysctl` calls, and that is most of what a tick costs. A view that redraws every few
/// seconds cannot afford it: the monitor becomes part of the load it exists to report,
/// which is exactly the objection raised against a live view.
///
/// The saving is available because a process's environment and arguments are fixed at
/// exec and never change afterwards. Only processes that were not there last time are
/// worth reading, and on a steady machine that is almost none of them.
public final class IncrementalCollector {

    private let readTable: ([Int32: String], [Int32: [String]]) -> [ProcessSample]
    private let readEnvironments: ([Int32]) -> ([Int32: ProcessEnvironment],
                                                [Int32: String], [Int32: [String]])

    private var environments: [Int32: ProcessEnvironment] = [:]
    private var commands: [Int32: String] = [:]
    private var arguments: [Int32: [String]] = [:]
    /// What each cached pid was when it was read. A pid whose start time has moved is a
    /// different process wearing the same number.
    private var startTimes: [Int32: Date] = [:]

    public var cachedProcessCount: Int { environments.count }

    public init(
        readTable: @escaping ([Int32: String], [Int32: [String]]) -> [ProcessSample]
            = ProcessTable.current,
        readEnvironments: @escaping ([Int32]) -> ([Int32: ProcessEnvironment],
                                                  [Int32: String], [Int32: [String]])
            = { ProcessEnvironmentReader.read(pids: $0) }
    ) {
        self.readTable = readTable
        self.readEnvironments = readEnvironments
    }

    /// One tick. Containers and the roster are collected by the caller, since both are
    /// shell-outs with their own timeouts and their own reasons to be skipped.
    public func collect(containers: [ContainerInfo] = [], roster: Roster? = nil,
                        timeout: TimeInterval = 3) -> RawSample {
        // Cheap, and the only part that has to happen every tick.
        var table = readTable(commands, arguments)
        let readAt = Date()

        let unknown = table.filter { process in
            guard let seen = startTimes[process.pid] else { return true }
            // A second of tolerance, the same as everywhere else a start time is compared.
            return abs(seen.timeIntervalSince(process.startedAt)) >= 1
        }.map(\.pid)

        if !unknown.isEmpty {
            let (freshEnvironments, freshCommands, freshArguments) = readEnvironments(unknown)
            for pid in unknown {
                environments[pid] = freshEnvironments[pid]
                commands[pid] = freshCommands[pid]
                arguments[pid] = freshArguments[pid]
            }
            // The table was built with whatever commands were cached, so the ones just
            // read have to be put back into it.
            table = table.map { process in
                guard let command = freshCommands[process.pid] else { return process }
                return ProcessSample(pid: process.pid, ppid: process.ppid,
                                     rssBytes: process.rssBytes, cpuTime: process.cpuTime,
                                     startedAt: process.startedAt, command: command,
                                     arguments: freshArguments[process.pid] ?? [])
            }
        }

        // Forget what has exited. Otherwise the cache grows for as long as the view is
        // open, and a later process inheriting one of those pids finds a stale entry.
        let living = Set(table.map(\.pid))
        environments = environments.filter { living.contains($0.key) }
        commands = commands.filter { living.contains($0.key) }
        arguments = arguments.filter { living.contains($0.key) }
        startTimes = [:]
        for process in table { startTimes[process.pid] = process.startedAt }

        return RawSample(
            processes: table,
            processesReadAt: readAt,
            environments: environments,
            containers: containers,
            roster: roster ?? Roster(sessions: [], source: .unavailable),
            machine: MachineProbe.current(capturedAt: readAt, processCount: table.count))
    }
}
