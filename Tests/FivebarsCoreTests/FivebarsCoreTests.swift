import Darwin
import Foundation
import Testing
@testable import FivebarsCore

private let config = ScoringConfig.original(slowPingThresholdMs: 100, timeout: 4)
private let now: TimeInterval = 1_000_000

private func ping(_ id: UInt64, sentAgo: TimeInterval, rtt: TimeInterval? = nil) -> PendingPing {
    let sent = now - sentAgo
    return PendingPing(id: id, sent: sent, reply: rtt.map { sent + $0 })
}

@Suite struct QualityScorerTests {
    @Test func fastRepliesScorePerfect() {
        var pending = (0..<10).map { ping(UInt64($0), sentAgo: Double(10 - $0), rtt: 0.02) }
        let result = QualityScorer.evaluate(&pending, now: now, config: config)
        #expect(result.score == 1)
        #expect(result.lossPercent == 0)
        #expect(QualityScorer.bars(for: result.score!) == 5)
    }

    @Test func latencyBetweenThresholdsScoresLinearly() {
        // Halfway between 100 ms and 1000 ms.
        var pending = [ping(1, sentAgo: 5, rtt: 0.55)]
        let result = QualityScorer.evaluate(&pending, now: now, config: config)
        #expect(abs(result.score! - 0.5) < 1e-9)
        #expect(QualityScorer.bars(for: result.score!) == 3)
    }

    @Test func youngUnansweredPingsAreNotScored() {
        var pending = [ping(1, sentAgo: 0.5)]
        let result = QualityScorer.evaluate(&pending, now: now, config: config)
        #expect(result.score == nil)
        #expect(result.lossPercent == 0)
    }

    @Test func slowUnansweredPingIsScoredByItsAge() {
        var pending = [ping(1, sentAgo: 2)]
        let result = QualityScorer.evaluate(&pending, now: now, config: config)
        #expect(abs(result.score! - (1 - 1.9 / 0.9)) < 1e-9)
        #expect(result.newlyLost.isEmpty)
    }

    @Test func timedOutPingIsLostOnce() {
        var pending = [ping(1, sentAgo: 5), ping(2, sentAgo: 1.5, rtt: 0.01)]
        let first = QualityScorer.evaluate(&pending, now: now, config: config)
        #expect(first.newlyLost.map(\.id) == [1])
        #expect(first.lossPercent == 50)
        #expect(pending[0].lost)

        let second = QualityScorer.evaluate(&pending, now: now, config: config)
        #expect(second.newlyLost.isEmpty)
        #expect(second.lossPercent == 50)
    }

    @Test func pingsOutsideTheWindowExpire() {
        var pending = [ping(1, sentAgo: 31, rtt: 0.01), ping(2, sentAgo: 2, rtt: 0.01)]
        _ = QualityScorer.evaluate(&pending, now: now, config: config)
        #expect(pending.map(\.id) == [2])
    }

    @Test func recentPingsWeighMore() {
        var oldLoss = [ping(1, sentAgo: 10), ping(2, sentAgo: 2, rtt: 0.01)]
        var newLoss = [ping(1, sentAgo: 10, rtt: 0.01), ping(2, sentAgo: 5)]
        let old = QualityScorer.evaluate(&oldLoss, now: now, config: config).score!
        let new = QualityScorer.evaluate(&newLoss, now: now, config: config).score!
        #expect(old > new)
        #expect(abs(old - (-2.5 + 1.2) / 2.2) < 1e-9)
    }

    @Test func barsMatchTheOriginalMapping() {
        #expect(QualityScorer.bars(for: -2.5) == 1)
        #expect(QualityScorer.bars(for: 0.19) == 1)
        #expect(QualityScorer.bars(for: 0.2) == 2)
        #expect(QualityScorer.bars(for: 0.79) == 4)
        #expect(QualityScorer.bars(for: 0.8) == 5)
        #expect(QualityScorer.bars(for: 1) == 5)
    }
}

@Suite struct StatCounterTests {
    @Test func tracksRunningStats() {
        var stats = StatCounter()
        for ms in [20.0, 40.0, 30.0] {
            stats.addPingSent()
            stats.addPingResponse(ms: ms)
        }
        stats.addPingSent()
        stats.addPingTimeout()
        #expect(stats.averageMs == 30)
        #expect(stats.fastestMs == 20)
        #expect(stats.slowestMs == 40)
        #expect(stats.lossPercent == 25)
    }

    @Test func lossPercentIsClamped() {
        var stats = StatCounter()
        stats.addPingSent()
        stats.addPingTimeout()
        stats.addPingTimeout()
        #expect(stats.lossPercent == 100)
    }

    @Test func storeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fivebars-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var stats = StatCounter()
        stats.addPingSent()
        let store = StatsStore(url: url)
        try store.save(["1.1.1.1": stats])
        #expect(store.load() == ["1.1.1.1": stats])
    }
}

@Suite struct PacketTests {
    @Test func checksumOfRequestVerifies() {
        let packet = Pinger.echoRequest(id: 42, identifier: 0xBEEF, family: AF_INET)
        #expect(Pinger.checksum(packet) == 0)
    }

    @Test func payloadIsTaggedWithTheMagic() {
        #expect(Pinger.magic == Array("FIVEBARS".utf8))
        #expect(Pinger.magic.count == 8)
        let packet = Pinger.echoRequest(id: 1, identifier: 1, family: AF_INET)
        #expect(Array(packet[8..<16]) == Pinger.magic)
    }

    @Test func parsesIPv4ReplyWithHeader() {
        var reply = Pinger.echoRequest(id: 70_000, identifier: 1, family: AF_INET)
        reply[0] = 0
        let ipHeader: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        #expect(Pinger.parseReply(ipHeader + reply, family: AF_INET, identifier: 1) == 70_000)
    }

    @Test func parsesIPv6Reply() {
        var reply = Pinger.echoRequest(id: 7, identifier: 1, family: AF_INET6)
        reply[0] = 129
        #expect(Pinger.parseReply(reply, family: AF_INET6, identifier: 1) == 7)
    }

    @Test func ignoresForeignPackets() {
        let request = Pinger.echoRequest(id: 7, identifier: 1, family: AF_INET6)
        #expect(Pinger.parseReply(request, family: AF_INET6, identifier: 1) == nil)
        #expect(Pinger.parseReply([0, 0, 0, 0, 0, 1, 0, 7] + [UInt8](repeating: 0, count: 16), family: AF_INET6, identifier: 1) == nil)
    }

    @Test func ignoresRepliesToAnotherIdentifier() {
        var reply = Pinger.echoRequest(id: 7, identifier: 0xBEEF, family: AF_INET6)
        reply[0] = 129
        #expect(Pinger.parseReply(reply, family: AF_INET6, identifier: 0xBEEF) == 7)
        #expect(Pinger.parseReply(reply, family: AF_INET6, identifier: 0xBEEE) == nil)
    }
}

@Suite struct AddressSelectorTests {
    @Test func movesOnAfterTheResponseDeadline() {
        var selector = AddressSelector(count: 2, deadline: 4)
        let rotations = (0...4).map { selector.sent(at: Double($0)) }
        #expect(rotations == [false, false, false, false, true])
        #expect(selector.index == 1)
    }

    @Test func keepsASlowAddressThatAnswers() {
        // RTT 2.5 s, one ping a second: a reply always lands before the 4 s deadline.
        var selector = AddressSelector(count: 2, deadline: 4)
        var rotations: [Bool] = []
        for second in 0..<20 {
            let t = Double(second)
            if t >= 3 {
                rotations.append(selector.replied(from: 0))
            }
            rotations.append(selector.sent(at: t))
        }
        #expect(!rotations.contains(true))
        #expect(selector.index == 0)
    }

    @Test func lateReplyFromThePreviousAddressReturnsToIt() {
        var selector = AddressSelector(count: 2, deadline: 4)
        for second in 0...4 {
            _ = selector.sent(at: Double(second))
        }
        #expect(selector.index == 1)
        let switched = selector.replied(from: 0)
        #expect(switched && selector.index == 0)
        // A reply from the current address only clears its deadline.
        let again = selector.replied(from: 0)
        #expect(!again)
    }

    @Test func movesOnWhenASendFailsAndWrapsAround() {
        var selector = AddressSelector(count: 2)
        let first = selector.sendFailed()
        #expect(first && selector.index == 1)
        let second = selector.sendFailed()
        #expect(second && selector.index == 0)
    }

    @Test func singleAddressNeverRotates() {
        var selector = AddressSelector(count: 1, deadline: 1)
        let rotations = [selector.sent(at: 0), selector.sent(at: 5), selector.sendFailed()]
        #expect(rotations == [false, false, false])
        #expect(selector.index == 0)
    }

    @Test func resolvesLiteralAddresses() throws {
        let addresses = try Pinger.resolve("127.0.0.1").get()
        #expect(addresses.map(\.display) == ["127.0.0.1"])
        #expect(addresses.first?.family == AF_INET)
    }
}

@Suite struct PingLedgerTests {
    @Test func resetWithPingsInFlightKeepsLossWithinSends() {
        var ledger = PingLedger()
        for id in 0..<5 as Range<UInt64> {
            ledger.sent(id, counted: true)
        }
        ledger.resetSession()
        for id in 0..<5 as Range<UInt64> {
            ledger.lost(id)
        }
        #expect(ledger.session.lost == 0)
        #expect(ledger.session.lossPercent == 0)
        #expect(ledger.site.lost == 5)
        #expect(ledger.site.lossPercent == 100)
    }

    @Test func uncountedSendsBookNoOutcome() {
        var ledger = PingLedger()
        ledger.sent(1, counted: false)
        ledger.replied(1, ms: 20, withinTimeout: true)
        ledger.sent(2, counted: true)
        ledger.replied(2, ms: 30, withinTimeout: true)
        #expect(ledger.session.sent == 1)
        #expect(ledger.session.replied == 1)
        #expect(ledger.session.averageMs == 30)
    }

    @Test func outcomesCountOnce() {
        var ledger = PingLedger()
        ledger.sent(1, counted: true)
        ledger.lost(1)
        ledger.replied(1, ms: 5000, withinTimeout: false)
        ledger.lost(1)
        #expect(ledger.session.lost == 1)
        #expect(ledger.session.replied == 0)
    }

    @Test func lateReplyBeforeHousekeepingIsBookedLost() {
        var ledger = PingLedger()
        ledger.sent(1, counted: true)
        ledger.replied(1, ms: 4200, withinTimeout: false)
        ledger.lost(1)
        #expect(ledger.session.lost == 1)
        #expect(ledger.session.replied == 0)
        #expect(ledger.site.lost == 1)
    }

    @Test func siteResetLoadsAnotherHost() {
        var saved = StatCounter()
        saved.addPingSent()
        var ledger = PingLedger()
        ledger.sent(1, counted: true)
        ledger.resetSite(to: saved)
        ledger.lost(1)
        #expect(ledger.site == saved)
        #expect(ledger.session.lost == 1)
    }
}

@Suite struct DownReasonTests {
    @Test func noNetworkPathWins() {
        #expect(DownReason(startError: .resolution("x"), pathSatisfied: false) == .noNetwork)
    }

    @Test func mapsStartErrors() {
        #expect(DownReason(startError: .resolution("nodename nor servname"), pathSatisfied: true) == .hostNotFound)
        #expect(DownReason(startError: .socket("EPERM"), pathSatisfied: true) == .socketError("EPERM"))
        #expect(DownReason(startError: nil, pathSatisfied: true) == .noReplies)
    }
}
