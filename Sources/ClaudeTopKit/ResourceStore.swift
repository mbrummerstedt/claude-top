import Foundation
import SQLite3

/// The rolling 24 hours, in SQLite through the system library.
///
/// A short-lived writer rather than a resident daemon: the sampler opens this file, writes
/// one tick, prunes, and exits. Nothing sits in memory between ticks, a crash self-heals
/// on the next one, and there is no long-running process to audit later. A previous tool
/// on this machine burned real resources through always-on background hooks, and this is
/// the lesson taken from it.
public final class ResourceStore {

    private let handle: OpaquePointer
    private let retention: TimeInterval

    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/state/resources.db")
    }

    public init(path: String, retention: TimeInterval = 24 * 3600) throws {
        self.retention = retention

        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK,
              let opened = handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw StoreError.cannotOpen(path: path, message: message)
        }
        self.handle = opened

        // WAL so a reader (the statusline, on every prompt) never blocks the writer, and
        // a busy timeout so two samplers overlapping wait rather than fail.
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        sqlite3_busy_timeout(opened, 2000)
        try createSchema()
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: - schema

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS sample (
                ts INTEGER PRIMARY KEY, load1 REAL, ncpu INTEGER,
                mem_used_mb INTEGER, mem_total_mb INTEGER);
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS attribution (
                ts INTEGER, key TEXT, label TEXT, kind TEXT,
                cpu_pct REAL, rss_mb INTEGER, n_proc INTEGER, n_container INTEGER,
                session_pid INTEGER,
                PRIMARY KEY (ts, key));
            """)
        // Added after the first release wrote its first file. An existing database gets
        // the column; a new one already has it and the failure here is the expected one.
        try? execute("ALTER TABLE attribution ADD COLUMN session_pid INTEGER")
        try execute("""
            CREATE TABLE IF NOT EXISTS proc_detail (
                ts INTEGER, key TEXT, pid INTEGER, cpu_pct REAL, rss_mb INTEGER, cmd TEXT);
            """)
        // The previous tick's raw counters. Not history: the sampler is a short-lived
        // process, so without somewhere to leave these it would have nothing to diff
        // against and could only report the lifetime averages this tool exists to avoid.
        // One tick is kept, replaced wholesale each time.
        try execute("""
            CREATE TABLE IF NOT EXISTS cpu_baseline (
                pid INTEGER PRIMARY KEY, ts REAL, cpu_time REAL, started_at REAL);
            """)
        // When each abandoned worktree was first seen with no session behind it. The one
        // fact an unattended reap rests on, and the one no single sample can observe.
        try execute("""
            CREATE TABLE IF NOT EXISTS orphan_seen (
                key TEXT PRIMARY KEY, first_seen INTEGER, last_seen INTEGER);
            """)
        try execute("CREATE INDEX IF NOT EXISTS attribution_ts ON attribution (ts)")
        try execute("CREATE INDEX IF NOT EXISTS proc_detail_ts ON proc_detail (ts)")
    }

    // MARK: - writing

    /// Write one tick and prune anything outside the retention window.
    ///
    /// `processes` and `cpuPercents` are optional: without them the tick still records
    /// every group, just without the per-process breakdown behind the worst offenders.
    public func write(_ snapshot: Snapshot,
                      processes: [ProcessSample] = [],
                      cpuPercents: [Int32: Double] = [:],
                      detailThreshold: Double = 50) throws {
        let timestamp = Int64(snapshot.machine.capturedAt.timeIntervalSince1970)

        try execute("BEGIN IMMEDIATE")
        do {
            try run("INSERT OR REPLACE INTO sample VALUES (?, ?, ?, ?, ?)") { statement in
                sqlite3_bind_int64(statement, 1, timestamp)
                sqlite3_bind_double(statement, 2, snapshot.machine.loadAverage1)
                sqlite3_bind_int(statement, 3, Int32(snapshot.machine.cpuCount))
                sqlite3_bind_int64(statement, 4, Int64(snapshot.machine.memUsedBytes / 1_048_576))
                sqlite3_bind_int64(statement, 5, Int64(snapshot.machine.memTotalBytes / 1_048_576))
            }

            let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            for group in snapshot.groups {
                try run("INSERT OR REPLACE INTO attribution VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)") { s in
                    sqlite3_bind_int64(s, 1, timestamp)
                    bindText(s, 2, group.key.storageKey)
                    bindText(s, 3, group.label)
                    bindText(s, 4, group.key.kind)
                    // NULL rather than 0: an unusable interval is unknown, and a zero here
                    // would draw a busy session as a flat line in the history.
                    if let cpu = group.cpuPercent { sqlite3_bind_double(s, 5, cpu) }
                    else { sqlite3_bind_null(s, 5) }
                    sqlite3_bind_int64(s, 6, Int64(group.rssBytes / 1_048_576))
                    sqlite3_bind_int(s, 7, Int32(group.pids.count))
                    sqlite3_bind_int(s, 8, Int32(group.containerIDs.count))
                    if let pid = group.sessionPID { sqlite3_bind_int(s, 9, pid) }
                    else { sqlite3_bind_null(s, 9) }
                }

                guard let cpu = group.cpuPercent, cpu >= detailThreshold else { continue }
                for pid in group.pids {
                    try run("INSERT INTO proc_detail VALUES (?, ?, ?, ?, ?, ?)") { s in
                        sqlite3_bind_int64(s, 1, timestamp)
                        bindText(s, 2, group.key.storageKey)
                        sqlite3_bind_int(s, 3, pid)
                        sqlite3_bind_double(s, 4, cpuPercents[pid] ?? 0)
                        sqlite3_bind_int64(s, 5, Int64((byPID[pid]?.rssBytes ?? 0) / 1_048_576))
                        bindText(s, 6, String((byPID[pid]?.command ?? "").prefix(300)))
                    }
                }
            }

            try prune(before: snapshot.machine.capturedAt.addingTimeInterval(-retention))
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Replace the stored counters wholesale. Anything not in this list is gone, which is
    /// correct: a PID absent from the newest reading has exited, and keeping its counter
    /// around is how a recycled PID gets diffed against a process it never was.
    public func writeBaseline(_ processes: [ProcessSample], at date: Date) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM cpu_baseline")
            let timestamp = date.timeIntervalSince1970
            for process in processes {
                try run("INSERT OR REPLACE INTO cpu_baseline VALUES (?, ?, ?, ?)") { s in
                    sqlite3_bind_int(s, 1, process.pid)
                    sqlite3_bind_double(s, 2, timestamp)
                    sqlite3_bind_double(s, 3, process.cpuTime)
                    sqlite3_bind_double(s, 4, process.startedAt.timeIntervalSince1970)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// How long an observation gap may be before the clock restarts.
    ///
    /// A machine that was asleep, or a sampler that was not installed, saw nothing. Nine
    /// hours of abandonment cannot be claimed across a gap in which a session could have
    /// come and gone unnoticed.
    public static let observationGap: TimeInterval = 30 * 60

    /// Note which worktrees are abandoned right now.
    ///
    /// Keys absent from `orphans` are forgotten: that worktree has a session again, and
    /// its clock must not carry on from before.
    public func recordOrphans(_ orphans: [AttributionKey], at date: Date) throws {
        let stamp = Int64(date.timeIntervalSince1970)
        let keys = Set(orphans.map(\.storageKey))
        let known = try orphanRecords()

        try execute("BEGIN IMMEDIATE")
        do {
            for key in known.keys where !keys.contains(key) {
                try run("DELETE FROM orphan_seen WHERE key = ?") { bindText($0, 1, key) }
            }
            for key in keys {
                // A gap in observation restarts the clock; a normal sampling interval
                // does not.
                let continuous = known[key].map {
                    stamp - $0.lastSeen <= Int64(Self.observationGap) && $0.firstSeen <= stamp
                } ?? false
                let firstSeen = continuous ? (known[key]?.firstSeen ?? stamp) : stamp
                try run("INSERT OR REPLACE INTO orphan_seen VALUES (?, ?, ?)") {
                    bindText($0, 1, key)
                    sqlite3_bind_int64($0, 2, firstSeen)
                    sqlite3_bind_int64($0, 3, stamp)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// When each currently abandoned worktree was first seen that way.
    public func orphanedSince() -> [String: Date] {
        let records = (try? orphanRecords()) ?? [:]
        return records.mapValues { Date(timeIntervalSince1970: Double($0.firstSeen)) }
    }

    private func orphanRecords() throws -> [String: (firstSeen: Int64, lastSeen: Int64)] {
        var out: [String: (firstSeen: Int64, lastSeen: Int64)] = [:]
        try query("SELECT key, first_seen, last_seen FROM orphan_seen") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                out[String(cString: sqlite3_column_text(statement, 0))] =
                    (sqlite3_column_int64(statement, 1), sqlite3_column_int64(statement, 2))
            }
        }
        return out
    }

    public func prune(before date: Date) throws {
        let cutoff = Int64(date.timeIntervalSince1970)
        for table in ["sample", "attribution", "proc_detail"] {
            try run("DELETE FROM \(table) WHERE ts < ?") { sqlite3_bind_int64($0, 1, cutoff) }
        }
    }

    // MARK: - reading

    public func latest() throws -> StoredSample? {
        try history(query: "SELECT ts, load1, ncpu, mem_used_mb, mem_total_mb FROM sample "
                    + "ORDER BY ts DESC LIMIT 1", bind: { _ in }).first
    }

    public func history(since date: Date) throws -> [StoredSample] {
        let cutoff = Int64(date.timeIntervalSince1970)
        return try history(query: "SELECT ts, load1, ncpu, mem_used_mb, mem_total_mb FROM sample "
                           + "WHERE ts >= ? ORDER BY ts ASC",
                           bind: { sqlite3_bind_int64($0, 1, cutoff) })
    }

    public func baseline() throws -> (processes: [ProcessSample], readAt: Date)? {
        var processes: [ProcessSample] = []
        var readAt: Date?
        try query("SELECT pid, ts, cpu_time, started_at FROM cpu_baseline") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                readAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                processes.append(ProcessSample(
                    pid: sqlite3_column_int(statement, 0), ppid: 0, rssBytes: 0,
                    cpuTime: sqlite3_column_double(statement, 2),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    command: ""))
            }
        }
        guard let readAt else { return nil }
        return (processes.sorted { $0.pid < $1.pid }, readAt)
    }

    public func processDetail(at date: Date) throws -> [(pid: Int32, key: String, cpuPercent: Double)] {
        let timestamp = Int64(date.timeIntervalSince1970)
        var rows: [(pid: Int32, key: String, cpuPercent: Double)] = []
        try query("SELECT pid, key, cpu_pct FROM proc_detail WHERE ts = ?") { statement in
            sqlite3_bind_int64(statement, 1, timestamp)
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((pid: sqlite3_column_int(statement, 0),
                             key: String(cString: sqlite3_column_text(statement, 1)),
                             cpuPercent: sqlite3_column_double(statement, 2)))
            }
        }
        return rows
    }

    private func history(query: String,
                         bind: (OpaquePointer) -> Void) throws -> [StoredSample] {
        var samples: [(Int64, Double, Int32, Int64, Int64)] = []
        try self.query(query) { statement in
            bind(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                samples.append((sqlite3_column_int64(statement, 0),
                                sqlite3_column_double(statement, 1),
                                sqlite3_column_int(statement, 2),
                                sqlite3_column_int64(statement, 3),
                                sqlite3_column_int64(statement, 4)))
            }
        }

        return try samples.map { ts, load, cores, used, total in
            StoredSample(timestamp: Date(timeIntervalSince1970: Double(ts)),
                         loadAverage1: load, cpuCount: Int(cores),
                         memUsedBytes: UInt64(used) * 1_048_576,
                         memTotalBytes: UInt64(total) * 1_048_576,
                         groups: try groups(at: ts))
        }
    }

    private func groups(at timestamp: Int64) throws -> [StoredGroup] {
        var rows: [StoredGroup] = []
        try query("SELECT key, label, cpu_pct, rss_mb, n_proc, n_container, session_pid "
                  + "FROM attribution WHERE ts = ? ORDER BY cpu_pct DESC") { statement in
            sqlite3_bind_int64(statement, 1, timestamp)
            while sqlite3_step(statement) == SQLITE_ROW {
                let stored = String(cString: sqlite3_column_text(statement, 0))
                // A key written by a newer version that this one cannot parse is skipped
                // rather than coerced into something wrong.
                guard let key = AttributionKey(storageKey: stored) else { continue }
                rows.append(StoredGroup(
                    key: key,
                    label: String(cString: sqlite3_column_text(statement, 1)),
                    cpuPercent: sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 2),
                    rssBytes: UInt64(sqlite3_column_int64(statement, 3)) * 1_048_576,
                    processCount: Int(sqlite3_column_int(statement, 4)),
                    containerCount: Int(sqlite3_column_int(statement, 5)),
                    sessionPID: sqlite3_column_type(statement, 6) == SQLITE_NULL
                        ? nil : sqlite3_column_int(statement, 6)))
            }
        }
        return rows
    }

    // MARK: - plumbing

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.query(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// A write. `bind` sets the parameters; stepping once is what performs it.
    private func run(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }) throws {
        try prepared(sql) { statement in
            bind(statement)
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE || status == SQLITE_ROW else {
                throw StoreError.query(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// A read. The body binds and steps to exhaustion itself, so nothing steps a
    /// statement that is already finished.
    private func query(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        try prepared(sql, body)
    }

    private func prepared(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement
        else {
            sqlite3_finalize(statement)
            throw StoreError.query(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(prepared) }
        try body(prepared)
    }

    /// SQLITE_TRANSIENT: SQLite copies the bytes, rather than holding a pointer into a
    /// Swift string that is about to go away.
    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case cannotOpen(path: String, message: String)
    case query(sql: String, message: String)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let message): return "cannot open \(path): \(message)"
        case .query(let sql, let message): return "\(message) running: \(sql)"
        }
    }
}
