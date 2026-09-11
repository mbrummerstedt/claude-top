import Foundation
import Darwin

/// The kernel's own CPU counters, the ones Activity Monitor and `top` read.
public struct CPUTicks: Sendable, Equatable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    public var total: UInt64 { user &+ system &+ idle &+ nice }
}

/// How busy the whole machine was, in the units Activity Monitor uses.
public struct SystemCPU: Sendable, Equatable {
    /// Percent of the whole machine, 0 to 100. `20.66% user` in Activity Monitor is 20.66
    /// here, whatever the core count.
    public let userPercent: Double
    public let systemPercent: Double

    public init(userPercent: Double, systemPercent: Double) {
        self.userPercent = userPercent; self.systemPercent = systemPercent
    }

    public var busyPercent: Double { userPercent + systemPercent }
    public var idlePercent: Double { max(0, 100 - busyPercent) }

    /// The same figure in the per-core units the group rows use, where a process on two
    /// cores reads 200%. Without this the machine total and the rows cannot be compared.
    public func busyPerCore(cpuCount: Int) -> Double { busyPercent * Double(cpuCount) }
}

extension AttributionEngine {

    /// What the machine was doing between two readings of the kernel's counters.
    ///
    /// Returns nil rather than zero when nothing elapsed or the counters moved backwards.
    /// Zero would claim an idle machine, which is a different statement from not knowing.
    public static func systemCPU(earlier: CPUTicks, later: CPUTicks) -> SystemCPU? {
        guard later.user >= earlier.user, later.system >= earlier.system,
              later.idle >= earlier.idle, later.nice >= earlier.nice
        else { return nil }

        let elapsed = Double(later.total - earlier.total)
        guard elapsed > 0 else { return nil }

        // Nice time is time the machine spent working, whatever priority it was at.
        let user = Double((later.user - earlier.user) + (later.nice - earlier.nice))
        let system = Double(later.system - earlier.system)
        return SystemCPU(userPercent: user / elapsed * 100,
                         systemPercent: system / elapsed * 100)
    }
}

extension MachineProbe {

    /// Host-wide CPU ticks. The same source `top` reads, so the two agree by construction
    /// rather than by coincidence.
    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }
}
