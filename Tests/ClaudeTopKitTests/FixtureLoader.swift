import Foundation
import ClaudeTopKit

/// Loads the sanitized machine captures in `Tests/Fixtures/`.
///
/// Located relative to `#filePath` rather than bundled as an SPM resource, because SPM
/// will not accept a resource path outside the target's own directory and the fixtures
/// are shared.
enum Fixture {
    static let referenceName = "load55-2026-09-10"

    static var root: URL {
        URL(fileURLWithPath: #filePath)      // Tests/ClaudeTopKitTests/FixtureLoader.swift
            .deletingLastPathComponent()      // Tests/ClaudeTopKitTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures")
    }

    static func dir(_ name: String = referenceName) -> URL {
        root.appendingPathComponent(name)
    }

    static func text(_ file: String, in name: String = referenceName) throws -> String {
        try String(contentsOf: dir(name).appendingPathComponent(file), encoding: .utf8)
    }

    // MARK: - ps.txt
    // Columns: pid ppid uid pcpu rss time etime command
    // `time` is cumulative CPU time as [[dd-]hh:]mm:ss.ff — the field the interval
    // calculation diffs. `pcpu` is a lifetime average and is captured only so tests can
    // demonstrate why it must not be used for ranking.

    struct RawProc {
        let pid: Int32, ppid: Int32, uid: Int32
        let psPercentCPU: Double
        let rssKB: UInt64
        let cpuTime: TimeInterval
        let command: String
    }

    static func processes(in name: String = referenceName) throws -> [RawProc] {
        try text("ps.txt", in: name).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard f.count == 8,
                  let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = Int32(f[2]),
                  let pcpu = Double(f[3]), let rss = UInt64(f[4])
            else { return nil }
            return RawProc(pid: pid, ppid: ppid, uid: uid, psPercentCPU: pcpu,
                           rssKB: rss, cpuTime: parseCPUTime(String(f[5])),
                           command: String(f[7]))
        }
    }

    /// `[[dd-]hh:]mm:ss.ff` -> seconds.
    static func parseCPUTime(_ s: String) -> TimeInterval {
        var rest = s, days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[rest.startIndex..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        let hms: Double
        switch parts.count {
        case 3: hms = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: hms = parts[0] * 60 + parts[1]
        case 1: hms = parts[0]
        default: hms = 0
        }
        return days * 86400 + hms
    }

    // MARK: - procenv.txt
    // `<pid> KEY=value KEY=value ...`, allowlisted at capture time to the four vars the
    // engine reads. Nothing else was ever written to disk.

    static func environments(in name: String = referenceName) throws -> [Int32: ProcessEnvironment] {
        var out: [Int32: ProcessEnvironment] = [:]
        for line in try text("procenv.txt", in: name).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = Int32(f.first ?? "") else { continue }
            var kv: [String: String] = [:]
            for token in f.dropFirst() {
                guard let eq = token.firstIndex(of: "=") else { continue }
                kv[String(token[token.startIndex..<eq])] = String(token[token.index(after: eq)...])
            }
            out[pid] = ProcessEnvironment(
                pid: pid,
                messagingSocket: kv["CLAUDE_CODE_MESSAGING_SOCKET"],
                hostSessionID: kv["CLAUDE_CODE_HOST_SESSION_ID"],
                entrypoint: kv["CLAUDE_CODE_ENTRYPOINT"],
                pwd: kv["PWD"])
        }
        return out
    }

    // MARK: - agents.json
    // The `name` field (the user's opening prompt) is stripped at capture time.

    static func sessions(in name: String = referenceName) throws -> [SessionInfo] {
        let data = Data(try text("agents.json", in: name).utf8)
        let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let pid = r["pid"] as? Int,
                  let cwd = r["cwd"] as? String,
                  let sid = r["sessionId"] as? String else { return nil }
            let ms = (r["startedAt"] as? Double) ?? 0
            return SessionInfo(pid: Int32(pid), cwd: cwd, sessionID: sid,
                               startedAt: Date(timeIntervalSince1970: ms / 1000))
        }
    }

    // MARK: - docker-labels.jsonl

    static func containers(in name: String = referenceName) throws -> [ContainerInfo] {
        try text("docker-labels.jsonl", in: name).split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return nil }
            return ContainerInfo(
                id: obj["id"] as? String ?? "",
                name: obj["name"] as? String ?? "",
                image: obj["image"] as? String ?? "",
                labels: obj["labels"] as? [String: String] ?? [:],
                cpuPercent: nil,   // docker stats returned "--" under load; unknown is valid
                rssBytes: nil)
        }
    }

    // MARK: - machine.txt

    static func machine(in name: String = referenceName) throws -> MachineInfo {
        var kv: [String: String] = [:]
        for line in try text("machine.txt", in: name).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            kv[String(line[line.startIndex..<eq])] =
                String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        let load = kv["loadavg"]?.split(separator: " ").first.flatMap { Double($0) } ?? 0
        let fmt = ISO8601DateFormatter()
        return MachineInfo(
            cpuCount: Int(kv["ncpu"] ?? "") ?? 0,
            memTotalBytes: UInt64(kv["memtotal_bytes"] ?? "") ?? 0,
            loadAverage1: load,
            capturedAt: kv["captured_at"].flatMap { fmt.date(from: $0) } ?? Date(),
            // Captures rewrite the real home to /Users/USER. Passing it explicitly keeps
            // labelling identical no matter whose machine replays the fixture.
            homeDirectory: kv["home"] ?? "/Users/USER")
    }
}
