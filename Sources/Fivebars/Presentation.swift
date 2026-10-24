import AppKit
import SwiftUI

/// How the UI words and colours the monitor's state. Shared by the menu bar item, its menu and the popover.
enum QualityTone {
    case neutral
    case good
    case warn
    case bad

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .good: LatencyPalette.good
        case .warn: LatencyPalette.warn
        case .bad: LatencyPalette.bad
        }
    }
}

/// Data colours that keep their contrast on the translucent popover in both appearances.
/// Raw `.yellow`/`.green` wash out on a light, wallpaper-tinted popover.
enum LatencyPalette {
    static let good = dynamic(light: NSColor(srgbRed: 0.14, green: 0.54, blue: 0.24, alpha: 1), dark: .systemGreen)
    static let warn = dynamic(light: NSColor(srgbRed: 0.76, green: 0.42, blue: 0, alpha: 1), dark: .systemOrange)
    static let bad = dynamic(light: NSColor(srgbRed: 0.77, green: 0.16, blue: 0.11, alpha: 1), dark: .systemRed)

    /// Same bands as the scorer: perfect up to the threshold, then degrading to zero at threshold + 900 ms.
    static func tone(forRtt rtt: Double, lowThreshold: Double, highThreshold: Double) -> QualityTone {
        if rtt <= lowThreshold {
            return .good
        }
        return rtt <= (lowThreshold + highThreshold) / 2 ? .warn : .bad
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum Format {
    /// "46 ms" below 100 ms keeps a decimal for stats ("61.3 ms"); whole numbers above.
    static func statMs(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f ms", value) : String(format: "%.1f ms", value)
    }

    static func wholeMs(_ value: Double) -> String {
        "\(Int(value.rounded())) ms"
    }

    static func percent(_ value: Double) -> String {
        value == 0 ? "0%" : String(format: "%.1f%%", value)
    }
}

extension Monitor {
    var isConnecting: Bool {
        status == .starting && score == nil
    }

    var qualityTitle: String {
        if isConnecting {
            return "Connecting…"
        }
        if status == .down {
            return "Connection down"
        }
        switch bars {
        case 5: return "Excellent"
        case 4: return "Good"
        case 3: return "Fair"
        case 2: return "Poor"
        default: return "Very poor"
        }
    }

    var qualityTone: QualityTone {
        if isConnecting {
            return .neutral
        }
        if status == .down {
            return .bad
        }
        switch bars {
        case 4...: return .good
        case 2...3: return .warn
        default: return .bad
        }
    }

    /// A short, human reason for the down state. The raw error text stays in `lastError` for the tooltip.
    var downReasonText: String {
        switch downReason ?? .noReplies {
        case .hostNotFound:
            return "Can’t find host “\(prefs.hostname)”"
        case .noNetwork:
            return "No network connection"
        case .noReplies:
            return "No replies for \(Int(replyTimeout)) s"
        case .socketError:
            return "Can’t open a ping socket"
        }
    }

    /// Whether the loss figure means anything yet.
    var showsLoss: Bool {
        lossIsKnown && !isConnecting
    }

    /// Spoken by VoiceOver for the menu bar item.
    var accessibilitySummary: String {
        if status == .down {
            return "Connection down, \(downReasonText)"
        }
        guard let latestPingMs, !isConnecting else { return "Connecting" }
        let loss = lossIsKnown ? ", \(Int(lossPercent.rounded())) percent packet loss" : ""
        return "\(qualityTitle), \(Int(latestPingMs.rounded())) milliseconds\(loss)"
    }

}
