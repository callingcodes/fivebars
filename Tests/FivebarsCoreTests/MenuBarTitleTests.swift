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
        #expect(MenuBarTitle.title(pingMs: 1234, lossPercent: 100) == "1.2s (100%)")
        #expect(MenuBarTitle.title(pingMs: 48, lossPercent: nil) == "48ms")
    }

    @Test func widestCandidatesIncludeTheLongestLossSuffix() {
        #expect(MenuBarTitle.widestCandidates(showsLoss: true).contains("8.8s (100%)"))
        #expect(!MenuBarTitle.widestCandidates(showsLoss: false).contains { $0.contains("%") })
    }
}
