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

    /// " (4%)", appended to the ping when packet loss text is on.
    public static func lossSuffix(_ percent: Double) -> String {
        " (\(Int(min(100, max(0, percent)).rounded()))%)"
    }

    public static func title(pingMs: Double, lossPercent: Double?) -> String {
        ping(pingMs) + (lossPercent.map(lossSuffix) ?? "")
    }

    /// Every shape the title can take at its widest, for measuring the width to reserve. With
    /// monospaced digits, one digit stands for all of them.
    public static func widestCandidates(showsLoss: Bool) -> [String] {
        let pings = ["88ms", "8.8s"]
        let suffix = showsLoss ? lossSuffix(100) : ""
        return pings.map { $0 + suffix } + [failed, waiting]
    }
}
