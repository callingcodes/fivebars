import Foundation

/// Decides when the connection is up or down, when to restart the pinger, and which alerts to post.
///
/// Pure state machine: the caller feeds it events with MonotonicClock timestamps and performs the
/// returned actions. Rules:
/// - Silence is measured from the last real reply, or from the start of the episode (launch, wake,
///   host change), never from a pinger restart, so restarts cannot postpone detection.
/// - Once pinging has started, `replyTimeout` without a reply declares the connection down
///   (the original's timeout + 4 pings). Whatever happens (slow DNS, path churn), `maxSilence`
///   without a reply declares it down too.
/// - A pinger start that is still resolving is never restarted, unless it has been resolving for
///   `resolutionTimeout`: then it is abandoned (`startTimedOut`) and handled as a failed start.
/// - Restarts are spaced by at least `minRestartInterval`; while down they back off from
///   `replyTimeout` to `maxRestartInterval`, counted from when the last start finished (opened or
///   failed), so a socket opened by a slow lookup always gets a full window to hear a reply.
/// - During `grace` after an episode start or a network change, a failed start (DNS not ready, no
///   socket) is retried after `retryDelay` instead of declaring the connection down.
/// - "Down" is announced once per outage, only if alerts are on and a reply has been seen for this
///   host. "Up" is announced only after an announced "Down", and only if alerts are still on.
public struct ConnectionWatchdog: Sendable {
    public enum Status: Sendable, Equatable {
        case starting
        case up
        case down
    }

    public enum Action: Sendable, Equatable {
        case restartPinger
        /// The start has been resolving for too long: stop that pinger and forget its lookup.
        case startTimedOut
        case announceDown
        case announceUp
    }

    public struct Config: Sendable, Equatable {
        public var replyTimeout: TimeInterval
        public var maxSilence: TimeInterval
        public var grace: TimeInterval
        public var retryDelay: TimeInterval
        public var minRestartInterval: TimeInterval
        public var maxRestartInterval: TimeInterval
        public var resolutionTimeout: TimeInterval

        public init(
            replyTimeout: TimeInterval,
            maxSilence: TimeInterval,
            grace: TimeInterval,
            retryDelay: TimeInterval,
            minRestartInterval: TimeInterval,
            maxRestartInterval: TimeInterval,
            resolutionTimeout: TimeInterval = 10
        ) {
            self.replyTimeout = replyTimeout
            self.maxSilence = maxSilence
            self.grace = grace
            self.retryDelay = retryDelay
            self.minRestartInterval = minRestartInterval
            self.maxRestartInterval = maxRestartInterval
            self.resolutionTimeout = resolutionTimeout
        }

        /// The original declared failure after timeout + 4 ping intervals without a reply (8 s at
        /// 1 s). Slower intervals miss 4 pings at most, 2 at least, and aim for no more than 60 s of
        /// misses: timeout + max(2 × interval, min(4 × interval, 60)).
        public static func original(timeout: TimeInterval, pingInterval: TimeInterval) -> Config {
            let missed = max(2 * pingInterval, min(4 * pingInterval, 60))
            let replyTimeout = timeout + missed
            return Config(
                replyTimeout: replyTimeout,
                maxSilence: replyTimeout + 12,
                grace: 10,
                retryDelay: 2,
                minRestartInterval: 2,
                // A recovery is noticed within ~15 s even when each retry needs DNS. Each restart
                // sends a ping, so retries never come faster than the chosen interval.
                maxRestartInterval: max(15, pingInterval),
                resolutionTimeout: 10
            )
        }
    }

    public var config: Config
    /// Mirrors the user's alert setting; read when an outage is declared.
    public var alertsEnabled = false
    public private(set) var status = Status.starting
    /// A pinger start (resolution + socket) is in flight.
    public private(set) var isResolving = false

    private var lastReplyAt: TimeInterval?
    private var episodeStart: TimeInterval
    private var pingingSince: TimeInterval?
    private var graceUntil: TimeInterval
    private var confirmed = false
    private var downAnnounced = false
    private var restartDue: TimeInterval?
    private var lastRestart: TimeInterval?
    private var restartBackoff: TimeInterval

    public init(config: Config, now: TimeInterval) {
        self.config = config
        episodeStart = now
        graceUntil = now + config.grace
        restartBackoff = config.replyTimeout
    }

    /// Starts a new episode: at launch, after wake, or for a new host (`newHost` forgets that the
    /// connection was ever confirmed). The caller has stopped the pinger; it restarts after `delay`.
    public mutating func reset(at now: TimeInterval, restartAfter delay: TimeInterval = 0, newHost: Bool) -> [Action] {
        status = .starting
        isResolving = false
        episodeStart = now
        pingingSince = nil
        graceUntil = now + config.grace
        lastRestart = nil
        restartDue = now + delay
        restartBackoff = config.replyTimeout
        if newHost {
            lastReplyAt = nil
            confirmed = false
            downAnnounced = false
        }
        return tick(at: now)
    }

    /// The pinger resolved the host and is about to send its first ping.
    public mutating func pingingStarted(at now: TimeInterval) {
        isResolving = false
        // Back-off is counted from here, not from when the (maybe slow) lookup began.
        lastRestart = now
        if pingingSince == nil {
            pingingSince = now
        }
    }

    /// The pinger could not start (resolution or socket error).
    public mutating func startFailed(at now: TimeInterval) -> [Action] {
        isResolving = false
        lastRestart = now
        if now < graceUntil && status != .down {
            restartDue = min(restartDue ?? .infinity, now + config.retryDelay)
            return []
        }
        return declareDown()
    }

    public mutating func replyReceived(at now: TimeInterval) -> [Action] {
        lastReplyAt = now
        confirmed = true
        restartBackoff = config.replyTimeout
        if status == .down {
            // Recovered: drop the pending back-off restart.
            restartDue = nil
        }
        status = .up
        // Survives wake (status goes back to .starting), so a recovery after wake is still announced.
        guard downAnnounced else { return [] }
        downAnnounced = false
        return alertsEnabled ? [.announceUp] : []
    }

    /// The network path changed: restart soon (DNS may have moved), without resetting the silence clock.
    public mutating func networkChanged(at now: TimeInterval) -> [Action] {
        graceUntil = max(graceUntil, now + config.grace)
        let earliest = lastRestart.map { $0 + config.minRestartInterval } ?? now
        restartDue = min(restartDue ?? .infinity, max(now, earliest))
        return tick(at: now)
    }

    /// Called every housekeeping second.
    public mutating func tick(at now: TimeInterval) -> [Action] {
        var actions: [Action] = []
        if isResolving, let lastRestart, now - lastRestart >= config.resolutionTimeout {
            actions.append(.startTimedOut)
            actions += startFailed(at: now)
        }
        let lastSign = max(lastReplyAt ?? episodeStart, episodeStart)
        if status != .down {
            let pingAnchor = pingingSince.map { max($0, lastSign) }
            if let pingAnchor, now - pingAnchor > config.replyTimeout {
                actions += declareDown()
            } else if now - lastSign > config.maxSilence {
                actions += declareDown()
            }
        }

        if status == .down, restartDue == nil, !isResolving {
            restartDue = (lastRestart ?? now) + restartBackoff
        }
        if let due = restartDue, now >= due, !isResolving {
            if let lastRestart, now - lastRestart < config.minRestartInterval {
                restartDue = lastRestart + config.minRestartInterval
            } else {
                actions.append(.restartPinger)
                isResolving = true
                lastRestart = now
                restartDue = nil
                if status == .down {
                    restartBackoff = min(restartBackoff * 2, config.maxRestartInterval)
                }
            }
        }
        return actions
    }

    private mutating func declareDown() -> [Action] {
        guard status != .down else { return [] }
        status = .down
        restartBackoff = config.replyTimeout
        guard confirmed, alertsEnabled, !downAnnounced else { return [] }
        downAnnounced = true
        return [.announceDown]
    }
}
