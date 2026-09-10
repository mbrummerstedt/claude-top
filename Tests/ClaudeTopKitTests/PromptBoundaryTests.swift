import Testing
import Foundation
@testable import ClaudeTopKit

/// The opening prompt is the user's own words. It earns its place in the terminal table,
/// where it is the only thing that tells two home-directory sessions apart, and it is
/// allowed nowhere else: not the database, not `--json`, not the reap log, not a fixture.
///
/// A comment saying so is not a guarantee. These tests are.
@Suite("Prompt boundary")
struct PromptBoundaryTests {

    private let secret = "migrate the billing schema before the audit"

    private func snapshotCarryingAPrompt() -> Snapshot {
        let session = SessionInfo(pid: 100, cwd: "/Users/USER", sessionID: "uuid-a",
                                  startedAt: Date(timeIntervalSince1970: 1_757_500_000),
                                  promptPreview: secret)
        return AttributionEngine.attribute(
            processes: [ProcessSample(pid: 500, ppid: 1, rssBytes: 1024, cpuTime: 1,
                                      startedAt: Date(timeIntervalSince1970: 1_757_499_000),
                                      command: "/usr/bin/node")],
            environments: [500: ProcessEnvironment(pid: 500,
                                                   messagingSocket: "/tmp/cc-socks/100.sock",
                                                   hostSessionID: nil, entrypoint: nil,
                                                   pwd: "/Users/USER")],
            containers: [], sessions: [session],
            cpuPercents: [500: 91],
            machine: MachineInfo(cpuCount: 10, memTotalBytes: 17_179_869_184,
                                 memUsedBytes: 1_073_741_824, loadAverage1: 5,
                                 capturedAt: Date(timeIntervalSince1970: 1_757_500_000),
                                 homeDirectory: "/Users/USER", processCount: 1))
    }

    @Test("The terminal table shows the prompt, which is the whole point of carrying it")
    func terminalShowsIt() {
        #expect(Renderer.text(snapshotCarryingAPrompt()).contains(secret))
    }

    @Test("A session named after a worktree keeps the worktree name")
    func worktreeNameWins() {
        // The name the person chose for the work beats the sentence they opened with.
        let session = SessionInfo(
            pid: 100,
            cwd: "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page-63c477",
            sessionID: "uuid-a", startedAt: Date(), promptPreview: secret)
        let snapshot = AttributionEngine.attribute(
            processes: [ProcessSample(pid: 100, ppid: 1, rssBytes: 1024, cpuTime: 1,
                                      startedAt: Date(), command: "claude")],
            environments: [:], containers: [], sessions: [session], cpuPercents: [100: 1],
            machine: MachineInfo(cpuCount: 10, memTotalBytes: 1, loadAverage1: 1,
                                 capturedAt: Date(), homeDirectory: "/Users/USER"))
        let text = Renderer.text(snapshot)
        #expect(text.contains("reader-app::terms-page"))
        #expect(!text.contains(secret))
    }

    @Test("The prompt never reaches --json")
    func jsonNeverCarriesIt() {
        // --json is what hooks, agents and scripts consume, and anything consuming it may
        // write it somewhere this tool cannot see.
        #expect(!Renderer.json(snapshotCarryingAPrompt()).contains(secret))
    }

    @Test("The prompt never reaches the group label, because the label is stored")
    func labelNeverCarriesIt() {
        #expect(snapshotCarryingAPrompt().groups.allSatisfy { !$0.label.contains(secret) })
    }

    @Test("The prompt never reaches the database")
    func databaseNeverCarriesIt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-prompt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("resources.db")
        let store = try ResourceStore(path: path.path)
        try store.write(snapshotCarryingAPrompt())

        // Read what is actually on disk, rather than what the reader chose to return.
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(file))
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(!text.contains(secret), "the prompt was written to \(file)")
        }
    }

    @Test("The prompt never reaches the reap log")
    func reapLogNeverCarriesIt() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-top-prompt-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }

        let reaper = Reaper(signaller: { _, _ in true }, isAlive: { _ in false },
                            stopContainer: { _ in true }, logURL: log)
        _ = reaper.execute(
            ReapPlan(key: .session(uuid: "uuid-a"),
                     processes: [ReapTarget(pid: 500, command: "/usr/bin/node",
                                            reason: "stamp names session 100")],
                     containers: []),
            sleeper: { _ in })

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(!contents.contains(secret))
    }

    @Test("A prompt is flattened and cut short before it is shown at all")
    func previewIsTrimmed() {
        // A prompt can be a paragraph. The table has one row per session.
        let sprawling = "first line\nsecond line\n" + String(repeating: "x", count: 200)
        let preview = SessionRoster.preview(of: sprawling)
        #expect(preview?.contains("\n") == false)
        #expect((preview?.count ?? 0) <= 48)
        #expect(SessionRoster.preview(of: "   ") == nil)
        #expect(SessionRoster.preview(of: nil) == nil)
    }

    @Test("The reference fixture still carries no prompt at all")
    func fixtureStillClean() throws {
        // Capture strips it before anything is written. The roster type being able to
        // carry one must not change that.
        #expect(!(try Fixture.text("agents.json")).contains("\"name\""))
        #expect(try Fixture.sessions().allSatisfy { $0.promptPreview == nil })
    }
}
