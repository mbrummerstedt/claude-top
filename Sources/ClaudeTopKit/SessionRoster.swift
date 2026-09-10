import Foundation

/// The authoritative list of live sessions, from `claude agents --json`.
///
/// The cascade only has to explain the processes; this says which sessions exist. When
/// `claude` is missing or slow the roster is empty, and every stamped process then
/// resolves as an orphan. That is the correct answer rather than a degraded one: nothing
/// on the machine was able to confirm any session is alive.
public enum SessionRoster {

    public static func live(timeout: TimeInterval = 3,
                            candidates: [String]? = nil) -> [SessionInfo] {
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
        return []
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
