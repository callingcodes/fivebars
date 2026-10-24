import AppKit
import FivebarsCore
import Observation
import SwiftUI

/// The menu bar item: left click opens the stats popover, right click shows a small menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let monitor: Monitor
    private let updater: Updater
    private let openSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    /// Last values written to the button, so an unchanged second costs no redraw.
    private var appliedImage: NSImage?
    private var appliedContentKey: String?
    private var appliedToolTip: String?
    private var appliedAccessibility: String?
    /// Width reserved for the text: the widest title the current display settings can produce,
    /// measured once per settings change, so the neighbouring menu bar icons never shift.
    private var textSlot: (key: String, width: CGFloat)?

    init(monitor: Monitor, updater: Updater, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.updater = updater
        self.openSettings = openSettings
        super.init()

        popover.behavior = .transient
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Fivebars")
            button.imagePosition = .imageOnly
        }
        MainMenu.install(
            target: self,
            settings: #selector(settingsSelected),
            about: #selector(aboutSelected),
            updates: #selector(checkForUpdatesSelected)
        )
        render()
    }

    /// Redraws the item now and again whenever anything it reads changes.
    private func render() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }

    private func update() {
        guard let button = item.button else { return }
        let display = monitor.prefs.display

        let icon: NSImage? = if display.showsIcon {
            monitor.status == .down ? MenuBarIcon.failed : MenuBarIcon.bars(monitor.bars)
        } else {
            nil
        }

        // The icon and the text are drawn into one image so the item keeps the system's own padding,
        // the same as in icon-only mode, and the gap between them is explicit.
        if display.showsText {
            let title = monitor.menuTitle
            let textWidth = MenuBarContent.textWidth(title)
            let slot = max(textWidth, reservedTextWidth(showsLoss: monitor.prefs.showPacketLossText))
            let key = "\(icon.map { ObjectIdentifier($0).hashValue } ?? 0)|\(title)|\(slot)"
            if key != appliedContentKey {
                let image = MenuBarContent.image(icon: icon, title: title, textSlot: slot)
                button.image = image
                appliedImage = image
                appliedContentKey = key
            }
        } else {
            if icon !== appliedImage {
                button.image = icon
                appliedImage = icon
                appliedContentKey = nil
            }
        }

        let toolTip = monitor.status == .down
            ? "\(monitor.downReasonText)" + (monitor.lastError.map { "\n\($0)" } ?? "")
            : monitor.tooltip
        if toolTip != appliedToolTip {
            button.toolTip = toolTip
            appliedToolTip = toolTip
        }

        let summary = monitor.accessibilitySummary
        if summary != appliedAccessibility {
            button.setAccessibilityValue(summary)
            appliedAccessibility = summary
        }
    }

    private func reservedTextWidth(showsLoss: Bool) -> CGFloat {
        let key = "\(showsLoss)"
        if let textSlot, textSlot.key == key {
            return textSlot.width
        }
        let width = MenuBarTitle.widestCandidates(showsLoss: showsLoss).map(MenuBarContent.textWidth).max() ?? 0
        textSlot = (key, width)
        return width
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(from: sender)
        }
    }

    /// The SwiftUI content only exists while the popover is open; a hidden hosting view would keep
    /// re-rendering the chart every second.
    private func showPopover(from button: NSStatusBarButton) {
        let panel = PanelView(monitor: monitor) { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettings()
        }
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover.contentViewController = nil
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: monitor.menuStatusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset Session Stats", action: #selector(resetSessionSelected), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsSelected), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About Fivebars", action: #selector(aboutSelected), keyEquivalent: "").target = self
        if Updater.isAvailable {
            let updates = menu.addItem(
                withTitle: "Check for Updates…",
                action: #selector(checkForUpdatesSelected),
                keyEquivalent: ""
            )
            updates.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Fivebars", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func resetSessionSelected() {
        monitor.resetSessionStats()
    }

    @objc func settingsSelected() {
        popover.performClose(nil)
        openSettings()
    }

    @objc func checkForUpdatesSelected() {
        popover.performClose(nil)
        updater.checkForUpdates(nil)
    }

    /// Greys out "Check for Updates…" while a check or an install is already running.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdatesSelected) {
            return updater.canCheckForUpdates
        }
        return true
    }

    @objc func aboutSelected() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Keeps an eye on your internet connection from the menu bar.\nhttps://callingcodes.com/fivebars",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            ),
        ])
    }
}

/// Draws the icon and the title side by side as one template image.
@MainActor
enum MenuBarContent {
    /// Space between the icon and the text.
    static let gap: CGFloat = 5
    /// Same height as the bars, so the image is centred in the menu bar exactly like the icon alone.
    static let height: CGFloat = 14
    /// Text baseline above the bottom of the image; puts the digits where the system title put them.
    static let baseline: CGFloat = 3

    /// Room for the wider of the bars and the warning triangle, so going down doesn't move the text.
    private static let iconSlot = ceil(max(MenuBarIcon.bars(0).size.width, MenuBarIcon.failed.size.width))

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private static func line(_ title: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: font]))
    }

    static func textWidth(_ title: String) -> CGFloat {
        ceil(CTLineGetTypographicBounds(line(title), nil, nil, nil))
    }

    /// `textSlot` is at least the title's width; the text is drawn at its leading edge and any
    /// reserved slack stays on the trailing side.
    static func image(icon: NSImage?, title: String, textSlot: CGFloat) -> NSImage {
        let textX = icon == nil ? 0 : iconSlot + gap
        let size = NSSize(width: textX + textSlot, height: height)
        let titleLine = line(title)
        let image = NSImage(size: size, flipped: false) { _ in
            if let icon {
                let iconX = ((iconSlot - icon.size.width) / 2).rounded()
                let iconY = ((height - icon.size.height) / 2).rounded()
                icon.draw(in: NSRect(x: iconX, y: iconY, width: icon.size.width, height: icon.size.height))
            }
            if let context = NSGraphicsContext.current?.cgContext {
                context.setFillColor(NSColor.black.cgColor)
                context.textPosition = CGPoint(x: textX, y: baseline)
                CTLineDraw(titleLine, context)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title
        return image
    }
}

@MainActor
enum MenuBarIcon {
    private static var cache: [Int: NSImage] = [:]

    /// Five signal bars with `active` of them filled, drawn as a template so it follows the menu bar's appearance.
    static func bars(_ active: Int, levels: Int = 5) -> NSImage {
        if let cached = cache[active] {
            return cached
        }
        let barWidth: CGFloat = 3
        let gap: CGFloat = 1
        let size = NSSize(width: CGFloat(levels) * barWidth + CGFloat(levels - 1) * gap, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            for index in 0..<levels {
                let height = 3 + CGFloat(index) * (rect.height - 3) / CGFloat(levels - 1)
                let bar = NSRect(x: CGFloat(index) * (barWidth + gap), y: 0, width: barWidth, height: height)
                NSColor.black.withAlphaComponent(index < active ? 1 : 0.3).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Connection quality \(active) of \(levels)"
        cache[active] = image
        return image
    }

    @MainActor
    static let failed: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Connection down")!
            .withSymbolConfiguration(configuration)!
        image.isTemplate = true
        return image
    }()
}
