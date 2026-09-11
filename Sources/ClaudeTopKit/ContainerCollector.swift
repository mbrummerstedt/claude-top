import Foundation

/// Containers, in three calls that are each allowed to fail.
///
/// `docker ps` and `docker inspect` give identity and labels; `docker stats` gives usage
/// and is the one most likely to hang. Losing stats costs the CPU and memory columns and
/// nothing else: attribution still works, because attribution comes from labels.
public enum ContainerCollector {

    /// What a listing attempt produced. `answered` is false only when no docker on this
    /// machine responded in time, which is a different fact from finding no containers
    /// and must not be rendered as one.
    public struct Listing: Sendable {
        public let containers: [ContainerInfo]
        public let answered: Bool

        public init(containers: [ContainerInfo], answered: Bool) {
            self.containers = containers; self.answered = answered
        }
    }

    public static func current(timeout: TimeInterval = 3) -> Listing {
        let binaries = Shell.locateAll("docker", extraDirectories: [
            (NSHomeDirectory() as NSString).appendingPathComponent(".docker/bin"),
            "/Applications/Docker.app/Contents/Resources/bin",
        ])

        // Same reason as the session roster: more than one docker can be installed, and
        // one of them may not be able to reach a daemon.
        var docker: String?
        var containers: [ContainerInfo] = []
        for binary in binaries {
            guard let listing = Shell.run(binary, ["ps", "--format", "{{json .}}"],
                                          timeout: timeout) else { continue }
            docker = binary
            containers = parseContainers(psJSONLines: listing)
            break
        }
        // `docker` is nil only when every binary failed or timed out. Having a docker
        // that answered with no containers is a real answer, and stays one.
        guard let docker else { return Listing(containers: [], answered: false) }
        guard !containers.isEmpty else { return Listing(containers: [], answered: true) }

        let stats = Shell.run(docker, ["stats", "--no-stream", "--format", "{{json .}}"],
                              timeout: timeout)
            .map { parseStats(statsJSONLines: $0) } ?? [:]
        return Listing(containers: merge(containers: containers, stats: stats),
                       answered: true)
    }

    public static func parseContainers(psJSONLines: String) -> [ContainerInfo] {
        psJSONLines.split(separator: "\n").compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["ID"] as? String
            else { return nil }
            return ContainerInfo(
                id: id,
                name: row["Names"] as? String ?? "",
                image: row["Image"] as? String ?? "",
                labels: parseLabels(row["Labels"] as? String ?? ""),
                cpuPercent: nil, rssBytes: nil)
        }
    }

    /// `docker ps` joins labels with commas and does not escape commas inside values, so
    /// splitting on every comma truncates any value that contains one. Pairs are found by
    /// looking for `key=` instead, which leaves a comma inside a value where it belongs.
    /// A truncated `working_dir` would attribute a container to the wrong worktree.
    static func parseLabels(_ raw: String) -> [String: String] {
        guard !raw.isEmpty else { return [:] }

        var labels: [String: String] = [:]
        var key: String?
        var value = ""

        for piece in raw.split(separator: ",", omittingEmptySubsequences: false) {
            if let equals = piece.firstIndex(of: "="),
               !piece[piece.startIndex..<equals].contains(" ") {
                if let previous = key { labels[previous] = value }
                key = String(piece[piece.startIndex..<equals])
                value = String(piece[piece.index(after: equals)...])
            } else if key != nil {
                value += "," + piece
            }
        }
        if let last = key { labels[last] = value }
        return labels
    }

    public static func parseStats(statsJSONLines: String)
        -> [String: (cpuPercent: Double?, rssBytes: UInt64?)] {
        var out: [String: (cpuPercent: Double?, rssBytes: UInt64?)] = [:]
        for line in statsJSONLines.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["Container"] as? String
            else { continue }
            out[id] = (cpuPercent: parsePercent(row["CPUPerc"] as? String),
                       rssBytes: parseMemory(row["MemUsage"] as? String))
        }
        return out
    }

    /// Dashes mean docker could not answer, which is unknown and not zero. Reporting zero
    /// would say a container is idle at exactly the moment the machine is too busy to say.
    static func parsePercent(_ raw: String?) -> Double? {
        guard let raw, !raw.contains("--") else { return nil }
        return Double(raw.replacingOccurrences(of: "%", with: ""))
    }

    static func parseMemory(_ raw: String?) -> UInt64? {
        guard let raw, !raw.contains("--"),
              let used = raw.split(separator: "/").first?.trimmingCharacters(in: .whitespaces)
        else { return nil }

        let units: [(String, Double)] = [
            ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024),
            ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1),
        ]
        for (suffix, multiplier) in units where used.hasSuffix(suffix) {
            guard let value = Double(used.dropLast(suffix.count)) else { return nil }
            return UInt64(value * multiplier)
        }
        return nil
    }

    public static func merge(containers: [ContainerInfo],
                             stats: [String: (cpuPercent: Double?, rssBytes: UInt64?)])
        -> [ContainerInfo] {
        containers.map { container in
            let s = stats[container.id]
            return ContainerInfo(id: container.id, name: container.name, image: container.image,
                                 labels: container.labels,
                                 cpuPercent: s?.cpuPercent, rssBytes: s?.rssBytes)
        }
    }
}
