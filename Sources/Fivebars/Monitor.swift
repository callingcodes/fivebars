import AppKit
import FivebarsCore
import Network
import Observation

/// Pings the configured host every `prefs.pingInterval` (1 s by default) and turns the replies into a connection quality.
@MainActor
@Observable
final class Monitor {
    typealias Status = ConnectionWatchdog.Status

    struct Sample: Identifiable {
        let id: UInt64
        let date: Date
        var rttMs: Double?
        var lost = false
    }

    /// The chart shows 5 minutes; nothing else reads older samples.
    static let historyLength: TimeInterval = 5 * 60
    static let saveEveryTicks = 20
    /// Wi-Fi usually needs a few seconds after wake.
    static let wakeRestartDelay: TimeInterval = 2
    static let pathChangeDebounce: TimeInterval = 1

    let prefs: Preferences

    private(set) var status = Status.starting
    private(set) var score: Double?
    private(set) var latestPingMs: Double?
    /// Loss over the averaging window; 0 when `lossIsKnown` is false.
    private(set) var lossPercent = 0.0
    /// False when no ping is in the averaging window (e.g. the host does not resolve), so there is
    /// no loss to speak of: show "–" rather than "0%".
    private(set) var lossIsKnown = false
    private(set) var resolvedAddress: String?
    private(set) var lastError: String?
    /// The error that made the last pinger start fail, cleared when pinging starts.
    private(set) var startError: PingError? {
        didSet { lastError = startError?.message }
    }
    /// False while NWPathMonitor reports no usable network path.
    private(set) var pathSatisfied = true
    private(set) var samples: [Sample] = []
    private(set) var ledger = PingLedger()

    var sessionStats: StatCounter { ledger.session }
    var siteStats: StatCounter { ledger.site }

    @ObservationIgnored private let store = StatsStore.defaultStore()
    @ObservationIgnored private var allTimeStats: [String: StatCounter] = [:]
    @ObservationIgnored private var pending: [PendingPing] = []
    @ObservationIgnored private var pinger: Pinger?
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var housekeepingTimer: Timer?
    @ObservationIgnored private var watchdog: ConnectionWatchdog
    /// One identifier per process, kept across pinger restarts so in-flight replies still match.
    @ObservationIgnored private let identifier = UInt16.random(in: .min ... .max)
    /// Random start so a relaunch never reuses the ids of the previous run's in-flight pings.
    /// When the last ping went out, so an interval change keeps the rhythm instead of pinging at once.
    @ObservationIgnored private var lastPingSent: Date?
    @ObservationIgnored private var nextPingId = UInt64.random(in: 0...UInt64(UInt32.max))
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPathKey: String?
    @ObservationIgnored private var pathWork: DispatchWorkItem?

    init(prefs: Preferences) {
        self.prefs = prefs
        watchdog = ConnectionWatchdog(config: Self.watchdogConfig(prefs), now: MonotonicClock.now())
    }

    private static func watchdogConfig(_ prefs: Preferences) -> ConnectionWatchdog.Config {
        .original(timeout: prefs.pingTimeout, pingInterval: prefs.pingInterval)
    }

    /// Seconds without a reply before the connection is declared down.
    var replyTimeout: TimeInterval {
        Self.watchdogConfig(prefs).replyTimeout
    }

    /// Why the connection is down; nil unless `status` is `.down`.
    var downReason: DownReason? {
        status == .down ? DownReason(startError: startError, pathSatisfied: pathSatisfied) : nil
    }

    var bars: Int {
        score.map { QualityScorer.bars(for: $0) } ?? 0
    }

    /// `showsLoss` comes from the status item, which owns the packet loss mode's hysteresis.
    func menuTitle(showsLoss: Bool) -> String {
        if status == .down {
            return MenuBarTitle.failed
        }
        guard let latestPingMs else { return MenuBarTitle.waiting }
        let loss = showsLoss && lossIsKnown ? lossPercent : nil
        return MenuBarTitle.title(pingMs: latestPingMs, lossPercent: loss)
    }

    var tooltip: String {
        let ms = latestPingMs.map { "\(Int($0.rounded()))ms" } ?? "–"
        let loss = lossIsKnown ? "\(Int(lossPercent.rounded()))%" : "–"
        return "Latest Ping Time: \(ms)\nRecent Packet Loss: \(loss)"
    }

    // MARK: - Lifecycle

    func start() {
        allTimeStats = store.load()
        ledger.resetSite(to: allTimeStats[prefs.hostname] ?? StatCounter())

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer

        observeSystemEvents()
        resetEpisode(newHost: true)
    }

    func saveStats() {
        // Hosts that never got a ping out (typo, no DNS) leave no empty entry behind.
        allTimeStats[prefs.hostname] = siteStats
        try? store.save(allTimeStats.filter { !$0.value.isEmpty })
    }

    func setHostname(_ hostname: String) {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != prefs.hostname else { return }
        saveStats()
        prefs.hostname = trimmed
        hostChanged()
    }

    func restoreDefaults() {
        let previousHost = prefs.hostname
        saveStats()
        prefs.restoreDefaults()
        if prefs.hostname != previousHost {
            hostChanged()
        } else {
            pingIntervalChanged()
        }
    }

    /// Applies at once: the watchdog takes the new timings and the one ping timer is rescheduled.
    func setPingInterval(_ interval: TimeInterval) {
        let interval = Preferences.validPingInterval(interval)
        guard interval != prefs.pingInterval else { return }
        prefs.pingInterval = interval
        pingIntervalChanged()
    }

    private func pingIntervalChanged() {
        watchdog.config = Self.watchdogConfig(prefs)
        guard pingTimer != nil else { return }
        schedulePingTimer()
    }

    /// Replaces the ping timer. The next ping is due one interval after the last one went out, never
    /// earlier than now: going faster sends at most one catch-up ping, going slower waits it out.
    private func schedulePingTimer() {
        pingTimer?.invalidate()
        let interval = prefs.pingInterval
        let due = lastPingSent.map { max($0.addingTimeInterval(interval), Date()) } ?? Date().addingTimeInterval(interval)
        let timer = Timer(fire: due, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendPing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func hostChanged() {
        ledger.resetSite(to: allTimeStats[prefs.hostname] ?? StatCounter())
        ledger.resetSession()
        samples.removeAll()
        score = nil
        latestPingMs = nil
        lossPercent = 0
        lossIsKnown = false
        resolvedAddress = nil
        startError = nil
        stopPinging()
        pending.removeAll()
        resetEpisode(newHost: true)
    }

    func resetSessionStats() {
        ledger.resetSession()
    }

    func resetAllTimeStats() {
        ledger.resetSite()
        saveStats()
    }

    // MARK: - Pinging

    /// Runs one watchdog transition, then mirrors its status and performs its actions.
    private func drive(_ transition: (inout ConnectionWatchdog) -> [ConnectionWatchdog.Action]) {
        watchdog.alertsEnabled = prefs.showNotifications
        let actions = transition(&watchdog)
        if status != watchdog.status {
            status = watchdog.status
        }
        for action in actions {
            switch action {
            case .restartPinger:
                restartPinger()
            case .startTimedOut:
                // The lookup hangs: drop that pinger (its late result is ignored) so a retry can run.
                stopPinging()
                startError = .resolution("lookup timed out")
            case .announceDown:
                Notifier.shared.post(title: "Fivebars — Connection down", body: "Your internet connection seems to be down.")
            case .announceUp:
                Notifier.shared.post(title: "Fivebars — Connection restored", body: "Your internet connection has been restored.")
            }
        }
    }

    private func resetEpisode(newHost: Bool, restartAfter delay: TimeInterval = 0) {
        watchdog.config = Self.watchdogConfig(prefs)
        drive { $0.reset(at: MonotonicClock.now(), restartAfter: delay, newHost: newHost) }
    }

    private func stopPinging() {
        pingTimer?.invalidate()
        pingTimer = nil
        pinger?.stop()
        pinger = nil
    }

    /// Pending pings are kept: their replies still match (same identifier) on the new socket.
    private func restartPinger() {
        stopPinging()
        let pinger = Pinger(hostName: prefs.hostname, identifier: identifier, responseDeadline: prefs.pingTimeout)
        pinger.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.pinger = pinger
        pinger.start()
    }

    private func handle(_ event: Pinger.Event) {
        switch event {
        case .started(let address):
            resolvedAddress = address.display
            startError = nil
            watchdog.pingingStarted(at: MonotonicClock.now())
            sendPing()
            schedulePingTimer()
        case .switched(let address):
            resolvedAddress = address.display
        case .failed(let error):
            startError = error
            drive { $0.startFailed(at: MonotonicClock.now()) }
        case .reply(let id, let date):
            receivedReply(id: id, at: date)
        }
    }

    private func sendPing() {
        guard let pinger else { return }
        let id = nextPingId
        nextPingId += 1
        let now = Date()
        lastPingSent = now
        pinger.send(id: id)
        pending.append(PendingPing(id: id, sent: MonotonicClock.now()))
        samples.append(Sample(id: id, date: now))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.historyLength }
        // Like the original, pings sent while down are not counted.
        ledger.sent(id, counted: status != .down)
    }

    private func receivedReply(id: UInt64, at date: TimeInterval) {
        guard let index = pending.firstIndex(where: { $0.id == id }), pending[index].reply == nil else { return }
        pending[index].reply = date
        let rttMs = (date - pending[index].sent) * 1000
        if let sampleIndex = samples.lastIndex(where: { $0.id == id }) {
            samples[sampleIndex].rttMs = rttMs
        }

        drive { $0.replyReceived(at: date) }
        latestPingMs = rttMs
        ledger.replied(id, ms: rttMs, withinTimeout: rttMs <= prefs.pingTimeout * 1000)
    }

    // MARK: - Housekeeping

    private func tick() {
        guard !asleep else { return }
        let now = MonotonicClock.now()
        drive { $0.tick(at: now) }

        let evaluation = QualityScorer.evaluate(&pending, now: now, config: prefs.scoringConfig)
        for ping in evaluation.newlyLost {
            ledger.lost(ping.id)
            if let index = samples.lastIndex(where: { $0.id == ping.id }) {
                samples[index].lost = true
            }
        }
        ledger.retain(Set(pending.map(\.id)))
        lossIsKnown = !pending.isEmpty
        lossPercent = lossIsKnown ? evaluation.lossPercent : 0
        if let value = evaluation.score {
            score = value
        }

        tickCount += 1
        if tickCount >= Self.saveEveryTicks {
            tickCount = 0
            saveStats()
        }
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let key = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.pathSatisfied != satisfied {
                        self?.pathSatisfied = satisfied
                    }
                    self?.pathChanged(key)
                }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    private func willSleep() {
        asleep = true
        pathWork?.cancel()
        stopPinging()
        pending.removeAll()
    }

    private func didWake() {
        asleep = false
        // A new episode with grace: the link coming back is not an outage, a real one still is.
        resetEpisode(newHost: false, restartAfter: Self.wakeRestartDelay)
    }

    private func pathChanged(_ key: String) {
        defer { lastPathKey = key }
        guard let lastPathKey, lastPathKey != key, !asleep else { return }
        // Debounced; the watchdog spaces restarts and never interrupts a resolution.
        pathWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.asleep else { return }
                self.drive { $0.networkChanged(at: MonotonicClock.now()) }
            }
        }
        pathWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pathChangeDebounce, execute: work)
    }
}
