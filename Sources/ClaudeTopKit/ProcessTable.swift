import Foundation
import Darwin

/// The process table, read in-process through `libproc`.
///
/// Shelling out to `ps eww` once per PID is what the fixture-capture script does and it
/// takes seconds for 600 processes. At a fifteen-second sampling interval that is not
/// viable, and a monitor that is itself a load is self-defeating.
public enum ProcessTable {

    /// Cumulative CPU time is the field that matters. `ps` reports `%cpu` averaged over a
    /// process's whole life, so a session that finished a test run an hour ago outranks
    /// the one currently saturating a core. Interval percentages come from diffing this.
    public static func current(commands: [Int32: String] = [:]) -> [ProcessSample] {
        listPIDs().compactMap { pid in
            var info = proc_taskallinfo()
            let wanted = Int32(MemoryLayout<proc_taskallinfo>.size)
            let read = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, wanted)
            // Short reads mean the process exited mid-listing, which happens constantly.
            guard read == wanted else { return nil }

            let nanoseconds = Double(info.ptinfo.pti_total_user) + Double(info.ptinfo.pti_total_system)
            let started = Double(info.pbsd.pbi_start_tvsec)
                + Double(info.pbsd.pbi_start_tvusec) / 1_000_000

            return ProcessSample(
                pid: pid,
                ppid: Int32(bitPattern: info.pbsd.pbi_ppid),
                rssBytes: info.ptinfo.pti_resident_size,
                cpuTime: nanoseconds / 1_000_000_000,
                startedAt: Date(timeIntervalSince1970: started),
                command: commands[pid] ?? executablePath(of: pid) ?? processName(of: info))
        }
    }

    public static func listPIDs() -> [Int32] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }

        // Headroom, because processes start between sizing the buffer and filling it.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 128)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                    Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// The true executable path, which is what decides a system family. It is used only
    /// when the arguments could not be read, since `argv` reads better in output.
    static func executablePath(of pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro and does not reach Swift; it is
        // 4 * MAXPATHLEN, which libproc will not exceed.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Last resort. Truncated to sixteen characters by the kernel, but a short name beats
    /// a blank row: the process still counts toward the machine's totals.
    private static func processName(of info: proc_taskallinfo) -> String {
        withUnsafeBytes(of: info.pbsd.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Load average, core count and installed memory.
public enum MachineProbe {

    public static func current(capturedAt: Date = Date(), processCount: Int = 0) -> MachineInfo {
        var loads = [Double](repeating: 0, count: 3)
        let load = getloadavg(&loads, 3) > 0 ? loads[0] : 0

        return MachineInfo(
            cpuCount: sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            memTotalBytes: UInt64(sysctlInt("hw.memsize") ?? 0),
            memUsedBytes: usedMemory(),
            loadAverage1: load,
            capturedAt: capturedAt,
            homeDirectory: NSHomeDirectory(),
            processCount: processCount)
    }

    /// Active, wired and compressed pages. Not free memory: macOS keeps very little of
    /// that by design, and reporting it would make every machine look full.
    private static func usedMemory() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }

        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        return pages * UInt64(pageSize)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
