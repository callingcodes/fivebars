import Testing
@testable import FivebarsCore

@Suite struct MenuBarTitleTests {
    @Test(arguments: [
        (0.0, "0ms"),
        (5, "5ms"),
        (48, "48ms"),
        (99.4, "99ms"),
        (99.6, "0.1s"),
        (100, "0.1s"),
        (149, "0.1s"),
        (150, "0.2s"),
        (400, "0.4s"),
        (1234, "1.2s"),
        (9949, "9.9s"),
        (9950, "9.9s"),
        (20000, "9.9s"),
    ])
    func formatsThePing(milliseconds: Double, expected: String) {
        #expect(MenuBarTitle.ping(milliseconds) == expected)
    }

    @Test func pingsFromOneHundredMillisecondsAreAlwaysFourCharacters() {
        for ms in stride(from: 99.5, through: 20000, by: 0.5) {
            #expect(MenuBarTitle.ping(ms).count == 4)
        }
    }

    @Test func appendsTheLossWhenGiven() {
        #expect(MenuBarTitle.title(pingMs: 48, lossPercent: 4.4) == "48ms (4%)")
        #expect(MenuBarTitle.title(pingMs: 1234, lossPercent: 100) == "1.2s (99%)")
        #expect(MenuBarTitle.title(pingMs: 48, lossPercent: 99.6) == "48ms (99%)")
        #expect(MenuBarTitle.title(pingMs: 48, lossPercent: nil) == "48ms")
    }

    @Test func widestCandidatesMakeRoomForTheRequestedLossDigits() {
        #expect(MenuBarTitle.widestCandidates(lossDigits: 1).contains("8.8s (8%)"))
        #expect(MenuBarTitle.widestCandidates(lossDigits: 2).contains("8.8s (88%)"))
        #expect(!MenuBarTitle.widestCandidates(lossDigits: 2).contains { $0.contains("100") })
        #expect(!MenuBarTitle.widestCandidates(lossDigits: nil).contains { $0.contains("%") })
    }

    @Test func lossModeDecidesTheSuffix() {
        #expect(!MenuBarTitle.showsLoss(mode: .off, gateOpen: true))
        #expect(MenuBarTitle.showsLoss(mode: .always, gateOpen: false))
        #expect(MenuBarTitle.showsLoss(mode: .whenLossy, gateOpen: true))
        #expect(!MenuBarTitle.showsLoss(mode: .whenLossy, gateOpen: false))
    }

    @Test func gateStaysClosedWithoutLoss() {
        var gate = MenuBarTitle.HoldGate.lossSuffix()
        var open: Bool
        open = gate.update(active: false, now: 0)
        #expect(!open)
        open = gate.update(active: false, now: 1)
        #expect(!open)
    }

    @Test func gateOpensOnLossAndHoldsTenSecondsAfterRecovery() {
        var gate = MenuBarTitle.HoldGate.lossSuffix()
        var open: Bool
        open = gate.update(active: true, now: 100)
        #expect(open)
        open = gate.update(active: true, now: 105)
        #expect(open)
        open = gate.update(active: false, now: 106)
        #expect(open)
        open = gate.update(active: false, now: 114.9)
        #expect(open)
        open = gate.update(active: false, now: 115)
        #expect(!open)
        open = gate.update(active: false, now: 130)
        #expect(!open)
    }

    @Test func newLossDuringTheHoldRestartsIt() {
        var gate = MenuBarTitle.HoldGate.lossSuffix()
        var open: Bool
        open = gate.update(active: true, now: 0)
        #expect(open)
        open = gate.update(active: false, now: 8)
        #expect(open)
        open = gate.update(active: true, now: 9)
        #expect(open)
        open = gate.update(active: false, now: 18)
        #expect(open)
        open = gate.update(active: false, now: 19)
        #expect(!open)
    }

    @Test func twoDigitGateHoldsThirtySeconds() {
        var gate = MenuBarTitle.HoldGate.twoDigitLoss()
        var open: Bool
        open = gate.update(active: MenuBarTitle.displayedLoss(12) >= 10, now: 0)
        #expect(open)
        open = gate.update(active: MenuBarTitle.displayedLoss(9.4) >= 10, now: 29.9)
        #expect(open)
        open = gate.update(active: false, now: 30)
        #expect(!open)
    }

    @Test func lossModeRawValuesAreStable() {
        #expect(MenuBarTitle.LossMode.allCases.map(\.rawValue) == ["off", "whenLossy", "always"])
    }
}
