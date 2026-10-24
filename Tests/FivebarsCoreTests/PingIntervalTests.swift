import Testing
@testable import FivebarsCore

/// The ping interval is a setting (whole seconds, 1 to 60). At 1 s every timing must match the
/// original exactly; slower intervals stretch the window and the watchdog.
@Suite struct PingIntervalTests {
    @Test func oneSecondMatchesTheOriginalExactly() {
        let config = ScoringConfig.original(slowPingThresholdMs: 100, timeout: 4, pingInterval: 1)
        #expect(config == ScoringConfig.original(slowPingThresholdMs: 100, timeout: 4))
        #expect(config.averageOver == 30)

        let dog = ConnectionWatchdog.Config.original(timeout: 4, pingInterval: 1)
        #expect(dog.replyTimeout == 8)
        #expect(dog.maxSilence == 20)
        #expect(dog.maxRestartInterval == 15)
        #expect(dog.minRestartInterval == 2)
        #expect(dog.grace == 10)
    }

    @Test(arguments: [
        (1.0, 30.0), (2.0, 30.0), (3.0, 30.0), (5.0, 50.0), (7.0, 70.0), (10.0, 100.0), (15.0, 150.0),
        (30.0, 300.0), (45.0, 450.0), (60.0, 600.0),
    ])
    func windowKeepsAtLeastTenPings(interval: Double, window: Double) {
        #expect(ScoringConfig.averagingWindow(pingInterval: interval) == window)
        let config = ScoringConfig.original(slowPingThresholdMs: 100, timeout: 4, pingInterval: interval)
        #expect(config.averageOver == window)
        #expect(config.averageOver / interval >= 10)
    }

    @Test(arguments: [
        (1.0, 8.0), (2.0, 12.0), (3.0, 16.0), (5.0, 24.0), (7.0, 32.0), (10.0, 44.0), (15.0, 64.0),
        (30.0, 64.0), (45.0, 94.0), (60.0, 124.0),
    ])
    func replyTimeoutMissesTwoToFourPings(interval: Double, replyTimeout: Double) {
        let dog = ConnectionWatchdog.Config.original(timeout: 4, pingInterval: interval)
        #expect(dog.replyTimeout == replyTimeout)
        let missed = (dog.replyTimeout - 4) / interval
        #expect(missed >= 2 && missed <= 4)
        #expect(dog.maxSilence == replyTimeout + 12)
        #expect(dog.maxRestartInterval == max(15, interval))
    }

    /// Ten pings 5 s apart: all ten stay in the 50 s window, and the 1.2x weighting is per ping,
    /// so a loss on the newest ping costs as much as it does at 1 s.
    @Test func slowIntervalScoresTheSameSequenceLikeOneSecond() {
        let now = 1_000.0
        func pings(every interval: Double) -> [PendingPing] {
            (0..<10).map { index in
                let sent = now - Double(10 - index) * interval
                // The newest ping is lost (no reply, well past the timeout); the rest are perfect.
                let reply: Double? = index == 9 ? nil : sent + 0.02
                return PendingPing(id: UInt64(index), sent: sent, reply: reply)
            }
        }
        var fast = pings(every: 1)
        var slow = pings(every: 5)
        // At 1 s the newest ping is only 1 s old; age it past the timeout like the 5 s one.
        fast[9] = PendingPing(id: 9, sent: now - 5)
        let fastResult = QualityScorer.evaluate(
            &fast, now: now, config: .original(slowPingThresholdMs: 100, timeout: 4, pingInterval: 1)
        )
        let slowResult = QualityScorer.evaluate(
            &slow, now: now, config: .original(slowPingThresholdMs: 100, timeout: 4, pingInterval: 5)
        )
        #expect(slow.count == 10)
        #expect(slowResult.lossPercent == 10)
        #expect(slowResult.score == fastResult.score)
        #expect(slowResult.newlyLost.map(\.id) == [9])
    }

    /// With the original 30 s window, pings every 30 s would leave one or two pings to score.
    @Test func slowIntervalWindowDropsOnlyOldPings() {
        let now = 10_000.0
        var pending = (0..<12).map { index in
            let sent = now - Double(12 - index) * 30
            return PendingPing(id: UInt64(index), sent: sent, reply: sent + 0.02)
        }
        let result = QualityScorer.evaluate(
            &pending, now: now, config: .original(slowPingThresholdMs: 100, timeout: 4, pingInterval: 30)
        )
        // Ages 360 s and 330 s fall out of the 300 s window; 300 s is still in.
        #expect(pending.map(\.id) == Array(2..<12))
        #expect(result.score == 1)
        #expect(result.lossPercent == 0)
    }

    @Test func slowIntervalDeclaresDownAfterItsReplyTimeout() {
        let config = ConnectionWatchdog.Config.original(timeout: 4, pingInterval: 30)
        var dog = ConnectionWatchdog(config: config, now: 0)
        dog.alertsEnabled = true
        _ = dog.reset(at: 0, newHost: true)
        dog.pingingStarted(at: 1)
        _ = dog.replyReceived(at: 1.02)
        // Two pings 30 s apart unanswered is not yet an outage at 30 s...
        _ = dog.tick(at: 60)
        #expect(dog.status != .down)
        // ...but past timeout + 60 s it is.
        _ = dog.tick(at: 1.02 + config.replyTimeout + 1)
        #expect(dog.status == .down)
    }

    @Test(arguments: [
        (1.0, 1), (3.0, 3), (7.0, 7), (15.0, 15), (45.0, 45), (60.0, 60),
        (0.0, 1), (-5.0, 1), (120.0, 60), (2.4, 2), (2.6, 3), (Double.nan, 1), (Double.infinity, 60),
    ])
    func storedValuesClampToWholeSecondsFromOneToSixty(stored: Double, seconds: Int) {
        #expect(PingIntervalSetting.clamped(stored) == seconds)
    }

    @Test func typedTextClampsOrReverts() {
        #expect(PingIntervalSetting.parse("5") == 5)
        #expect(PingIntervalSetting.parse(" 45 ") == 45)
        #expect(PingIntervalSetting.parse("0") == 1)
        #expect(PingIntervalSetting.parse("120") == 60)
        #expect(PingIntervalSetting.parse("") == nil)
        #expect(PingIntervalSetting.parse("abc") == nil)
        #expect(PingIntervalSetting.parse("5s") == nil)
    }
}
