import Foundation

/// Running an external command with a deadline.
///
/// Every shell-out in this project is optional and every one of them has a timeout.
/// `docker stats` returned dashes for every column during the reference capture, and a
/// sampler tick that blocks on a wedged docker is worse than a tick that reports unknown:
/// the tool exists to be usable at the moment the machine is already struggling.
public enum Shell {

    /// Output on success, nil on failure, a non-zero exit, a missing binary, or a timeout.
    /// The caller cannot tell those apart on purpose. All four mean the same thing here,
    /// which is that this tier has nothing to contribute to the snapshot.
    public static func run(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Signalled from the termination handler rather than from a thread parked in
        // waitUntilExit, and the pipes are drained on threads of their own rather than on
        // the shared dispatch pool. Borrowing pool threads here is what made this hang:
        // under parallel test execution every concurrent shell-out wanted two of them, a
        // machine with few cores ran out, and `/bin/echo hello` took thirteen seconds to
        // report a timeout it never actually had.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do { try process.run() } catch { return nil }

        let collected = Box()
        let outputDrained = DispatchSemaphore(value: 0)

        let outputReader = Thread {
            collected.set(stdout.fileHandleForReading.readDataToEndOfFile())
            outputDrained.signal()
        }
        outputReader.stackSize = 512 * 1024
        outputReader.start()

        // Drained and discarded. An undrained stderr pipe fills at 64 KB and blocks the
        // child forever, which would turn a diagnostic into the hang it was meant to warn
        // about.
        let errorReader = Thread { _ = stderr.fileHandleForReading.readDataToEndOfFile() }
        errorReader.stackSize = 512 * 1024
        errorReader.start()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + graceAfterTerminate) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + graceAfterTerminate)
            }
            _ = outputDrained.wait(timeout: .now() + graceAfterTerminate)
            return nil
        }

        // The child has exited, so its end of the pipe is closed and the reader reaches
        // EOF. Waiting on that is what makes the output complete rather than whatever had
        // arrived by the time the process died.
        guard outputDrained.wait(timeout: .now() + graceAfterTerminate) == .success,
              process.terminationStatus == 0
        else { return nil }

        return String(data: collected.get(), encoding: .utf8)
    }

    /// Matches the escalation used when reaping: signal, wait, and only then insist.
    private static let graceAfterTerminate: TimeInterval = 2

    /// Every place a tool might be installed, in the order worth trying.
    ///
    /// All of them, not the first one that exists, because more than one can be installed
    /// at once and the first is not necessarily the one that works. A Mac can carry both
    /// a Homebrew `claude` and a newer `/usr/local/bin` one, and the older of the two
    /// answers `agents --json` with "unknown option" rather than with sessions. A caller
    /// works down this list until something actually answers.
    ///
    /// `PATH` comes first because it is what the person's own shell resolves, then the
    /// fixed directories, which is what a launchd job sees: launchd inherits no
    /// interactive `PATH` at all.
    public static func locateAll(_ name: String, extraDirectories: [String] = []) -> [String] {
        var directories: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        directories += extraDirectories
        directories += ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]

        var found: [String] = []
        var seen: Set<String> = []
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            // Deduplicated by where the symlink actually points, so the same install
            // reached through three different paths is only tried once.
            let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate))
                .map { $0.hasPrefix("/") ? $0 : (directory as NSString).appendingPathComponent($0) }
                ?? candidate
            let identity = (resolved as NSString).standardizingPath
            if seen.insert(identity).inserted { found.append(candidate) }
        }
        return found
    }

    public static func locate(_ name: String, extraDirectories: [String] = []) -> String? {
        locateAll(name, extraDirectories: extraDirectories).first
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }
}
