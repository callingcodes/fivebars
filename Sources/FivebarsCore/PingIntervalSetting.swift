import Foundation

/// The "Ping Every" setting: whole seconds from 1 to 60, 1 by default.
public enum PingIntervalSetting {
    public static let range: ClosedRange<Int> = 1...60
    public static let defaultSeconds = 1

    /// Rounds to whole seconds and clamps to 1...60. Stored values from older builds or hand edits
    /// (0, negative, fractional, huge) land on the nearest valid value; NaN falls back to the default.
    public static func clamped(_ seconds: Double) -> Int {
        if seconds.isNaN { return defaultSeconds }
        guard seconds.isFinite else { return seconds > 0 ? range.upperBound : range.lowerBound }
        return min(max(Int(seconds.rounded()), range.lowerBound), range.upperBound)
    }

    /// The value typed in the field, clamped, or nil when the text is not a number (the field
    /// then reverts to the last valid value).
    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else { return nil }
        return clamped(value)
    }
}
