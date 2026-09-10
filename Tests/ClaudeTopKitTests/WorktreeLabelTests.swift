import Testing
@testable import ClaudeTopKit

/// `worktreeLabel` is what makes a dead session's leftovers line up visually with the
/// session that spawned them: both sides of the output derive their label the same way,
/// from a path. Getting it wrong means an orphan group that reads as unrelated to the
/// worktree it came from.
@Suite("Worktree labels")
struct WorktreeLabelTests {

    @Test("A worktree path becomes repo::worktree")
    func worktreePath() {
        #expect(AttributionEngine.worktreeLabel(
            forPath: "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page-63c477")
            == "reader-app::terms-page")
    }

    @Test("A path inside a worktree still names the worktree, not the subdirectory")
    func pathInsideWorktree() {
        // Captured PWDs are frequently deep: a vitest worker sits in apps/web, and a
        // uvicorn in apps/api. All of them belong to the same session.
        #expect(AttributionEngine.worktreeLabel(
            forPath: "/Users/USER/git_repositories/platform/.claude/worktrees/qa-testing-a538f6/apps/web")
            == "platform::qa-testing")
    }

    @Test("The worktree hash suffix is dropped for display")
    func hashSuffixDropped() {
        // Six hex characters appended by the worktree tooling. They disambiguate the
        // directory, not the work, and they cost the column width the command needs.
        #expect(AttributionEngine.worktreeLabel(
            forPath: "/Users/USER/git_repositories/reader-app/.claude/worktrees/admiring-fermat-3aa813")
            == "reader-app::admiring-fermat")
    }

    @Test("A suffix that is not six hex characters is kept")
    func nonHashSuffixKept() {
        // `-page` is part of the name. Stripping any trailing token would corrupt it.
        #expect(AttributionEngine.worktreeLabel(
            forPath: "/Users/USER/git_repositories/reader-app/.claude/worktrees/terms-page")
            == "reader-app::terms-page")
        #expect(AttributionEngine.worktreeLabel(
            forPath: "/Users/USER/git_repositories/reader-app/.claude/worktrees/fix-12345")
            == "reader-app::fix-12345")
    }

    @Test("A plain repository checkout is labelled by its directory name")
    func plainCheckout() {
        #expect(AttributionEngine.worktreeLabel(forPath: "/Users/USER/git_repositories/claude-top")
            == "claude-top")
    }

    @Test("A path with no worktree segment falls back to its basename")
    func fallbackToBasename() {
        #expect(AttributionEngine.worktreeLabel(forPath: "/Users/USER") == "USER")
        #expect(AttributionEngine.worktreeLabel(forPath: "/opt/homebrew/bin") == "bin")
    }

    @Test("Trailing slashes do not change the label")
    func trailingSlash() {
        #expect(AttributionEngine.worktreeLabel(
            forPath: "/Users/USER/git_repositories/tradebot/.claude/worktrees/flow-testing-670e04/")
            == "tradebot::flow-testing")
    }

    @Test("A path that names nothing yields nil")
    func nothingToLabel() {
        #expect(AttributionEngine.worktreeLabel(forPath: "") == nil)
        #expect(AttributionEngine.worktreeLabel(forPath: "/") == nil)
    }

    @Test("Every worktree path in the reference fixture produces a label")
    func everyFixturePathLabels() throws {
        let paths = try Fixture.environments().values
            .compactMap(\.pwd)
            .filter { $0.contains("/.claude/worktrees/") }
        #expect(!paths.isEmpty)
        for p in paths {
            let label = AttributionEngine.worktreeLabel(forPath: p)
            #expect(label?.contains("::") == true, "no repo::worktree label for \(p)")
        }
    }
}
