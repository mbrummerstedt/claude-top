import Foundation

/// The authoritative list of live sessions, from `claude agents --json`.
///
/// The cascade only has to explain the processes; this says which sessions exist. When
/// `claude` is missing or slow the roster is empty, and every stamped process then
/// resolves as an orphan. That is the correct answer rather than a degraded one: nothing
/// on the machine was able to confirm any session is alive.
public enum SessionRoster {

    public static func live(timeout: TimeInterval = 3) -> [SessionInfo] {
        guard let binary = Shell.locate("claude", extraDirectories: [
            (NSHomeDirectory() as NSString).appendingPathComponent(".claude/local"),
        ]) else { return [] }
        guard let output = Shell.run(binary, ["agents", "--json"], timeout: timeout) else { return [] }
        return parse(Data(output.utf8))
    }

    /// The `name` field of each row is the user's opening prompt. It is read past and
    /// never stored: it must not reach the database, a log, or a fixture.
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
                               startedAt: startedAt ?? Date())
        }
    }
}
