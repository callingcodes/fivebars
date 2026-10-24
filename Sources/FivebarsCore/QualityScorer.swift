import Foundation

/// Monotonic seconds (system uptime): immune to wall-clock steps, unlike Date.
public enum MonotonicClock {
    public static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// A ping that has been sent and is still inside the averaging window.
/// Times are monotonic seconds (see MonotonicClock).
public struct PendingPing: Equatable, Sendable {
    public let id: UInt64
    public let sent: TimeInterval
    public var reply: TimeInterval?
    public var lost: Bool

    public init(id: UInt64, sent: TimeInterval, reply: TimeInterval? = nil, lost: Bool = false) {
        self.id = id
        self.sent = sent
        self.reply = reply
        self.lost = lost
    }
}

public struct ScoringConfig: Equatable, Sendable {
    /// Round-trip time (seconds) at or below which a ping scores a perfect 1.
    public var lowThreshold: TimeInterval
    /// Round-trip time (seconds) at which a ping scores 0.
    public var highThreshold: TimeInterval
    /// A ping slower than this (or never answered) counts as lost.
    public var timeout: TimeInterval
    /// Pings older than this drop out of the window.
    public var averageOver: TimeInterval

    public init(lowThreshold: TimeInterval, highThreshold: TimeInterval, timeout: TimeInterval, averageOver: TimeInterval) {
        self.lowThreshold = lowThreshold
        self.highThreshold = highThreshold
        self.timeout = timeout
        self.averageOver = averageOver
    }

    /// The original app derived the high threshold as low + 900 ms and averaged over 30 s.
    public static func original(slowPingThresholdMs: Double, timeout: TimeInterval) -> ScoringConfig {
        ScoringConfig(
            lowThreshold: slowPingThresholdMs / 1000,
            highThreshold: (slowPingThresholdMs + 900) / 1000,
            timeout: timeout,
            averageOver: 30
        )
    }
}

public struct Evaluation: Equatable, Sendable {
    /// Recency-weighted quality score, or nil when no ping in the window can be scored yet.
    public var score: Double?
    /// Lost pings as a percentage of the pings in the window.
    public var lossPercent: Double
    /// Pings marked lost for the first time during this evaluation.
    public var newlyLost: [PendingPing]
}

/// Port of the scoring done in the original app's (v1.02) -[AppDelegate onHousekeepingTimer:].
public enum QualityScorer {
    public static let lostScore = -2.5
    public static let recencyWeight = 1.2

    public static func evaluate(_ pending: inout [PendingPing], now: TimeInterval, config: ScoringConfig) -> Evaluation {
        pending.removeAll { now - $0.sent > config.averageOver }

        let range = config.highThreshold - config.lowThreshold
        var scores: [Double] = []
        var lostCount = 0
        var newlyLost: [PendingPing] = []

        for index in pending.indices {
            let ping = pending[index]
            let age = now - ping.sent
            let rtt: TimeInterval
            if let reply = ping.reply {
                rtt = reply - ping.sent
            } else if age < config.highThreshold {
                // Still in flight and not yet slow enough to count against the connection.
                continue
            } else {
                // Unanswered pings are scored as if they replied right now.
                rtt = age
            }

            if rtt > config.timeout {
                lostCount += 1
                if !ping.lost {
                    pending[index].lost = true
                    newlyLost.append(pending[index])
                }
                scores.append(lostScore)
            } else if rtt <= config.lowThreshold {
                scores.append(1)
            } else {
                scores.append(max(1 - (rtt - config.lowThreshold) / range, lostScore))
            }
        }

        let lossPercent = pending.isEmpty ? 0 : Double(lostCount) / Double(pending.count) * 100
        return Evaluation(score: weightedAverage(scores), lossPercent: lossPercent, newlyLost: newlyLost)
    }

    /// Later (more recent) scores weigh 1.2x more than the one before them.
    static func weightedAverage(_ scores: [Double]) -> Double? {
        guard !scores.isEmpty else { return nil }
        var weight = 1.0
        var total = 0.0
        var totalWeight = 0.0
        for score in scores {
            total += score * weight
            totalWeight += weight
            weight *= recencyWeight
        }
        return total / totalWeight
    }

    /// Maps a score to 1...levels bars, exactly like -[AppDelegate updateIconState:error:].
    public static func bars(for score: Double, levels: Int = 5) -> Int {
        let clamped = min(max(score, 0), 1)
        return min(Int((clamped * Double(levels)).rounded(.down)), levels - 1) + 1
    }
}
