import Testing
import Foundation
@testable import ClaudeTopKit

/// The screen between a keystroke and a signal.
///
/// A kill path behind a single key needs the whole list in front of you first. What is
/// rendered here is exactly what gets signalled: the plan is built once, shown, and acted
/// on, never rebuilt in between, so nothing can join the list after you have read it.
@Suite("Reap confirmation")
struct ReapConfirmationTests {

    private func proposal(_ label: String, processes: Int, containers: Int = 0,
                          age: TimeInterval? = 86400) -> ReapProposal {
        ReapProposal(
            plan: ReapPlan(
                key: .orphan(repo: "r", worktree: label),
                processes: (0..<processes).map {
                    ReapTarget(pid: Int32(100 + $0), command: "/usr/bin/node worker\($0)",
                               reason: "stamp names session 100")
                },
                containers: (0..<containers).map {
                    ReapComposeTarget(containerID: "c\($0)", name: "\(label)-db-\($0)",
                                      workingDirectory: "/tmp", reason: "compose working_dir")
                }),
            label: label, age: age)
    }

    private func screen(_ proposals: [ReapProposal], width: Int = 90,
                        height: Int = 30) -> String {
        Renderer.reapConfirmation(proposals, width: width, height: height)
    }

    @Test("Every group that would be stopped is named, with what it holds")
    func namesEveryGroup() {
        let text = screen([proposal("r::alpha", processes: 18),
                           proposal("r::beta", processes: 0, containers: 3)])
        #expect(text.contains("r::alpha"))
        #expect(text.contains("r::beta"))
        #expect(text.contains("18"))
        #expect(text.contains("3"))
    }

    @Test("The total is stated, so the number is never only implied by a list")
    func statesTheTotal() {
        let text = screen([proposal("r::alpha", processes: 18, containers: 1),
                           proposal("r::beta", processes: 23, containers: 2)])
        #expect(text.contains("41"))
        #expect(text.contains("3"))
    }

    @Test("It says how things will be signalled, before you agree to it")
    func statesTheMethod() {
        // SIGTERM, wait, then escalate. Someone about to press a key should know that a
        // Postgres gets a chance to close cleanly, and that this is written down.
        let text = screen([proposal("r::alpha", processes: 2)])
        #expect(text.contains("SIGTERM"))
        #expect(text.lowercased().contains("reap.log"))
    }

    @Test("Confirming is an explicit key and anything else cancels")
    func confirmIsExplicit() {
        let text = screen([proposal("r::alpha", processes: 2)])
        #expect(text.lowercased().contains("cancel"))
    }

    @Test("How long each group has been abandoned is shown")
    func showsAge() {
        // The strongest argument for stopping something: nothing has touched it in a day.
        #expect(screen([proposal("r::alpha", processes: 4, age: 86400)]).contains("1d"))
    }

    @Test("Individual processes are listed, because a count is not a list")
    func listsProcesses() {
        let text = screen([proposal("r::alpha", processes: 3)])
        #expect(text.contains("100"))
        #expect(text.contains("worker0"))
    }

    @Test("A list too long for the screen still states the totals")
    func longListKeepsTotals() {
        // The count is the thing you cannot afford to lose to truncation.
        let many = (0..<12).map { proposal("r::group\($0)", processes: 9) }
        let text = screen(many, height: 20)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count <= 20)
        #expect(lines.allSatisfy { $0.count <= 90 })
        #expect(text.contains("108"), "the total survived truncation")
    }

    @Test("Nothing to stop says so rather than showing an empty confirmation")
    func nothingToStop() {
        #expect(screen([]).lowercased().contains("nothing"))
    }

    @Test("A refusal names the reason rather than looking like an empty result")
    func refusalIsExplained() {
        // The roster failing is the one case that must never read as "all clear".
        let text = Renderer.reapRefusal(
            "the session list could not be read, so live sessions would look abandoned",
            width: 80, height: 24)
        #expect(text.lowercased().contains("could not be read"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count <= 24)
        #expect(lines.allSatisfy { $0.count <= 80 })
    }

    @Test("The outcome reports what actually happened, including what survived")
    func outcomeIsHonest() {
        // A process that ignored both signals is a fact worth printing, not one to round
        // away into a success message.
        let text = Renderer.reapOutcome(
            [(label: "r::alpha",
              outcome: ReapOutcome(terminated: [1, 2, 3], killed: [3], survived: [9],
                                   containersStopped: ["c0"]))],
            width: 80, height: 24)
        #expect(text.contains("3"))
        #expect(text.lowercased().contains("escalat") || text.contains("SIGKILL"))
        #expect(text.contains("9"), "a process that survived must be named")
    }

    @Test("An outcome with nothing left behind does not invent a warning")
    func cleanOutcome() {
        let text = Renderer.reapOutcome(
            [(label: "r::alpha",
              outcome: ReapOutcome(terminated: [1, 2], killed: [], survived: [],
                                   containersStopped: []))],
            width: 80, height: 24)
        #expect(!text.lowercased().contains("survived"))
    }
}
