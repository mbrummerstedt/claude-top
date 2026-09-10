import Foundation
import Darwin
import ClaudeTopKit

/// Set from a signal handler, which may not capture context or allocate.
nonisolated(unsafe) private var interrupted = false

/// The full-screen live view.
///
/// The design notes argued against one: at load 55 the thing you open to diagnose the
/// problem should not be competing for the cores you are trying to free. That objection is
/// answered here rather than dismissed. A redraw re-reads only the process table, which is
/// the cheap half of a sample; environments are read once per process and kept, because a
/// process cannot change them after exec. The expensive shell-outs, `docker` and the
/// session roster, run on their own slower cycle, since the roster alone took nearly six
/// seconds on this machine at load 22. And the view prints what it costs, so the argument
/// can be settled by looking at it.
enum LiveView {

    static func run(interval: TimeInterval) {
        guard isatty(STDOUT_FILENO) == 1 else {
            // Piped or redirected. A stream of escape sequences into a file helps nobody.
            print(Renderer.text(Sampler.snapshot()))
            return
        }

        let originalTerminal = enterRawMode()
        enterAlternateScreen()
        defer {
            leaveAlternateScreen()
            if var original = originalTerminal { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        }

        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber) { _ in interrupted = true }
        }

        let collector = IncrementalCollector()
        let me = getpid()

        // The slow sources change on a human timescale, not a redraw one.
        let slowCycle = max(1, Int((15.0 / max(interval, 1)).rounded()))
        var tick = 0
        var containers: [ContainerInfo] = []
        var roster = Roster(sessions: [], source: .unavailable)

        // On screen before anything expensive happens. Load and memory are `sysctl`
        // calls and cost nothing; a full sample took twelve seconds on this machine at
        // load 89, and twelve seconds of blank screen reads as the tool being the problem.
        let firstSize = terminalSize()
        draw(Renderer.liveFrameCollecting(MachineProbe.current(),
                                          width: firstSize.columns, height: firstSize.rows))

        // A baseline before the first frame, so the opening view shows real percentages
        // rather than a screen of question marks.
        var previous = ProcessTable.current()
        var previousAt = Date()

        while !interrupted {
            if tick % slowCycle == 0 {
                containers = ContainerCollector.current(timeout: 3)
                roster = SessionRoster.live()
            }
            tick += 1

            let sample = collector.collect(containers: containers, roster: roster)
            let cpu = AttributionEngine.cpuPercents(
                earlier: previous, earlierAt: previousAt,
                later: sample.processes, laterAt: sample.processesReadAt)
            let snapshot = Sampler.attribute(sample, cpuPercents: cpu)

            let own = sample.processes.first { $0.pid == me }
            let status = LiveViewStatus(refreshInterval: interval,
                                        ownCPUPercent: cpu[me],
                                        ownRSSBytes: own?.rssBytes ?? 0,
                                        rosterSource: roster.source)

            let size = terminalSize()
            draw(Renderer.liveFrame(snapshot, width: size.columns, height: size.rows,
                                    status: status))

            previous = sample.processes
            previousAt = sample.processesReadAt

            if waitForQuit(upTo: interval) { break }
        }
    }

    // MARK: - drawing

    /// Home the cursor and overwrite, rather than clearing first. Clearing then painting
    /// shows an empty screen for one frame, which reads as a flicker on every redraw.
    private static func draw(_ frame: String) {
        var output = "\u{1B}[H"
        for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            output += line + "\u{1B}[K\r\n"
        }
        output += "\u{1B}[J"
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    private static func enterAlternateScreen() {
        // The alternate buffer, so quitting leaves the scrollback exactly as it was.
        FileHandle.standardOutput.write(Data("\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J".utf8))
    }

    private static func leaveAlternateScreen() {
        FileHandle.standardOutput.write(Data("\u{1B}[?25h\u{1B}[?1049l".utf8))
    }

    private static func terminalSize() -> (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return (columns: 80, rows: 24)
        }
        return (columns: Int(size.ws_col), rows: Int(size.ws_row))
    }

    // MARK: - input

    /// Raw mode so `q` arrives without a return key. The original settings are handed
    /// back to the caller to restore: a terminal left in raw mode outlives the process
    /// and makes the shell unusable.
    private static func enterRawMode() -> termios? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }

        var raw = original
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        // Polled rather than blocking: read returns immediately with whatever is there.
        withUnsafeMutableBytes(of: &raw.c_cc) { control in
            control[Int(VMIN)] = 0
            control[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
        return original
    }

    /// Sleep until the next redraw, unless a quit key arrives first. Returns true to stop.
    ///
    /// Polled in short slices rather than one long sleep so `q` feels immediate at a
    /// fifteen second refresh instead of taking up to fifteen seconds to register.
    private static func waitForQuit(upTo interval: TimeInterval) -> Bool {
        let slice = 0.05
        var waited = 0.0
        while waited < interval {
            if interrupted { return true }

            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) == 1 {
                // q, Q, Ctrl-C, or Escape.
                if byte == 0x71 || byte == 0x51 || byte == 0x03 || byte == 0x1B { return true }
            }
            Thread.sleep(forTimeInterval: slice)
            waited += slice
        }
        return false
    }
}
