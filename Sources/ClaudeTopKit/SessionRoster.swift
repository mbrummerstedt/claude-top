import Foundation

/// The authoritative list of live sessions, from `claude agents --json`.
///
/// The cascade only has to explain the processes; this says which sessions exist. When
/// `claude` is missing or slow the roster is empty, and every stamped process then
/// resolves as an orphan. That is the correct answer rather than a degraded one: nothing
/// on the machine was able to confirm any session is alive.
public enum SessionRoster {

    /// Ten seconds, not three.
    ///
    /// `claude agents --json` answers in under half a second on an idle machine and took
    /// 5.9 seconds on this one at load 22. A timeout tuned to the idle case expires
    /// exactly when the machine is busy, which is the only time anyone runs this.
    public static let defaultTimeout: TimeInterval = 10

    /// How long a remembered roster is still worth showing. Sessions come and go; an
    /// hour-old roster describes a machine that no longer exists.
    public static let cacheWindow: TimeInterval = 600

    public static var cachePath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/state/claude-top-roster-cache.json")
    }

    /// The roster, and where it came from.
    ///
    /// A read that fails falls back to the last good one rather than to silence, because
    /// an empty roster resolves every stamped process to an orphan and orphans are what
    /// `--reap` acts on. The fallback is labelled so nothing mistakes it for fresh.
    public static func live(timeout: TimeInterval = defaultTimeout,
                            candidates: [String]? = nil,
                            cache: URL? = cachePath) -> Roster {
        if let sessions = read(timeout: timeout, candidates: candidates) {
            if let cache { remember(sessions, at: cache) }
            return Roster(sessions: sessions, source: .live)
        }
        if let cache, let remembered = remembered(at: cache, now: Date(),
                                                  maximumAge: cacheWindow) {
            return remembered
        }
        return Roster(sessions: [], source: .unavailable)
    }

    /// What is on disk from the last successful read, if it is recent enough to mean
    /// anything.
    public static func remembered(at path: URL, now: Date,
                                  maximumAge: TimeInterval) -> Roster? {
        guard let data = try? Data(contentsOf: path),
              let stored = try? JSONDecoder().decode(CachedRoster.self, from: data)
        else { return nil }

        let age = now.timeIntervalSince(stored.writtenAt)
        guard age >= 0, age <= maximumAge else { return nil }

        return Roster(sessions: stored.sessions.map(\.asSessionInfo), source: .cached(age: age))
    }

    /// The prompt is deliberately not written. This is a file that outlives the terminal
    /// the prompt was printed to.
    public static func remember(_ sessions: [SessionInfo], at path: URL) {
        let stored = CachedRoster(writtenAt: Date(),
                                  sessions: sessions.map(CachedRoster.Entry.init))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
    }

    struct CachedRoster: Codable {
        let writtenAt: Date
        let sessions: [Entry]

        struct Entry: Codable {
            let pid: Int32
            let cwd: String
            let sessionID: String
            let startedAt: Date

            init(_ session: SessionInfo) {
                pid = session.pid; cwd = session.cwd
                sessionID = session.sessionID; startedAt = session.startedAt
            }

            var asSessionInfo: SessionInfo {
                SessionInfo(pid: pid, cwd: cwd, sessionID: sessionID, startedAt: startedAt)
            }
        }
    }

    private static func read(timeout: TimeInterval,
                             candidates: [String]?) -> [SessionInfo]? {
        let binaries = candidates ?? Shell.locateAll("claude", extraDirectories: [
            (NSHomeDirectory() as NSString).appendingPathComponent(".claude/local"),
        ])

        // Work down the candidates until one answers with a JSON array. An older install
        // earlier on `PATH` rejects `--json` outright, and taking its failure as "no
        // sessions are running" would file every live session as an orphan: the one
        // mistake that makes `--reap` dangerous rather than merely wrong.
        for binary in binaries {
            guard let output = Shell.run(binary, ["agents", "--json"], timeout: timeout) else {
                continue
            }
            let data = Data(output.utf8)
            guard (try? JSONSerialization.jsonObject(with: data)) is [Any] else { continue }
            // An empty array is a real answer: no sessions are running.
            return parse(data)
        }
        // nil, not []. Nothing answered, which is a different fact from nothing running.
        return nil
    }

    /// The `name` field of each row is the user's opening prompt. It is carried only far
    /// enough to be printed in the terminal table, where it is the one thing that tells
    /// two home-directory sessions apart, and it goes no further than that.
    public static func parse(_ data: Data) -> [SessionInfo] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let pid = row["pid"] as? Int,
                  let cwd = row["cwd"] as? String,
                  let sessionID = row["sessionId"] as? String,
                  !sessionID.isEmpty
            else { return nil }
            // Milliseconds since the epoch, as the CLI emits it.
            let startedAt = (row["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return SessionInfo(pid: Int32(pid), cwd: cwd, sessionID: sessionID,
                               startedAt: startedAt ?? Date(),
                               promptPreview: preview(of: row["name"] as? String))
        }
    }

    /// Collapsed to one line and cut short. A prompt can be a paragraph, and the table
    /// has one row per session.
    static func preview(of name: String?) -> String? {
        guard let name else { return nil }
        let flattened = name.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }
        return flattened.count > 48 ? String(flattened.prefix(47)) + "…" : flattened
    }
}
