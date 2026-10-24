import FivebarsCore
import Foundation
import Observation

/// User settings, stored under the same UserDefaults keys as the original app.
@MainActor
@Observable
final class Preferences {
    enum Display: Int, CaseIterable, Identifiable {
        case iconAndText
        case iconOnly
        case textOnly

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .iconAndText: "Icon and Text"
            case .iconOnly: "Icon Only"
            case .textOnly: "Text Only"
            }
        }

        var showsIcon: Bool { self != .textOnly }
        var showsText: Bool { self != .iconOnly }
    }

    static let slowPingRange: ClosedRange<Double> = 50...2000

    private static let defaultValues: [String: Any] = [
        Key.hostname: "1.1.1.1",
        Key.pingTimeout: 4.0,
        Key.slowPingThreshold: 100.0,
        Key.showIcon: true,
        Key.showText: true,
        Key.showPacketLossText: false,
        Key.showNotifications: false,
    ]

    private enum Key {
        static let hostname = "Hostname"
        static let pingTimeout = "PingTimeout"
        static let slowPingThreshold = "SlowPingLowThreshold"
        static let showIcon = "ShowIcon"
        static let showText = "ShowText"
        static let showPacketLossText = "ShowPacketLossText"
        static let showNotifications = "ShowNotifications"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var hostname: String {
        didSet { defaults.set(hostname, forKey: Key.hostname) }
    }

    var slowPingThresholdMs: Double {
        didSet { defaults.set(slowPingThresholdMs, forKey: Key.slowPingThreshold) }
    }

    var pingTimeout: TimeInterval {
        didSet { defaults.set(pingTimeout, forKey: Key.pingTimeout) }
    }

    var display: Display {
        didSet {
            defaults.set(display.showsIcon, forKey: Key.showIcon)
            defaults.set(display.showsText, forKey: Key.showText)
        }
    }

    var showPacketLossText: Bool {
        didSet { defaults.set(showPacketLossText, forKey: Key.showPacketLossText) }
    }

    var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: Key.showNotifications) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.defaultValues)
        hostname = defaults.string(forKey: Key.hostname) ?? "1.1.1.1"
        slowPingThresholdMs = defaults.double(forKey: Key.slowPingThreshold)
        pingTimeout = defaults.double(forKey: Key.pingTimeout)
        let showIcon = defaults.bool(forKey: Key.showIcon)
        let showText = defaults.bool(forKey: Key.showText)
        display = showIcon && showText ? .iconAndText : (showIcon ? .iconOnly : .textOnly)
        showPacketLossText = defaults.bool(forKey: Key.showPacketLossText)
        showNotifications = defaults.bool(forKey: Key.showNotifications)
    }

    var scoringConfig: ScoringConfig {
        .original(slowPingThresholdMs: slowPingThresholdMs, timeout: pingTimeout)
    }

    func restoreDefaults() {
        for key in Self.defaultValues.keys {
            defaults.removeObject(forKey: key)
        }
        let fresh = Preferences(defaults: defaults)
        hostname = fresh.hostname
        slowPingThresholdMs = fresh.slowPingThresholdMs
        pingTimeout = fresh.pingTimeout
        display = fresh.display
        showPacketLossText = fresh.showPacketLossText
        showNotifications = fresh.showNotifications
    }
}
