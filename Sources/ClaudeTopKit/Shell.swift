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

        do { try process.run() } catch { return nil }

        let collected = Box()
        let finished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "claude-top.shell", attributes: .concurrent)

        queue.async {
            collected.set(stdout.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
            finished.signal()
        }
        // Drained but discarded. An undrained stderr pipe fills at 64 KB and blocks the
        // child forever, which would turn a diagnostic into the hang it was meant to warn
        // about.
        queue.async { _ = stderr.fileHandleForReading.readDataToEndOfFile() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + graceAfterTerminate) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + graceAfterTerminate)
            }
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        return String(data: collected.get(), encoding: .utf8)
    }

    /// Matches the escalation used when reaping: signal, wait, and only then insist.
    private static let graceAfterTerminate: TimeInterval = 2

    /// First match in the directories a GUI or launchd process actually sees. `PATH` is
    /// not consulted first because the sampler runs under launchd, which does not inherit
    /// the interactive shell's `PATH`, and this machine has pyenv shims early in it.
    public static func locate(_ name: String, extraDirectories: [String] = []) -> String? {
        var directories = extraDirectories
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }
}
