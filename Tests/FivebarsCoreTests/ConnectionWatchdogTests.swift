import Testing
@testable import FivebarsCore

private let watchdogConfig = ConnectionWatchdog.Config.original(timeout: 4, pingInterval: 1)

/// Drives a watchdog the way Monitor does and records everything it asks for.
private struct Harness {
    var dog: ConnectionWatchdog
    var now: Double = 0
    var restarts: [Double] = []
    var timeouts: [Double] = []
    var announcements: [(ConnectionWatchdog.Action, Double)] = []

    init(alerts: Bool = true) {
        dog = ConnectionWatchdog(config: watchdogConfig, now: 0)
        dog.alertsEnabled = alerts
        record(dog.reset(at: 0, newHost: true))
    }

    var downs: Int { announcements.filter { $0.0 == .announceDown }.count }
    var ups: Int { announcements.filter { $0.0 == .announceUp }.count }

    mutating func record(_ actions: [ConnectionWatchdog.Action]) {
        for action in actions {
            if action == .restartPinger {
                restarts.append(now)
            } else if action == .startTimedOut {
                timeouts.append(now)
            } else {
                announcements.append((action, now))
            }
        }
    }

    /// Advances time second by second, calling `each` before every housekeeping tick.
    mutating func run(until end: Double, each: (inout Harness) -> Void = { _ in }) {
        while now + 1 <= end + 1e-9 {
            now += 1
            each(&self)
            record(dog.tick(at: now))
        }
    }

    mutating func started() { dog.pingingStarted(at: now) }
    mutating func failed() { record(dog.startFailed(at: now)) }
    mutating func reply() { record(dog.replyReceived(at: now)) }
    mutating func networkChanged() { record(dog.networkChanged(at: now)) }

    /// A healthy link: pinging starts, then a reply every second until `end`.
    mutating func healthy(until end: Double) {
        started()
        reply()
        run(until: end) { $0.reply() }
    }
}

@Suite struct ConnectionWatchdogTests {
    @Test func outageIsDeclaredAndAnnouncedOnce() {
        var h = Harness()
        h.healthy(until: 20)
        #expect(h.dog.status == .up)
        h.run(until: 60)
        #expect(h.dog.status == .down)
        #expect(h.downs == 1)
        #expect(h.announcements.first?.1 == 29)
        h.reply()
        #expect(h.dog.status == .up)
        #expect(h.ups == 1)
        #expect(h.announcements.last?.0 == .announceUp)
    }

    @Test func restartsBackOffWhileDown() {
        var h = Harness()
        h.healthy(until: 20)
        h.restarts.removeAll()
        // Each restart resolves at once (IP literal), still no replies.
        h.run(until: 200) { if $0.dog.isResolving { $0.started() } }
        let gaps = zip(h.restarts.dropFirst(), h.restarts).map { $0 - $1 }
        // 8 s back-off doubled and capped at 15 s, counted from when each start finished (+1 s harness lag).
        #expect(h.restarts.first == 29)
        #expect(!gaps.isEmpty && gaps.allSatisfy { $0 == 16 })
    }

    @Test func pathChurnDuringOutageStillDeclaresDown() {
        var h = Harness()
        h.healthy(until: 10)
        // No more replies; the path flaps every 3 s and each restart re-resolves within a second.
        h.run(until: 60) { h in
            if Int(h.now) % 3 == 0 { h.networkChanged() }
            if h.dog.isResolving { h.started() }
        }
        #expect(h.dog.status == .down)
        #expect(h.downs == 1)
        #expect(h.announcements[0].1 <= 10 + watchdogConfig.replyTimeout + 1)
        // Restarts are spaced, never one per tick.
        let gaps = zip(h.restarts.dropFirst(), h.restarts).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= watchdogConfig.minRestartInterval })
    }

    @Test func pathChurnWithFailingDNSIsBoundedByMaxSilence() {
        var h = Harness()
        h.healthy(until: 10)
        h.run(until: 60) { h in
            if Int(h.now) % 3 == 0 { h.networkChanged() }
            if h.dog.isResolving { h.failed() }
        }
        #expect(h.downs == 1)
        #expect(h.announcements[0].1 <= 10 + watchdogConfig.maxSilence + 1)
    }

    @Test func slowResolutionIsNotRestartedAndEventuallyPings() {
        var h = Harness()
        #expect(h.restarts == [0])
        // Slower than the 8 s reply timeout, within the 10 s resolution timeout.
        h.run(until: 9)
        #expect(h.restarts == [0])
        #expect(h.dog.status == .starting)
        h.started()
        h.run(until: 10)
        h.reply()
        #expect(h.dog.status == .up)
        #expect(h.restarts == [0])
        #expect(h.announcements.isEmpty)
    }

    @Test func lookupSlowerThanTheTimeoutIsRetriedThenPings() {
        var h = Harness()
        h.run(until: 25)
        #expect(h.timeouts == [10])
        #expect(h.restarts == [0, 18])
        #expect(h.dog.status == .down)
        #expect(h.dog.isResolving)
        h.started()
        h.reply()
        #expect(h.dog.status == .up)
        #expect(h.announcements.isEmpty)
    }

    @Test func noAlertsWhenTheConnectionWasNeverUp() {
        var h = Harness()
        h.run(until: 120) { if $0.dog.isResolving { $0.failed() } }
        #expect(h.dog.status == .down)
        h.started()
        h.reply()
        #expect(h.announcements.isEmpty)
    }

    @Test func failedStartsDuringGraceAreRetried() {
        var h = Harness()
        h.failed()
        #expect(h.dog.status == .starting)
        h.run(until: 5) { if $0.dog.isResolving { $0.failed() } }
        #expect(h.dog.status == .starting)
        // The harness answers one second after each restart.
        #expect(h.restarts == [0, 2, 5])
        // Past the grace period a failed start is an outage, like the original.
        h.run(until: 12) { if $0.dog.isResolving { $0.failed() } }
        #expect(h.dog.status == .down)
    }

    @Test func wakeGraceThenRecoveryIsSilent() {
        var h = Harness()
        h.healthy(until: 100)
        h.record(h.dog.reset(at: h.now, restartAfter: 2, newHost: false))
        h.restarts.removeAll()
        h.run(until: 101)
        #expect(h.restarts.isEmpty)
        h.run(until: 102)
        #expect(h.restarts == [102])
        h.failed()
        h.run(until: 105) { if $0.dog.isResolving { $0.started() } }
        h.reply()
        #expect(h.dog.status == .up)
        #expect(h.announcements.isEmpty)
    }

    @Test func realOutageAfterWakeIsAnnouncedOnce() {
        var h = Harness()
        h.healthy(until: 100)
        h.record(h.dog.reset(at: h.now, restartAfter: 2, newHost: false))
        h.run(until: 160) { if $0.dog.isResolving { $0.started() } }
        #expect(h.downs == 1)
        #expect(h.announcements[0].1 <= 102 + watchdogConfig.replyTimeout + 2)
    }

    @Test func downAnnouncedBeforeSleepIsPairedWithUpAfterWake() {
        var h = Harness()
        h.healthy(until: 10)
        h.run(until: 30)
        #expect(h.downs == 1)
        h.record(h.dog.reset(at: h.now, restartAfter: 2, newHost: false))
        h.run(until: 34) { if $0.dog.isResolving { $0.started() } }
        h.reply()
        #expect(h.downs == 1)
        #expect(h.ups == 1)
    }

    @Test func newHostForgetsConfirmation() {
        var h = Harness()
        h.healthy(until: 10)
        h.record(h.dog.reset(at: h.now, newHost: true))
        h.run(until: 60) { if $0.dog.isResolving { $0.started() } }
        #expect(h.dog.status == .down)
        #expect(h.announcements.isEmpty)
    }

    @Test func alertsOffMeansNoAnnouncements() {
        var h = Harness(alerts: false)
        h.healthy(until: 10)
        h.run(until: 40)
        h.dog.alertsEnabled = true
        h.reply()
        #expect(h.announcements.isEmpty)
    }

    @Test func slowLookupAfterAPathChangeGetsAFullReplyWindow() {
        var h = Harness()
        h.healthy(until: 10)
        h.now = 11
        h.networkChanged()
        #expect(h.restarts.last == 11)
        // The lookup takes 9 s: the connection is declared down meanwhile, with an 8 s back-off.
        h.run(until: 20)
        #expect(h.dog.status == .down)
        h.started()
        h.run(until: 22)
        #expect(h.restarts.last == 11)
        h.reply()
        #expect(h.dog.status == .up)
    }

    @Test func hungLookupIsAbandonedAndRetried() {
        var h = Harness()
        h.run(until: 30)
        #expect(h.timeouts.first == watchdogConfig.resolutionTimeout)
        #expect(h.restarts.count > 1)
    }

    @Test func upIsNotAnnouncedWhenAlertsWereTurnedOffDuringTheOutage() {
        var h = Harness()
        h.healthy(until: 10)
        h.run(until: 30)
        #expect(h.downs == 1)
        h.dog.alertsEnabled = false
        h.reply()
        #expect(h.ups == 0)
        // And a later outage + recovery with alerts back on pairs normally.
        h.dog.alertsEnabled = true
        h.run(until: 40) { $0.reply() }
        h.run(until: 60)
        h.reply()
        #expect(h.downs == 2)
        #expect(h.ups == 1)
    }

    @Test func failingDNSIsRetriedAtLeastEvery15Seconds() {
        var h = Harness()
        h.healthy(until: 10)
        h.restarts.removeAll()
        h.run(until: 200) { if $0.dog.isResolving { $0.failed() } }
        let gaps = zip(h.restarts.dropFirst(), h.restarts).map { $0 - $1 }
        #expect(gaps.count > 5)
        #expect(gaps.allSatisfy { $0 <= 16 })
    }
}
