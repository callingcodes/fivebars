import AppKit
import FivebarsCore
import Observation
import SwiftUI

/// The menu bar item. Left and right click open the same native menu: a live SwiftUI header
/// (quality, latency chart, stats) above standard rows. AppKit owns opening, closing (outside clicks,
/// other menu bar items, Esc) and the system menu material.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let monitor: Monitor
    private let updater: Updater
    private let openSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let changeHostItem = NSMenuItem()
    private var isMenuOpen = false
    /// Loss digits the title last made room for. While the menu is open the title keeps this
    /// width: resizing a status item closes its open menu, which happened in "When There's Loss"
    /// mode when the suffix came or went.
    private var appliedLossDigits: Int?

    /// Last values written to the button, so an unchanged second costs no redraw.
    private var appliedImage: NSImage?
    private var appliedContentKey: String?
    private var appliedToolTip: String?
    private var appliedAccessibility: String?
    /// Width reserved for the text: the widest title the current display settings can produce,
    /// measured once per settings change, so the neighbouring menu bar icons never shift.
    private var textSlot: (key: String, width: CGFloat)?
    /// "When There's Loss" mode: shows the loss suffix while packets are lost, plus a hold.
    private var lossGate = MenuBarTitle.HoldGate.lossSuffix()
    /// Whether the reserved width has room for a two-digit loss.
    private var twoDigitGate = MenuBarTitle.HoldGate.twoDigitLoss()
    /// Redraws while a gate is holding, in case no ping lands in between (slow intervals).
    private var lossGateRecheck: DispatchWorkItem?

    init(monitor: Monitor, updater: Updater, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.updater = updater
        self.openSettings = openSettings
        super.init()

        if let button = item.button {
            button.setAccessibilityLabel("Fivebars")
            button.imagePosition = .imageOnly
        }
        buildMenu()
        // A status item with a menu opens it on left click, right click and Control-click alike.
        item.menu = menu
        MainMenu.install(
            target: self,
            settings: #selector(settingsSelected),
            about: #selector(aboutSelected),
            updates: #selector(checkForUpdatesSelected)
        )
        render()
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = true
        menu.addItem(headerItem)

        changeHostItem.title = "Change Host…"
        changeHostItem.action = #selector(settingsSelected)
        changeHostItem.target = self
        changeHostItem.image = symbol("network")
        changeHostItem.isHidden = true
        menu.addItem(changeHostItem)

        menu.addItem(.separator())
        addRow("Reset Session Stats", symbol: "arrow.counterclockwise", action: #selector(resetSessionSelected))
        // Holding Option swaps in the all-time reset, as in the old panel's Reset menu.
        let resetAll = addRow(
            "Reset All Time Stats…",
            symbol: "arrow.counterclockwise",
            action: #selector(resetAllTimeSelected)
        )
        resetAll.isAlternate = true
        resetAll.keyEquivalentModifierMask = .option
        menu.addItem(.separator())
        if Updater.isAvailable {
            addRow("Check for Updates…", symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdatesSelected))
        }
        addRow("Settings…", symbol: "gearshape", action: #selector(settingsSelected), key: ",")
        addRow("About Fivebars", symbol: "info.circle", action: #selector(aboutSelected))
        menu.addItem(.separator())
        let quit = addRow("Quit Fivebars", symbol: "power", action: #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
    }

    @discardableResult
    private func addRow(_ title: String, symbol name: String, action: Selector, key: String = "") -> NSMenuItem {
        let row = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        row.target = self
        row.image = symbol(name)
        return row
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: Menu lifecycle

    /// The SwiftUI header only exists while the menu is open; a hidden hosting view would keep
    /// re-rendering the chart every second. While open, the menu tracks events in
    /// `.eventTracking` mode: the monitor's timers run in `.common` modes and the ICMP socket
    /// source is on the main queue, so pings land and the header redraws live.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            isMenuOpen = true
            let hosting = NSHostingView(rootView: StatusMenuView(monitor: monitor))
            hosting.frame.size = hosting.fittingSize
            headerItem.view = hosting
            trackMenuState()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            isMenuOpen = false
            headerItem.view = nil
            // Catch up on a loss suffix that came or went while the width was held.
            update()
        }
    }

    /// Shows "Change Host…" while the connection is down, for as long as the menu stays open.
    /// The header reserves two lines for the down reason, so it keeps one height in both states
    /// and the open menu never has to relayout its custom view.
    private func trackMenuState() {
        guard isMenuOpen else { return }
        let hidden = withObservationTracking {
            monitor.status != .down
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackMenuState() }
        }
        if changeHostItem.isHidden != hidden {
            changeHostItem.isHidden = hidden
        }
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
            let gatedDigits = updateLossGates()
            let lossDigits = isMenuOpen ? appliedLossDigits : gatedDigits
            appliedLossDigits = lossDigits
            let title = monitor.menuTitle(showsLoss: lossDigits != nil)
            let textWidth = MenuBarContent.textWidth(title)
            // The slot widens only while the suffix is shown, so in "When There's Loss" mode the
            // neighbouring icons move when it appears and when it goes, never on each ping.
            let slot = max(textWidth, reservedTextWidth(lossDigits: lossDigits))
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

    /// nil when the title has no loss suffix, else how many loss digits to make room for: one
    /// normally, two only during heavy loss, so the slack is at most one digit wide.
    private func updateLossGates() -> Int? {
        let loss = monitor.lossIsKnown ? monitor.lossPercent : 0
        let shown = MenuBarTitle.displayedLoss(loss)
        let now = ProcessInfo.processInfo.systemUptime
        let suffixOpen = lossGate.update(active: loss > 0, now: now)
        let twoDigits = twoDigitGate.update(active: shown >= 10, now: now)

        // A gate holding open closes on a later redraw; pings usually bring one, slow intervals may not.
        lossGateRecheck?.cancel()
        lossGateRecheck = nil
        if (suffixOpen && loss <= 0) || (twoDigits && shown < 10) {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.update() }
            }
            lossGateRecheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }

        guard MenuBarTitle.showsLoss(mode: monitor.prefs.lossTextMode, gateOpen: suffixOpen) else { return nil }
        return twoDigits ? 2 : 1
    }

    private func reservedTextWidth(lossDigits: Int?) -> CGFloat {
        let key = "\(lossDigits ?? 0)"
        if let textSlot, textSlot.key == key {
            return textSlot.width
        }
        let width = MenuBarTitle.widestCandidates(lossDigits: lossDigits).map(MenuBarContent.textWidth).max() ?? 0
        textSlot = (key, width)
        return width
    }

    @objc private func resetSessionSelected() {
        monitor.resetSessionStats()
    }

    @objc private func resetAllTimeSelected() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to reset the all time stats for \(monitor.prefs.hostname)?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.resetAllTimeStats()
        }
    }

    @objc func settingsSelected() {
        openSettings()
    }

    @objc func checkForUpdatesSelected() {
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
