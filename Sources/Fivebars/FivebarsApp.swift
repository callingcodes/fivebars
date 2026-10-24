import AppKit
import FivebarsCore
import ServiceManagement
import SwiftUI
import UserNotifications

@main
@MainActor
enum FivebarsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = Monitor(prefs: Preferences())
        Notifier.shared.configure()
        statusItem = StatusItemController(monitor: monitor, updater: updater) { [weak self] in
            self?.showSettings()
        }
        monitor.start()
        self.monitor = monitor
        saveStatsOnTerminationSignals()
    }

    /// `kill`/`pkill` (SIGTERM) and Ctrl-C (SIGINT) skip applicationWillTerminate: save first, then exit.
    private func saveStatsOnTerminationSignals() {
        for signo in [SIGTERM, SIGINT] {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.monitor?.saveStats()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.saveStats()
    }

    private func showSettings() {
        guard let monitor else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(monitor: monitor, updater: updater)))
            window.title = "Fivebars Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Replaces the original's sandboxed login-item helper app.
enum LaunchAtLogin {
    /// Registered, including while waiting for approval in System Settings: the toggle shows on, and
    /// turning it off then really unregisters (`.requiresApproval` used to be treated as off).
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        let registered = isEnabled
        if enabled && !registered {
            try SMAppService.mainApp.register()
        } else if !enabled && registered {
            try SMAppService.mainApp.unregister()
        }
    }
}
