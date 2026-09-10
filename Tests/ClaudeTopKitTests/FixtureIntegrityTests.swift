import Testing
import Foundation
@testable import ClaudeTopKit

/// These tests do not exercise the engine. They pin down what the reference capture
/// contains, so that the engine tests written against it are anchored to real numbers
/// and so that a re-capture that silently loses a case fails loudly.
///
/// The reference capture is a machine running 14 concurrent Claude Code sessions, taken
/// deliberately while it was struggling. Its value is the awkward cases: sessions that
/// died leaving children behind, containers across all three attribution tiers, and a
/// test-runner worker pool saturating every core.
@Suite("Reference fixture integrity")
struct FixtureIntegrityTests {

    @Test("Machine is the 16 GB / 10-core reference laptop under load")
    func machine() throws {
        let m = try Fixture.machine()
        #expect(m.cpuCount == 10)
        #expect(m.memTotalBytes == 17_179_869_184)
        // Captured at load 37.9. An earlier reading in the same session peaked at 55.6;
        // the fixture holds the lower of the two, which is still ~3.8x oversubscribed.
        #expect(m.loadAverage1 > 30)
        #expect(m.loadAverage1 / Double(m.cpuCount) > 3)
    }

    @Test("Process table parses and carries usable CPU time")
    func processTable() throws {
        let procs = try Fixture.processes()
        #expect(procs.count == 662)
        #expect(procs.allSatisfy { $0.cpuTime >= 0 })
        #expect(procs.contains { $0.pid == 1 })          // launchd
        #expect(procs.contains { $0.cpuTime > 60 })      // something long-running
    }

    @Test("44 processes carry a session stamp across 10 distinct sessions")
    func envStamps() throws {
        let envs = try Fixture.environments()
        let stamped = envs.values.filter { $0.spawningSessionPID != nil }
        #expect(stamped.count == 44)
        #expect(Set(stamped.compactMap(\.spawningSessionPID)).count == 10)

        // Six more processes carry no stamp but do have a worktree PWD. They are the
        // reason tier 3 exists: re-exec'd watchers lose the environment but keep the cwd.
        let pwdOnly = envs.values.filter {
            $0.spawningSessionPID == nil && ($0.pwd?.contains(".claude/worktrees/") ?? false)
        }
        #expect(pwdOnly.count == 6)
    }

    @Test("Stamps survive session death: dead sessions still have live children")
    func orphanedStampsExist() throws {
        let envs = try Fixture.environments()
        let live = Set(try Fixture.sessions().map(\.pid))
        let stampedSessionPIDs = Set(envs.values.compactMap(\.spawningSessionPID))
        let dead = stampedSessionPIDs.subtracting(live)

        // This is the case the whole tool exists for. Children of these sessions were
        // still running, some for 22 hours, with no live parent anywhere on the machine.
        #expect(dead.count == 5, "expected 5 dead sessions with surviving children")

        let orphanedProcs = envs.values.filter {
            guard let s = $0.spawningSessionPID else { return false }
            return dead.contains(s)
        }
        #expect(orphanedProcs.count == 27)
    }

    @Test("ps %cpu is a lifetime average and disagrees with reality")
    func psPercentIsNotRankable() throws {
        let procs = try Fixture.processes()
        // Sum of ps %cpu across all processes wildly exceeds what the load average and
        // core count allow, because each value is averaged over a different lifetime.
        // Recorded here so the reason for diffing cumulative CPU time is not forgotten.
        let total = procs.reduce(0.0) { $0 + $1.psPercentCPU }
        let m = try Fixture.machine()
        #expect(total > 0)
        #expect(abs(total - m.loadAverage1 * 100) > 100)
    }

    @Test("Sessions roster parses and carries no prompt text")
    func sessions() throws {
        let sessions = try Fixture.sessions()
        #expect(sessions.count >= 10)
        #expect(sessions.allSatisfy { !$0.sessionID.isEmpty })
        // The `name` field is the user's opening prompt and must never reach a fixture.
        let raw = try Fixture.text("agents.json")
        #expect(!raw.contains("\"name\""))
    }

    @Test("Containers span all three attribution tiers")
    func containerTiers() throws {
        let containers = try Fixture.containers()
        #expect(containers.count == 13)

        let compose = containers.filter { $0.composeWorkingDir != nil }
        #expect(compose.count == 7)
        #expect(compose.allSatisfy { $0.composeWorkingDir!.contains(".claude/worktrees/") })

        let testcontainers = containers.filter { $0.labels["org.testcontainers"] == "true" }
        #expect(testcontainers.count == 5)
        let clusters = Set(testcontainers.compactMap(\.testcontainersSessionID))
        #expect(clusters.count == 3)
        #expect(testcontainers.filter(\.isTestcontainersReaper).count == 2)

        // One container has no labels at all, started by a bare `docker run --name`.
        // It must land in `unattributed` and must never be eligible for reaping.
        let bare = containers.filter { $0.labels.isEmpty }
        #expect(bare.count == 1)
        #expect(bare.first?.name == "sp-chatroom-pg")
    }

    @Test("Container name embedding a worktree hash is still attributed by label")
    func attributeByLabelNotName() throws {
        let c = try #require(try Fixture.containers()
            .first { $0.name == "account-deletion-d7fb2e-db-1" })
        // The name happens to contain the worktree hash. That is a coincidence of how the
        // compose project was named, not a contract. Attribution must come from the label.
        let dir = try #require(c.composeWorkingDir)
        #expect(dir.hasSuffix("/.claude/worktrees/account-deletion-d7fb2e"))
    }

    @Test("Fixture contains no secret-shaped content")
    func noSecrets() throws {
        let pattern = try NSRegularExpression(
            pattern: "(^|[^A-Za-z0-9-])(sk-[A-Za-z0-9]{16}|ghp_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16})|BEGIN [A-Z ]*PRIVATE KEY")
        for file in ["ps.txt", "procenv.txt", "agents.json", "docker-labels.jsonl", "machine.txt"] {
            let s = try Fixture.text(file)
            let hits = pattern.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
            #expect(hits == 0, "secret-shaped content in \(file)")
        }
    }
}
