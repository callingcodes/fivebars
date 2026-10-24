import Foundation

/// Ping statistics for one host, as kept by the original app's StatCounter class.
public struct StatCounter: Codable, Equatable, Sendable {
    public var sent = 0
    public var replied = 0
    public var lost = 0
    public var averageMs = 0.0
    public var fastestMs = 0.0
    public var slowestMs = 0.0

    public init() {}

    /// True when nothing was ever counted (not worth persisting).
    public var isEmpty: Bool {
        sent == 0 && replied == 0 && lost == 0
    }

    /// Clamped to 100 % in case an older stats file booked more losses than sends.
    public var lossPercent: Double {
        sent > 0 ? min(Double(lost) / Double(sent) * 100, 100) : 0
    }

    public mutating func addPingSent() {
        sent += 1
    }

    public mutating func addPingTimeout() {
        lost += 1
    }

    public mutating func addPingResponse(ms: Double) {
        replied += 1
        if ms > slowestMs {
            slowestMs = ms
        }
        if fastestMs == 0 || ms < fastestMs {
            fastestMs = ms
        }
        // The original over-weighted each new sample; this is a true running mean.
        averageMs += (ms - averageMs) / Double(replied)
    }
}

/// Persists all-time statistics per host (the original used stats.sqlite).
public struct StatsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static func defaultStore() -> StatsStore {
        StatsStore(url: supportDirectory.appendingPathComponent("Fivebars/stats.json"))
    }

    public func load() -> [String: StatCounter] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: StatCounter].self, from: data)) ?? [:]
    }

    public func save(_ stats: [String: StatCounter]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stats).write(to: url, options: .atomic)
    }
}
