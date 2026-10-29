import AppKit

/// The app's menu bar, built in code (no MainMenu.xib).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = submenu(in: mainMenu, title: String(localized: "YAS"))
        appMenu.addItem(withTitle: String(localized: "About YAS"),
                        action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide YAS"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit YAS"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = submenu(in: mainMenu, title: String(localized: "File"))
        fileMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = submenu(in: mainMenu, title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Find…"), action: #selector(AppDelegate.focusSearch(_:)), keyEquivalent: "f")

        let viewMenu = submenu(in: mainMenu, title: String(localized: "View"))
        let pageActions: [DetailPageKind: Selector] = [
            .map: #selector(AppDelegate.showMap(_:)), .rules: #selector(AppDelegate.showRules(_:)),
            .history: #selector(AppDelegate.showHistory(_:)), .traffic: #selector(AppDelegate.showTraffic(_:)),
            .settings: #selector(AppDelegate.showSettings(_:)),
        ]
        for (index, kind) in DetailPageKind.allCases.enumerated() {
            guard let action = pageActions[kind] else { continue }
            viewMenu.addItem(withTitle: kind.title, action: action, keyEquivalent: kind.keyEquivalent)
            // Hold ⌥: the same shortcut with ⌥ opens the page in its own window.
            let detach = viewMenu.addItem(
                withTitle: String(localized: "Open \(kind.title) in New Window"),
                action: #selector(AppDelegate.openPageInNewWindow(_:)), keyEquivalent: kind.keyEquivalent)
            detach.keyEquivalentModifierMask = [.command, .option]
            detach.isAlternate = true
            detach.tag = index
        }
        viewMenu.addItem(.separator())
        let togglePane = viewMenu.addItem(
            withTitle: String(localized: "Hide Detail Pane"), action: #selector(AppDelegate.toggleDetailPane(_:)),
            keyEquivalent: "m")
        togglePane.keyEquivalentModifierMask = [.command, .shift]

        let windowMenu = submenu(in: mainMenu, title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: String(localized: "YAS"), action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "0")
        windowMenu.addItem(withTitle: String(localized: "Setup Assistant"), action: #selector(AppDelegate.showOnboarding(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private static func submenu(in mainMenu: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        mainMenu.addItem(item)
        return menu
    }
}
