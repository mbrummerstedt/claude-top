import Foundation

/// One kind of process within a group, and how many of them there are.
public struct ProcessKind: Sendable, Equatable {
    public let name: String
    public let count: Int
    /// nil when the sampling interval was unusable, the same contract as everywhere else.
    public let cpuPercent: Double?
    public let rssBytes: UInt64
    public let pids: [Int32]

    public init(name: String, count: Int, cpuPercent: Double?, rssBytes: UInt64,
                pids: [Int32]) {
        self.name = name; self.count = count; self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes; self.pids = pids
    }
}

extension AttributionEngine {

    /// What a group is actually made of, heaviest kind first.
    ///
    /// A row saying a session holds 239% across 36 processes tells you to worry. A row
    /// saying nine of them are vitest workers tells you what to do about it.
    public static func breakdown(of group: AttributionGroup, processes: [ProcessSample],
                                 cpuPercents: [Int32: Double]) -> [ProcessKind] {
        let owned = Set(group.pids)
        let members = processes.filter { owned.contains($0.pid) }
        guard !members.isEmpty else { return [] }

        let intervalUsable = !cpuPercents.isEmpty
        var order: [String] = []
        var byName: [String: [ProcessSample]] = [:]
        for process in members {
            let name = processName(of: process)
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(process)
        }

        let kinds = order.map { name -> ProcessKind in
            let group = byName[name] ?? []
            return ProcessKind(
                name: name,
                count: group.count,
                cpuPercent: intervalUsable
                    ? group.reduce(0.0) { $0 + (cpuPercents[$1.pid] ?? 0) } : nil,
                rssBytes: group.reduce(UInt64(0)) { $0 + $1.rssBytes },
                pids: group.map(\.pid).sorted())
        }

        return kinds.sorted {
            if ($0.cpuPercent ?? -1) != ($1.cpuPercent ?? -1) {
                return ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
            }
            if $0.rssBytes != $1.rssBytes { return $0.rssBytes > $1.rssBytes }
            return $0.name < $1.name
        }
    }

    /// A short name for what a command line is running.
    ///
    /// Display only. Attribution never consults this, and the fallback is always the
    /// honest basename of whatever was executed, so the worst outcome is a name that is
    /// less useful rather than one that is wrong.
    ///
    /// The rules exist because the obvious approach produces nothing: taking the first
    /// token of every command on the reference machine gives `python` seventeen times and
    /// `uv` ten times.
    public static func processName(of process: ProcessSample) -> String {
        // The real argv when it could be read. Splitting the joined form on spaces breaks
        // any executable path that contains one, and a Mac is full of them: a command
        // under `Library/Application Support` was being named `Application`.
        process.arguments.isEmpty ? processName(forCommand: process.command)
                                  : processName(arguments: process.arguments)
    }

    public static func processName(forCommand command: String) -> String {
        processName(arguments: command.split(separator: " ").map(String.init))
    }

    public static func processName(arguments: [String]) -> String {
        var tokens = arguments
        guard let first = tokens.first else { return "?" }

        // Some processes replace their own command line and leave no executable path to
        // read. Postgres writes `postgres: io worker 1`; there is nothing else to go on
        // and nothing else needed.
        if first.hasSuffix(":") {
            return String(first.dropLast()).components(separatedBy: "/").last ?? first
        }

        var steps = 0
        while steps < 8, !tokens.isEmpty {
            steps += 1
            let token = tokens[0]
            let name = basename(token)

            if interpreters.contains(name) {
                tokens.removeFirst()
                // `uv run pytest`, `python -m module`, `timeout 900 uv run …`.
                while let next = tokens.first,
                      subcommandNoise.contains(next) || Int(next) != nil {
                    tokens.removeFirst()
                }
                continue
            }

            // A package runner is stepped past only when it is running something else.
            // `pnpm dev` runs a script this cannot see into, and naming it after the
            // script would be inventing a fact.
            if packageRunners.contains(name) {
                if let next = tokens.dropFirst().first, delegating.contains(next) {
                    tokens.removeFirst(2)
                    continue
                }
                return name
            }

            if token.hasPrefix("-") { tokens.removeFirst(); continue }

            // vitest workers appear as `node (vitest 1)`, so a stray opening bracket has
            // to go. A balanced pair is part of the real name and stays: an app called
            // `Claude Helper (Renderer)` was losing its closing bracket to a blanket trim.
            let cleaned = unwrapped(name)
            if !cleaned.isEmpty { return distinctive(cleaned, within: token) }
            tokens.removeFirst()
        }

        return basename(first)
    }

    /// Strips a bracket only when it has no partner. `(vitest` is a fragment; `Claude
    /// Helper (Renderer)` is a name.
    private static func unwrapped(_ name: String) -> String {
        // A bracket wrapping the whole token is punctuation from a rewritten argv:
        // `(vitest)` and `(vitest` are both the word. A bracket in the middle belongs to
        // the name: `Claude Helper (Renderer)` was losing its closing one to a blanket
        // trim.
        if name.hasPrefix("(") {
            let inner = name.dropFirst()
            return String(inner.hasSuffix(")") ? inner.dropLast() : inner)
        }
        if name.hasSuffix(")") && !name.contains("(") { return String(name.dropLast()) }
        return name
    }

    private static func basename(_ token: String) -> String {
        (token as NSString).lastPathComponent
    }

    /// `cli.mjs` says nothing about what is running. The package directory around it does.
    private static func distinctive(_ name: String, within path: String) -> String {
        let stripped = stripExtension(name)
        guard genericEntryPoints.contains(stripped) else { return stripped }

        let parents = path.components(separatedBy: "/").dropLast().reversed()
        for parent in parents where !genericEntryPoints.contains(parent) && !parent.isEmpty {
            if parent.hasPrefix(".") || parent == "node_modules" { continue }
            // A version directory names a release, not a program. `25.2.6-b5b9692` was
            // being reported as though it were the thing running.
            if parent.first?.isNumber == true || parent.hasPrefix("v") && parent.dropFirst()
                .first?.isNumber == true { continue }
            return parent
        }
        return stripped
    }

    private static func stripExtension(_ name: String) -> String {
        for suffix in [".js", ".mjs", ".cjs", ".py", ".ts"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// Things that run other things and say nothing about what.
    private static let interpreters: Set<String> = [
        "node", "python", "python3", "ruby", "deno", "uv", "poetry", "pipenv",
        "env", "timeout", "exec", "sh", "bash", "zsh", "nice", "caffeinate",
    ]

    /// Words between an interpreter and the thing it is running.
    private static let subcommandNoise: Set<String> = ["run", "exec", "-m", "--", "-u"]

    private static let packageRunners: Set<String> = ["npm", "npx", "pnpm", "yarn", "bun"]

    /// A package runner followed by one of these is running something nameable.
    private static let delegating: Set<String> = ["exec", "dlx", "run", "x"]

    private static let genericEntryPoints: Set<String> = [
        "cli", "index", "main", "app", "bin", "dist", "start", "server", "run", "src",
    ]
}
