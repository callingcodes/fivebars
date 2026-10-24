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
    static let defaultPingInterval = TimeInterval(PingIntervalSetting.defaultSeconds)

    private static let defaultValues: [String: Any] = [
        Key.hostname: "1.1.1.1",
        Key.pingTimeout: 4.0,
        Key.pingInterval: defaultPingInterval,
        Key.slowPingThreshold: 100.0,
        Key.showIcon: true,
        Key.showText: true,
        Key.showNotifications: false,
    ]

    private enum Key {
        static let hostname = "Hostname"
        static let pingTimeout = "PingTimeout"
        static let pingInterval = "PingInterval"
        static let slowPingThreshold = "SlowPingLowThreshold"
        static let showIcon = "ShowIcon"
        static let showText = "ShowText"
        /// The original app's on/off switch, read once to carry an existing choice over.
        static let showPacketLossText = "ShowPacketLossText"
        static let lossTextMode = "PacketLossTextMode"
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

    /// Seconds between pings, always a whole number from 1 to 60.
    var pingInterval: TimeInterval {
        didSet { defaults.set(pingInterval, forKey: Key.pingInterval) }
    }

    var display: Display {
        didSet {
            defaults.set(display.showsIcon, forKey: Key.showIcon)
            defaults.set(display.showsText, forKey: Key.showText)
        }
    }

    var lossTextMode: MenuBarTitle.LossMode {
        didSet { defaults.set(lossTextMode.rawValue, forKey: Key.lossTextMode) }
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
        pingInterval = Self.validPingInterval(defaults.double(forKey: Key.pingInterval))
        let showIcon = defaults.bool(forKey: Key.showIcon)
        let showText = defaults.bool(forKey: Key.showText)
        display = showIcon && showText ? .iconAndText : (showIcon ? .iconOnly : .textOnly)
        lossTextMode = Self.storedLossTextMode(defaults)
        showNotifications = defaults.bool(forKey: Key.showNotifications)
    }

    var scoringConfig: ScoringConfig {
        .original(slowPingThresholdMs: slowPingThresholdMs, timeout: pingTimeout, pingInterval: pingInterval)
    }

    /// Any stored value is rounded and clamped to 1...60 (see PingIntervalSetting).
    static func validPingInterval(_ value: TimeInterval) -> TimeInterval {
        TimeInterval(PingIntervalSetting.clamped(value))
    }

    /// New users get "When There's Loss"; someone who had the old switch keeps what it did:
    /// on means always, off means off.
    static func storedLossTextMode(_ defaults: UserDefaults) -> MenuBarTitle.LossMode {
        if let raw = defaults.string(forKey: Key.lossTextMode), let mode = MenuBarTitle.LossMode(rawValue: raw) {
            return mode
        }
        if let legacy = defaults.object(forKey: Key.showPacketLossText) as? Bool {
            return legacy ? .always : .off
        }
        return .whenLossy
    }

    func restoreDefaults() {
        for key in Self.defaultValues.keys + [Key.lossTextMode, Key.showPacketLossText] {
            defaults.removeObject(forKey: key)
        }
        let fresh = Preferences(defaults: defaults)
        hostname = fresh.hostname
        slowPingThresholdMs = fresh.slowPingThresholdMs
        pingTimeout = fresh.pingTimeout
        pingInterval = fresh.pingInterval
        display = fresh.display
        lossTextMode = fresh.lossTextMode
        showNotifications = fresh.showNotifications
    }
}
