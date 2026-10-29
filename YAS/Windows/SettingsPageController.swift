import AppKit
import YASShared
import ServiceManagement

/// Settings page: General / Filter / Privacy / About, switched with a segmented
/// control (instead of a toolbar tab window) so it fits the detail pane.
@MainActor
final class SettingsPageController: NSViewController, DetailPage {
    enum Section: Int, CaseIterable {
        case general, filter, privacy, about

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .filter: String(localized: "Filter")
            case .privacy: String(localized: "Privacy")
            case .about: String(localized: "About")
            }
        }
    }

    let pageKind = DetailPageKind.settings
    private let sections: [NSViewController]
    private let segmented = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private(set) var section: Section = .general

    init(store: Store, extensionManager: ExtensionManager) {
        sections = [
            GeneralSettingsViewController(store: store),
            FilterSettingsViewController(store: store, extensionManager: extensionManager),
            PrivacySettingsViewController(store: store),
            AboutSettingsViewController(geo: store.geo),
        ]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        segmented.segmentCount = Section.allCases.count
        for section in Section.allCases {
            segmented.setLabel(section.title, forSegment: section.rawValue)
        }
        segmented.segmentStyle = .rounded
        segmented.target = self
        segmented.action = #selector(sectionChanged(_:))
        segmented.setAccessibilityLabel(String(localized: "Settings sections"))
        segmented.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(segmented)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            segmented.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        show(.general)
    }

    @objc private func sectionChanged(_ sender: NSSegmentedControl) {
        show(Section(rawValue: sender.selectedSegment) ?? .general)
    }

    func show(_ newSection: Section) {
        section = newSection
        segmented.selectedSegment = newSection.rawValue
        let controller = sections[newSection.rawValue]
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scrollView.documentView = document
        let clip = scrollView.contentView
        let fillWidth = document.widthAnchor.constraint(equalTo: clip.widthAnchor)
        fillWidth.priority = .defaultHigh // wider than the pane only if the form needs it
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            fillWidth,
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        (controller as? SettingsPaneController)?.refreshContent()
    }
}

/// Top-left origin, so scrolled content starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Form helper: a two-column grid with trailing-aligned labels.
@MainActor
private func formGrid(_ rows: [(String, NSView)]) -> NSGridView {
    let grid = NSGridView(views: rows.map { title, view in
        [title.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: title), view]
    })
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 12
    grid.columnSpacing = 10
    return grid
}

@MainActor
private func note(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.preferredMaxLayoutWidth = 330
    return label
}

@MainActor
private func padded(_ content: NSView) -> NSView {
    let root = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
    ])
    return root
}

/// Base for Settings sections.
@MainActor
class SettingsPaneController: NSViewController {
    /// Re-reads live state (login item, extension status) when the section is shown.
    func refreshContent() {}
}

// MARK: - General

@MainActor
final class GeneralSettingsViewController: SettingsPaneController {
    private let store: Store
    private let dockCheckbox = NSButton(checkboxWithTitle: String(localized: "Show YAS in the Dock"), target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: String(localized: "Open YAS at login"), target: nil, action: nil)
    private let loginNote = note("")
    private let loginSettingsButton = NSButton(title: String(localized: "Open Login Items Settings…"), target: nil, action: nil)
    private let homePopUp = NSPopUpButton()
    private var homeCodes: [String?] = []

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "General")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        dockCheckbox.target = self
        dockCheckbox.action = #selector(toggleDock(_:))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin(_:))
        homePopUp.target = self
        homePopUp.action = #selector(homeChanged(_:))
        buildHomeMenu()

        let dockStack = NSStackView(views: [
            dockCheckbox,
            note(String(localized: "When off, YAS lives in the menu bar only.")),
        ])
        dockStack.orientation = .vertical
        dockStack.alignment = .leading
        dockStack.spacing = 4
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginItems(_:))
        loginSettingsButton.controlSize = .small
        let loginStack = NSStackView(views: [loginCheckbox, loginNote, loginSettingsButton])
        loginStack.detachesHiddenViews = true
        refreshLoginState() // before the first measurement, so hidden rows don't reserve space
        loginStack.orientation = .vertical
        loginStack.alignment = .leading
        loginStack.spacing = 4
        let homeStack = NSStackView(views: [
            homePopUp,
            note(String(localized: "Where the map arcs start. Automatic uses your Mac's time zone.")),
        ])
        homeStack.orientation = .vertical
        homeStack.alignment = .leading
        homeStack.spacing = 4

        view = padded(formGrid([
            (String(localized: "Appearance:"), dockStack),
            (String(localized: "Startup:"), loginStack),
            (String(localized: "Home location:"), homeStack),
        ]))
    }

    override func refreshContent() {
        dockCheckbox.state = Preferences.showInDock ? .on : .off
        refreshLoginState()
    }

    private func buildHomeMenu() {
        homePopUp.removeAllItems()
        homeCodes = []
        let automatic = store.geo.automaticHomeCountryCode.map { CountryCentroids.name(for: $0) } ?? "—"
        homePopUp.addItem(withTitle: String(format: String(localized: "Automatic (%@)"), automatic))
        homeCodes.append(nil)
        homePopUp.menu?.addItem(.separator())
        homeCodes.append(nil)
        let countries = CountryCentroids.all.keys
            .map { ($0, CountryCentroids.name(for: $0)) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        for (code, name) in countries {
            homePopUp.addItem(withTitle: "\(CountryCentroids.flag(for: code)) \(name)")
            homeCodes.append(code)
        }
        if let override = Preferences.homeCountryOverride, let index = homeCodes.firstIndex(of: override) {
            homePopUp.selectItem(at: index)
        } else {
            homePopUp.selectItem(at: 0)
        }
    }

    @objc private func toggleDock(_ sender: NSButton) {
        Preferences.showInDock = sender.state == .on
        AppDelegate.applyActivationPolicy(activate: true)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshLoginState()
    }

    /// Shows the real SMAppService status, not just the checkbox state.
    private func refreshLoginState() {
        let status = SMAppService.mainApp.status
        loginCheckbox.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginCheckbox.isEnabled = status != .notFound
        loginSettingsButton.isHidden = status != .requiresApproval
        switch status {
        case .enabled:
            loginNote.stringValue = String(localized: "YAS opens when you log in.")
        case .requiresApproval:
            loginNote.stringValue = String(localized: "Waiting for your approval in System Settings > General > Login Items.")
        case .notFound:
            loginNote.stringValue = String(localized: "Not available: move YAS to /Applications first.")
        case .notRegistered:
            loginNote.stringValue = String(localized: "YAS does not open at login.")
        @unknown default:
            loginNote.stringValue = ""
        }
        loginNote.isHidden = loginNote.stringValue.isEmpty
    }

    @objc private func openLoginItems(_ sender: Any?) {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func homeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        Preferences.homeCountryOverride = homeCodes.indices.contains(index) ? homeCodes[index] : nil
        NotificationCenter.default.post(name: MapViewController.homeCountryDidChange, object: nil)
    }
}

// MARK: - Filter

@MainActor
final class FilterSettingsViewController: SettingsPaneController {
    private let store: Store
    private let extensionManager: ExtensionManager
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let toggleButton = NSButton()
    private let installButton = NSButton()
    private let uninstallButton = NSButton()
    private let modePopUp = NSPopUpButton()

    init(store: Store, extensionManager: ExtensionManager) {
        self.store = store
        self.extensionManager = extensionManager
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Filter")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 320
        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        toggleButton.bezelStyle = .push
        toggleButton.target = self
        toggleButton.action = #selector(toggleFilter(_:))
        installButton.bezelStyle = .push
        installButton.title = String(localized: "Install Extension…")
        installButton.target = self
        installButton.action = #selector(install(_:))
        uninstallButton.bezelStyle = .push
        uninstallButton.title = String(localized: "Uninstall Extension")
        uninstallButton.target = self
        uninstallButton.action = #selector(uninstall(_:))
        let buttons = NSStackView(views: [toggleButton, installButton, uninstallButton])
        buttons.spacing = 8

        for mode in FilterMode.menuOrder {
            modePopUp.addItem(withTitle: mode.title)
            modePopUp.lastItem?.representedObject = mode.rawValue
            modePopUp.lastItem?.image = Theme.paletteSymbol(mode.symbolName, pointSize: 12, glyph: .white, fill: mode.tint)
        }
        modePopUp.target = self
        modePopUp.action = #selector(modeChanged(_:))

        // The extension has no XPC setter for these yet: show its defaults, read-only.
        let timeoutPopUp = NSPopUpButton()
        timeoutPopUp.addItem(withTitle: String(localized: "60 seconds"))
        timeoutPopUp.isEnabled = false
        let fallbackPopUp = NSPopUpButton()
        fallbackPopUp.addItem(withTitle: String(localized: "Block (default)"))
        fallbackPopUp.isEnabled = false
        let comingSoon = note(String(localized: "Coming soon: these use the extension's defaults and can't be changed yet."))

        view = padded(formGrid([
            (String(localized: "Status:"), statusRow),
            ("", buttons),
            ("", note(String(localized: "Disabling the filter is the kill switch: all traffic flows normally until you enable it again."))),
            (String(localized: "Mode:"), modePopUp),
            (String(localized: "Approval timeout:"), timeoutPopUp),
            (String(localized: "When YAS is closed:"), fallbackPopUp),
            ("", comingSoon),
        ]))

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: ExtensionManager.stateDidChange, object: extensionManager)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: Store.modeDidChange, object: store)
    }

    override func refreshContent() {
        refresh()
    }

    @objc private func refresh() {
        let state = extensionManager.state
        statusLabel.stringValue = state.localizedDescription
        let color: NSColor = switch state {
        case .enabled: Theme.activeGreen
        case .error: Theme.blockedRed
        case .needsUserApproval, .activating: .systemOrange
        default: Theme.idleGrey
        }
        statusDot.layer?.backgroundColor = color.cgColor
        toggleButton.title = state == .enabled ? String(localized: "Disable Filter") : String(localized: "Enable Filter")
        toggleButton.isEnabled = extensionManager.isFilterConfigured || state == .enabled || state == .disabled
        uninstallButton.isEnabled = extensionManager.isExtensionInstalled
        installButton.isEnabled = state != .activating
        if let index = modePopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == store.mode.rawValue }) {
            modePopUp.selectItem(at: index)
        }
    }

    @objc private func toggleFilter(_ sender: Any?) {
        if extensionManager.state == .enabled {
            extensionManager.disableFilter()
        } else {
            extensionManager.enableFilter()
        }
    }

    @objc private func install(_ sender: Any?) {
        extensionManager.install()
    }

    @objc private func uninstall(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Uninstall the network extension?")
        alert.informativeText = String(localized: "YAS will stop monitoring and filtering connections.")
        alert.addButton(withTitle: String(localized: "Uninstall"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            extensionManager.uninstall()
        }
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let mode = FilterMode(rawValue: raw) else { return }
        store.setMode(mode)
    }
}

// MARK: - Privacy

@MainActor
final class PrivacySettingsViewController: SettingsPaneController {
    private let store: Store
    private let retentionPopUp = NSPopUpButton()

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Privacy")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        for retention in HistoryRetention.allCases {
            retentionPopUp.addItem(withTitle: retention.title)
            retentionPopUp.lastItem?.tag = retention.rawValue
        }
        retentionPopUp.selectItem(withTag: Preferences.historyRetention.rawValue)
        retentionPopUp.target = self
        retentionPopUp.action = #selector(retentionChanged(_:))
        let retentionStack = NSStackView(views: [
            retentionPopUp,
            note(String(localized: "Older connections are deleted automatically. Rules are never deleted.")),
        ])
        retentionStack.orientation = .vertical
        retentionStack.alignment = .leading
        retentionStack.spacing = 4

        let clear = NSButton(title: String(localized: "Clear History…"), target: self, action: #selector(clearHistory(_:)))
        let clearStack = NSStackView(views: [
            clear,
            note(String(localized: "History is stored only on this Mac, in ~/Library/Application Support/YAS.")),
        ])
        clearStack.orientation = .vertical
        clearStack.alignment = .leading
        clearStack.spacing = 4

        view = padded(formGrid([
            (String(localized: "Keep history for:"), retentionStack),
            (String(localized: "History:"), clearStack),
        ]))
    }

    @objc private func retentionChanged(_ sender: NSPopUpButton) {
        guard let retention = HistoryRetention(rawValue: sender.selectedTag()) else { return }
        Preferences.historyRetention = retention
        store.pruneHistory()
    }

    @objc private func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear all connection history?")
        alert.informativeText = String(localized: "This deletes every recorded connection and traffic total. Rules are kept. This can't be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.clearHistory()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - About

@MainActor
final class AboutSettingsViewController: SettingsPaneController {
    private let geo: GeoIPService

    init(geo: GeoIPService) {
        self.geo = geo
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "About")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let info = Bundle.main.infoDictionary ?? [:]
        let version = String(
            format: String(localized: "Version %@ (%@)"),
            info["CFBundleShortVersionString"] as? String ?? "?",
            info["CFBundleVersion"] as? String ?? "?")
        let name = NSTextField(labelWithString: String(localized: "YAS"))
        name.font = .systemFont(ofSize: 18, weight: .bold)

        let attribution = NSTextField(labelWithAttributedString: {
            let text = NSMutableAttributedString(
                string: String(localized: "IP geolocation by DB-IP, licensed under CC BY 4.0."),
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(string: "\n"))
            text.append(NSAttributedString(
                string: "https://db-ip.com",
                attributes: [.link: URL(string: "https://db-ip.com")!, .font: NSFont.systemFont(ofSize: 12)]))
            return text
        }())
        attribution.isSelectable = true
        attribution.allowsEditingTextAttributes = true

        let database: String
        if geo.isDatabaseLoaded {
            if let date = geo.databaseBuildDate {
                database = String(format: String(localized: "GeoIP database built %@."), date.formatted(date: .abbreviated, time: .omitted))
            } else {
                database = String(localized: "GeoIP database loaded.")
            }
        } else {
            database = String(localized: "No GeoIP database installed: countries show as unknown. Run scripts/fetch-geoip.sh and rebuild.")
        }

        let fullName = NSTextField(labelWithString: String(localized: "Yet Another Shield"))
        fullName.font = .systemFont(ofSize: 12, weight: .medium)
        fullName.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, name, fullName, note(version), attribution, note(database)])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        view = padded(stack)
    }
}
