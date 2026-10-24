import AppKit
import Sparkle

/// Software updates through Sparkle 2. The feed, the public EdDSA key and the defaults (daily automatic
/// checks, install only when the user agrees, no system profile) live in Info.plist.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    /// Sparkle needs a real app bundle (Info.plist keys, a place to install to); `swift run` has none.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    override init() {
        super.init()
        guard Self.isAvailable else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        controller.updater.userAgentString = Self.userAgent
        controller.startUpdater()
        self.controller = controller
    }

    /// "Fivebars/2.0.1 Sparkle/2.10.0 macOS/15.1": callingcodes.com counts update checks per app and
    /// macOS version from this header alone (no identifier, no system profile).
    private static var userAgent: String {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let sparkle = Bundle(for: SPUUpdater.self).object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "2"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Fivebars/\(app) Sparkle/\(sparkle) macOS/\(os.majorVersion).\(os.minorVersion)"
    }

    private var updater: SPUUpdater? { controller?.updater }

    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    @objc func checkForUpdates(_ sender: Any?) {
        Self.bringSparkleToFront()
        controller?.checkForUpdates(sender)
        Self.bringSparkleToFront(after: 0.2)
    }

    /// A menu bar (accessory) app is never frontmost, and macOS 14's cooperative activation may
    /// decline a plain activate(): activate, then order Sparkle's windows front regardless.
    static func bringSparkleToFront(after delay: TimeInterval = 0) {
        let raise = {
            NSApp.activate()
            for window in NSApp.windows where window.isVisible && isSparkleWindow(window) {
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
        if delay == 0 {
            raise()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated(raise)
            }
        }
    }

    private static func isSparkleWindow(_ window: NSWindow) -> Bool {
        guard let controller = window.windowController else { return false }
        return Bundle(for: type(of: controller)) == Bundle(for: SPUUpdater.self)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { updater?.lastUpdateCheckDate }

    // MARK: SPUStandardUserDriverDelegate

    /// Fivebars is a menu bar (LSUIElement) app: scheduled update alerts must not jump in front of
    /// whatever the user is doing. Sparkle shows them without stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A background app is not frontmost; bring the update window forward when Sparkle shows it.
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated {
            // Sparkle creates the window after this call: raise it once it exists.
            Self.bringSparkleToFront()
            Self.bringSparkleToFront(after: 0.2)
        }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated {
            Self.bringSparkleToFront()
        }
    }

    /// Show a found update right away, in focus, rather than waiting for a gentle reminder moment.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }
}
