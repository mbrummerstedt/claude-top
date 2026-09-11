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
        // Starts as "no answer yet" rather than "no containers": the first slow cycle has
        // not run, so nothing has been asked.
        var listing = ContainerCollector.Listing(containers: [], answered: false)
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
                listing = ContainerCollector.current(timeout: 3)
                roster = SessionRoster.live()
            }
            tick += 1

            let sample = collector.collect(containers: listing.containers,
                                           dockerAnswered: listing.answered,
                                           roster: roster)
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

            switch waitForKey(upTo: interval) {
            case .quit:
                return
            case .reap:
                if reap(collector: collector, interval: interval) { return }
            case .refresh:
                continue
            }
        }
    }

    // MARK: - reaping

    private enum Action { case quit, reap, refresh }

    /// The stop path. Returns true if the user quit out of it.
    ///
    /// Everything is re-read before anything is shown. Acting on the list from the last
    /// tick would mean a session started since then looks abandoned, and a pid recycled
    /// since then points at something else entirely. A fresh read costs a second and
    /// removes both.
    private static func reap(collector: IncrementalCollector, interval: TimeInterval) -> Bool {
        let size = terminalSize()
        draw(Renderer.reapRefusal("checking what can be stopped…",
                                  width: size.columns, height: size.rows))

        // The roster is what separates "this session exited" from "this session was not
        // listed", and only a reading from just now can tell them apart.
        let roster = SessionRoster.live()
        guard roster.allowsReaping else {
            draw(Renderer.reapRefusal(
                "The session list could not be read just now, so every live session would "
                + "look orphaned. Nothing was stopped. Check that `claude agents --json` "
                + "responds, then try again.",
                width: size.columns, height: size.rows))
            return waitForAnyKey() == .quit
        }

        let reapListing = ContainerCollector.current(timeout: 5)
        let sample = collector.collect(containers: reapListing.containers,
                                       dockerAnswered: reapListing.answered,
                                       roster: roster)
        let snapshot = Sampler.attribute(sample, cpuPercents: [:])
        let keep = Reaper.keepMarkedWorktrees(in: sample)

        let proposals: [ReapProposal] = snapshot.orphans.compactMap { group in
            let plan = AttributionEngine.reapPlan(
                for: group.key, processes: sample.processes,
                environments: sample.environments, containers: sample.containers,
                roster: roster, keepMarkedWorktrees: keep)
            guard !plan.isEmpty else { return nil }
            return ReapProposal(
                plan: plan, label: group.label,
                age: group.oldestProcessStartedAt.map {
                    sample.machine.capturedAt.timeIntervalSince($0)
                })
        }

        draw(Renderer.reapConfirmation(proposals, width: size.columns, height: size.rows))
        guard !proposals.isEmpty else { return waitForAnyKey() == .quit }

        // Anything other than an explicit yes is a no.
        let answer = waitForAnyKey()
        if answer == .quit { return true }
        guard answer == .confirm else { return false }

        // Exactly the plans that were shown. Nothing is rebuilt between reading and
        // acting, so nothing can join the list after it has been agreed to.
        let reaper = Reaper()
        let results = proposals.map {
            (label: $0.label, outcome: reaper.execute($0.plan))
        }
        draw(Renderer.reapOutcome(results, width: size.columns, height: size.rows))
        return waitForAnyKey() == .quit
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

    /// Sleep until the next redraw, unless a key arrives first.
    ///
    /// Polled in short slices rather than one long sleep so a keystroke feels immediate at
    /// a fifteen second refresh instead of taking up to fifteen seconds to register.
    private static func waitForKey(upTo interval: TimeInterval) -> Action {
        let slice = 0.05
        var waited = 0.0
        while waited < interval {
            if interrupted { return .quit }
            if let key = pressedKey() {
                switch key {
                case 0x71, 0x51, 0x03, 0x1B: return .quit   // q, Q, Ctrl-C, Escape
                case 0x72, 0x52: return .reap               // r, R
                default: return .refresh                    // anything else redraws now
                }
            }
            Thread.sleep(forTimeInterval: slice)
            waited += slice
        }
        return .refresh
    }

    private enum Answer { case confirm, dismiss, quit }

    /// Block until something is pressed. Used by the screens that are waiting on a person
    /// rather than on a clock.
    private static func waitForAnyKey() -> Answer {
        while !interrupted {
            if let key = pressedKey() {
                switch key {
                case 0x79, 0x59: return .confirm            // y, Y
                case 0x03: return .quit                     // Ctrl-C
                default: return .dismiss
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return .quit
    }

    private static func pressedKey() -> UInt8? {
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }
}
