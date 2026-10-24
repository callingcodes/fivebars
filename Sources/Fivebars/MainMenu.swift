import AppKit

/// An accessory app shows no menu bar of its own, but without a main menu AppKit has nothing to route
/// the standard key equivalents through: ⌘V would not paste into the Settings host field and ⌘W would
/// not close the window. This menu is never visible; it only carries the shortcuts.
@MainActor
enum MainMenu {
    static func install(target: AnyObject, settings: Selector, about: Selector, updates: Selector) {
        let main = NSMenu()

        let app = NSMenu(title: "Fivebars")
        app.addItem(withTitle: "About Fivebars", action: about, keyEquivalent: "").target = target
        app.addItem(withTitle: "Check for Updates…", action: updates, keyEquivalent: "").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: settings, keyEquivalent: ",").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Fivebars", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, to: main)

        NSApp.mainMenu = main
    }

    private static func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
