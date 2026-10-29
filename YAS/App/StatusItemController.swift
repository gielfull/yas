import AppKit
import YASShared

/// Menu bar item: glyph per mode with a pending-approvals badge,
/// mode radio items, counters (read when the menu opens), approvals, pause, open, quit.
@MainActor
final class StatusItemController: NSObject {
    private let store: Store
    private let approvals: ApprovalPanelController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    static let pauseDuration: TimeInterval = 15 * 60

    init(store: Store, approvals: ApprovalPanelController) {
        self.store = store
        self.approvals = approvals
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateIcon), name: Store.modeDidChange, object: store)
        center.addObserver(self, selector: #selector(updateIcon), name: Store.approvalsDidChange, object: store)
        updateIcon()
    }

    @objc private func updateIcon() {
        let pending = store.pendingApprovals.count
        statusItem.button?.image = StatusIcon.image(for: store.mode, pendingApprovals: pending)
        let description = StatusIcon.accessibilityDescription(mode: store.mode, pendingApprovals: pending)
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }

    /// Counters from the database (all recorded history), falling back to in-memory flows.
    private func counters(now: Date) -> (connections: Int, blocked: Int) {
        let hourAgo = now.addingTimeInterval(-3600)
        let startOfDay = Calendar.current.startOfDay(for: now)
        if let history = store.history, let counts = try? history.counters(connectionsSince: hourAgo, blockedSince: startOfDay) {
            return counts
        }
        return (store.connectionCount(since: hourAgo), store.blockedCount(since: startOfDay))
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FilterMode(rawValue: raw) else { return }
        store.setMode(mode)
    }

    @objc private func showApprovals(_ sender: Any?) {
        approvals.showPanel()
    }

    @objc private func pause(_ sender: Any?) {
        store.pauseFiltering(for: Self.pauseDuration)
    }

    @objc private func resume(_ sender: Any?) {
        store.resumeFiltering()
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        if let until = store.pausedUntil {
            let minutes = PauseSchedule.minutesRemaining(until: until, now: now)
            let paused = NSMenuItem(title: String(localized: "Filtering paused — resumes in \(minutes) min"), action: nil, keyEquivalent: "")
            paused.isEnabled = false
            menu.addItem(paused)
            let resume = NSMenuItem(title: String(localized: "Resume Now"), action: #selector(resume(_:)), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: String(localized: "Filter Mode"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for mode in FilterMode.menuOrder {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = store.mode == mode ? .on : .off
            item.toolTip = mode.summary
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let counts = counters(now: now)
        for text in [
            String(format: String(localized: "Connections in the last hour: %lld"), counts.connections),
            String(format: String(localized: "Blocked today: %lld"), counts.blocked),
        ] {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let pending = store.pendingApprovals.count
        if pending > 0 {
            let item = NSMenuItem(
                title: String(localized: "Review \(pending) Pending Approvals…"),
                action: #selector(showApprovals(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let open = NSMenuItem(title: String(localized: "Open YAS"), action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "")
        open.target = NSApp.delegate
        menu.addItem(open)

        if store.pausedUntil == nil {
            let pause = NSMenuItem(title: String(localized: "Pause Filtering for 15 Minutes"), action: #selector(pause(_:)), keyEquivalent: "")
            pause.target = self
            pause.toolTip = String(localized: "Switches to Allow All, then restores the current mode.")
            menu.addItem(pause)
        }

        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = NSApp.delegate
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit YAS"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
