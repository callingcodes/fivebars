import Foundation

/// The menu bar title, kept to one fixed width: the ping is always 4 characters, "48ms" below
/// 100 ms and "0.1s" to "9.9s" from there up.
public enum MenuBarTitle {
    public static let failed = "Failed"
    public static let waiting = "…"

    /// "48ms" while the ping rounds to under 100 ms, then seconds with one decimal, clamped to "9.9s".
    public static func ping(_ milliseconds: Double) -> String {
        let ms = max(0, milliseconds)
        let whole = Int(ms.rounded())
        if whole < 100 {
            return "\(whole)ms"
        }
        let tenths = min(99, max(1, Int((ms / 100).rounded())))
        return "\(tenths / 10).\(tenths % 10)s"
    }

    /// When the menu bar shows the packet loss after the ping.
    public enum LossMode: String, CaseIterable, Sendable {
        case off
        /// Only while packets are being lost, and for `HoldGate.lossSuffix()`'s hold after.
        case whenLossy
        case always
    }

    /// Opens as soon as its condition holds and closes only once the condition has been false for
    /// `holdSeconds`, so a brief change doesn't make the title (and the neighbouring menu bar
    /// icons) flap.
    public struct HoldGate: Sendable {
        public let holdSeconds: Double
        public private(set) var isOpen = false
        private var lastActiveAt: Double?

        public init(holdSeconds: Double) {
            self.holdSeconds = holdSeconds
        }

        /// `now` is any monotonic clock in seconds.
        public mutating func update(active: Bool, now: Double) -> Bool {
            if active {
                lastActiveAt = now
                isOpen = true
            } else if isOpen, let lastActiveAt, now - lastActiveAt < holdSeconds {
                isOpen = true
            } else {
                isOpen = false
                lastActiveAt = nil
            }
            return isOpen
        }

        /// `.whenLossy`: the suffix shows while the loss is above 0, and 10 s after.
        public static func lossSuffix() -> HoldGate { HoldGate(holdSeconds: 10) }
        /// Room for a two-digit loss from 10 %, kept until it has been under 10 % for 30 s.
        public static func twoDigitLoss() -> HoldGate { HoldGate(holdSeconds: 30) }
    }

    /// The loss as the suffix shows it. Next to a ping it tops out at 99 %: a whole window without a
    /// reply has already declared the connection down, which shows "Failed" instead.
    public static func displayedLoss(_ percent: Double) -> Int {
        Int(min(99, max(0, percent)).rounded())
    }

    /// Whether the title carries the loss suffix, which also decides the width to reserve.
    public static func showsLoss(mode: LossMode, gateOpen: Bool) -> Bool {
        switch mode {
        case .off: false
        case .whenLossy: gateOpen
        case .always: true
        }
    }

    /// " (4%)", appended to the ping when packet loss text is on.
    public static func lossSuffix(_ percent: Double) -> String {
        " (\(displayedLoss(percent))%)"
    }

    public static func title(pingMs: Double, lossPercent: Double?) -> String {
        ping(pingMs) + (lossPercent.map(lossSuffix) ?? "")
    }

    /// Every shape the title can take at its widest, for measuring the width to reserve. With
    /// monospaced digits, one digit stands for all of them. `lossDigits` is nil without the
    /// suffix, else the number of digits to make room for (1 or 2).
    public static func widestCandidates(lossDigits: Int?) -> [String] {
        let pings = ["88ms", "8.8s"]
        let suffix = lossDigits.map { " (" + String(repeating: "8", count: min(2, max(1, $0))) + "%)" } ?? ""
        return pings.map { $0 + suffix } + [failed, waiting]
    }
}
