import AppKit
import YASShared
import os
import UserNotifications

/// Require Approval prompt: a floating, non-activating panel near
/// the menu bar for the oldest pending request, with a queue indicator. Posts a
/// user notification instead when the user has dismissed the panel.
@MainActor
final class ApprovalPanelController: NSObject {
    private let store: Store
    private let xpc: XPCClient
    private let logger = Logger(subsystem: "com.gful.yas", category: "Approvals")
    private var panel: NSPanel?
    private var scopePopUp: NSPopUpButton?
    private var expiryLabel: NSTextField?
    private var shownRequest: ApprovalRequest?
    private var seenRequestIDs: Set<UUID> = []
    /// Set when the user closes the panel with requests still pending.
    private var isDismissedByUser = false
    private var expiryTimer: Timer?
    private var didRequestNotificationAuthorization = false

    private static let panelWidth: CGFloat = 400
    private static let maxListedDestinations = 5
    /// Extension default; there is no XPC setter for it yet.
    private static let extensionTimeout: TimeInterval = 60

    init(store: Store, xpc: XPCClient) {
        self.store = store
        self.xpc = xpc
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(approvalsChanged), name: Store.approvalsDidChange, object: store)
        UNUserNotificationCenter.current().delegate = self

        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tickExpiry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Shows the panel if anything is pending (menu bar item, notification click).
    func showPanel() {
        isDismissedByUser = false
        render()
    }

    // MARK: - Store changes

    @objc private func approvalsChanged() {
        let pending = store.pendingApprovals
        let newRequests = pending.filter { !seenRequestIDs.contains($0.requestID) }
        seenRequestIDs.formIntersection(pending.map(\.requestID))
        seenRequestIDs.formUnion(newRequests.map(\.requestID))

        if pending.isEmpty {
            isDismissedByUser = false
            panel?.orderOut(nil)
            shownRequest = nil
            return
        }
        if isDismissedByUser {
            for request in newRequests { postNotification(for: request) }
            return
        }
        render()
    }

    private func tickExpiry() {
        store.expireApprovals(olderThan: Date().addingTimeInterval(-Self.extensionTimeout - 2))
        guard let request = shownRequest, let expiryLabel else { return }
        let remaining = max(0, Int(Self.extensionTimeout - Date().timeIntervalSince(request.firstSeen)))
        expiryLabel.stringValue = String(format: String(localized: "Decide within %lld s"), remaining)
    }

    // MARK: - Decisions

    private func resolve(_ request: ApprovalRequest, action: RuleAction, scope: ApprovalDecision.Scope) {
        let decision = ApprovalDecision(action: action, scope: scope)
        xpc.resolveApproval(request, decision: decision)
        store.removeApproval(request.requestID)
        // Same ID as the rule the extension persists, so the push does not duplicate it.
        if let rule = decision.makeRule(for: request.app, id: request.requestID) {
            store.upsertRule(rule)
        }
    }

    private var selectedScope: ApprovalDecision.Scope {
        scopePopUp?.indexOfSelectedItem == 0 ? .once : .always
    }

    @objc private func allow(_ sender: Any?) {
        guard let request = shownRequest else { return }
        resolve(request, action: .allow, scope: selectedScope)
    }

    @objc private func block(_ sender: Any?) {
        guard let request = shownRequest else { return }
        resolve(request, action: .block, scope: selectedScope)
    }

    @objc private func allowAll(_ sender: Any?) {
        let scope = selectedScope
        for request in store.pendingApprovals { resolve(request, action: .allow, scope: scope) }
    }

    @objc private func blockAll(_ sender: Any?) {
        let scope = selectedScope
        for request in store.pendingApprovals { resolve(request, action: .block, scope: scope) }
    }

    // MARK: - Panel

    private func render() {
        guard let request = store.pendingApprovals.first else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let previousScope = scopePopUp?.indexOfSelectedItem ?? 1
        shownRequest = request

        let content = makeContent(for: request, waiting: store.pendingApprovals.count - 1)
        scopePopUp?.selectItem(at: previousScope)
        guard let effect = panel.contentView else { return }
        effect.subviews.forEach { $0.removeFromSuperview() }
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: 30),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),
        ])
        effect.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height + 46
        var frame = panel.frame
        frame.size = NSSize(width: Self.panelWidth, height: height)
        if let screen = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: screen.maxX - frame.width - 12, y: screen.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: true)
        tickExpiry()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = String(localized: "Connection Request")
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        // Only the close button: the panel can't be minimized or zoomed.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Solid dark background: vibrancy turned mid-grey over light desktops.
        panel.backgroundColor = Theme.panelBackground
        panel.contentView = NSView()
        return panel
    }

    private func makeContent(for request: ApprovalRequest, waiting: Int) -> NSView {
        let icons = AppIconService.shared
        let iconView = NSImageView(image: icons.icon(forExecutablePath: request.app.executablePath))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
        ])

        let name = NSTextField.label(icons.displayName(forExecutablePath: request.app.executablePath), size: 15, weight: .bold)
        let signature = NSTextField.label(
            request.app.signatureDescription, size: 11,
            color: request.app.hasWarningSignature ? .systemOrange : .secondaryLabelColor)
        if request.app.hasWarningSignature {
            signature.stringValue = "⚠︎ " + signature.stringValue
        }
        let wants = NSTextField.label(String(localized: "wants to connect to:"), size: 12, color: .secondaryLabelColor)
        let titleStack = NSStackView(views: [name, signature, wants])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        let header = NSStackView(views: [iconView, titleStack])
        header.alignment = .centerY
        header.spacing = 12

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        for destination in request.destinations.prefix(Self.maxListedDestinations) {
            list.addArrangedSubview(destinationRow(destination))
        }
        if request.destinations.count > Self.maxListedDestinations {
            let more = request.destinations.count - Self.maxListedDestinations
            list.addArrangedSubview(NSTextField.label(
                String(localized: "and \(more) more destinations"),
                size: 11, color: .tertiaryLabelColor))
        }
        let listBox = NSView()
        listBox.wantsLayer = true
        listBox.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        listBox.layer?.cornerRadius = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        listBox.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: listBox.leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: listBox.trailingAnchor, constant: -10),
            list.topAnchor.constraint(equalTo: listBox.topAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: listBox.bottomAnchor, constant: -8),
        ])

        let expiry = NSTextField.label(size: 11, color: .tertiaryLabelColor)
        expiryLabel = expiry

        let scope = NSPopUpButton(frame: .zero, pullsDown: false)
        scope.addItems(withTitles: [String(localized: "Once"), String(localized: "Always")])
        scope.selectItem(at: 1)
        scope.controlSize = .regular
        scope.setAccessibilityLabel(String(localized: "Remember this decision"))
        scopePopUp = scope
        let blockButton = NSButton(title: String(localized: "Block"), target: self, action: #selector(block(_:)))
        blockButton.contentTintColor = Theme.blockedRed
        let allowButton = NSButton(title: String(localized: "Allow"), target: self, action: #selector(allow(_:)))
        allowButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [scope, spacer, blockButton, allowButton])
        buttons.spacing = 8

        var rows: [NSView] = [header, listBox, expiry, buttons]
        if waiting > 0 {
            let divider = NSBox()
            divider.boxType = .separator
            let queue = NSTextField.label(
                String(localized: "\(waiting) more apps waiting"),
                size: 12, weight: .medium, color: .secondaryLabelColor)
            let queueSpacer = NSView()
            queueSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let blockAll = NSButton(title: String(localized: "Block All"), target: self, action: #selector(blockAll(_:)))
            let allowAll = NSButton(title: String(localized: "Allow All"), target: self, action: #selector(allowAll(_:)))
            for button in [blockAll, allowAll] { button.controlSize = .small }
            let queueRow = NSStackView(views: [queue, queueSpacer, blockAll, allowAll])
            queueRow.spacing = 6
            rows += [divider, queueRow]
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows where row !== expiry {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func destinationRow(_ destination: ApprovalDestination) -> NSView {
        let code = store.geo.countryCode(forIP: destination.ip)
        let country = code.map { "\(CountryCentroids.flag(for: $0)) \($0)" } ?? "🌐"
        let host = NSTextField.label(destination.host ?? destination.ip, size: 12, weight: .medium)
        host.lineBreakMode = .byTruncatingMiddle
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField.label(
            "\(country)  \(destination.ip):\(destination.port)  ×\(destination.count)",
            size: 11, color: .secondaryLabelColor)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [host, detail])
        row.distribution = .fill
        row.spacing = 8
        return row
    }

    // MARK: - Notifications

    private func postNotification(for request: ApprovalRequest) {
        let name = AppIconService.shared.displayName(forExecutablePath: request.app.executablePath)
        let title = String(format: String(localized: "%@ wants to connect"), name)
        let body = request.destinations.prefix(3).map { $0.host ?? $0.ip }.joined(separator: ", ")
        let identifier = request.requestID.uuidString
        let logger = logger

        if didRequestNotificationAuthorization {
            Self.deliver(identifier: identifier, title: title, body: body, logger: logger)
            return
        }
        didRequestNotificationAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error { logger.error("Notification authorization failed: \(String(describing: error), privacy: .public)") }
            if granted { Self.deliver(identifier: identifier, title: title, body: body, logger: logger) }
        }
    }

    private nonisolated static func deliver(identifier: String, title: String, body: String, logger: Logger) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            if let error { logger.error("Notification failed: \(String(describing: error), privacy: .public)") }
        }
    }
}

extension ApprovalPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if !store.pendingApprovals.isEmpty { isDismissedByUser = true }
    }
}

extension ApprovalPanelController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { self.showPanel() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
