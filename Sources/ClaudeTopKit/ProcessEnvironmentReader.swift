import Foundation
import Darwin

/// Reading another process's arguments and environment through `KERN_PROCARGS2`.
///
/// This is the mechanism the whole tool rests on. Claude Code exports
/// `CLAUDE_CODE_MESSAGING_SOCKET` into every process it spawns, and on macOS any
/// same-uid process's environment is readable, so attribution becomes a lookup instead of
/// a heuristic. Nothing has to cooperate and nothing has to be wrapped.
///
/// Only four variables are kept. A process environment routinely holds API keys, database
/// passwords and session tokens, and none of that is copied out of the buffer.
public enum ProcessEnvironmentReader {

    public static func read(pids: [Int32])
        -> (environments: [Int32: ProcessEnvironment], commands: [Int32: String],
            arguments: [Int32: [String]]) {
        var environments: [Int32: ProcessEnvironment] = [:]
        var commands: [Int32: String] = [:]
        var arguments: [Int32: [String]] = [:]

        // One buffer, reused across every process. The kernel's ceiling on this read is
        // a quarter of a megabyte, and allocating that once per process is most of the
        // cost of a sampler tick on a machine running six hundred of them.
        var buffer = [UInt8](repeating: 0, count: argumentMaximum)

        for pid in pids {
            // Processes exit between being listed and being read, constantly on a machine
            // running this many of them. That is not an error worth reporting.
            guard let raw = readRaw(pid: pid, into: &buffer) else { continue }

            if !raw.arguments.isEmpty {
                commands[pid] = raw.arguments.joined(separator: " ")
                arguments[pid] = raw.arguments
            }
            let environment = extract(pid: pid, environmentEntries: raw.environment)
            if environment.messagingSocket != nil || environment.pwd != nil
                || environment.hostSessionID != nil || environment.entrypoint != nil {
                environments[pid] = environment
            }
        }
        return (environments, commands, arguments)
    }

    /// Pull the four variables out of a raw `KEY=value` list and let the rest go.
    public static func extract(pid: Int32, environmentEntries: [String]) -> ProcessEnvironment {
        var socket: String?, hostSession: String?, entrypoint: String?, workingDirectory: String?

        for entry in environmentEntries {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let value = { String(entry[entry.index(after: equals)...]) }
            switch entry[entry.startIndex..<equals] {
            case "CLAUDE_CODE_MESSAGING_SOCKET": socket = value()
            case "CLAUDE_CODE_HOST_SESSION_ID": hostSession = value()
            case "CLAUDE_CODE_ENTRYPOINT": entrypoint = value()
            case "PWD": workingDirectory = value()
            default: continue
            }
        }

        return ProcessEnvironment(pid: pid, messagingSocket: socket, hostSessionID: hostSession,
                                  entrypoint: entrypoint, pwd: workingDirectory)
    }

    /// `KERN_PROCARGS2` hands back one buffer: an argument count, the executable path,
    /// padding, then `argc` argument strings, then the environment, all null-separated.
    static func readRaw(pid: Int32, into buffer: inout [UInt8])
        -> (arguments: [String], environment: [String])? {
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        // Fails for a process owned by another user, and for one that has already exited.
        // Both are ordinary and neither is worth a diagnostic.
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argc >= 0 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard cursor < size else { return nil }
            let start = cursor
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            let string = String(decoding: buffer[start..<cursor], as: UTF8.self)
            if cursor < size { cursor += 1 }
            return string
        }

        // The executable path, then however many nulls pad it out to alignment.
        _ = nextString()
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        for _ in 0..<Int(argc) {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }

        var environment: [String] = []
        while let entry = nextString() {
            if entry.isEmpty { continue }
            environment.append(entry)
        }

        return (arguments, environment)
    }

    /// `KERN_ARGMAX` is the kernel's own ceiling on this buffer, so one allocation of it
    /// is always enough and the read never has to be retried.
    private static let argumentMaximum: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 18 }
        return Int(value)
    }()
}
