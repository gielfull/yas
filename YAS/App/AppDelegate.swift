import AppKit
import YASShared
import os

/// Owns the services and windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.gful.yas", category: "App")
    private var store: Store?
    private var extensionManager: ExtensionManager?
    private var xpc: XPCClient?
    private var approvals: ApprovalPanelController?
    private var statusItem: StatusItemController?
    private var mainWindowController: MainWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    /// Real history + rules. Demo mode records into `demoDatabase` instead.
    private var mainDatabase: HistoryDatabase?
    private var pruneTimer: Timer?
    private var hasResolvedInitialState = false
    /// Monitor-only fallback (libproc) while the filter isn't running.
    private var monitor: ConnectionMonitor?
    #if DEBUG
    private var demo: DemoDataSource?
    private var demoRequested: Bool { DemoDataSource.isRequestedByLaunchArgument }
    #else
    private var demoRequested: Bool { false }
    #endif

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted by the app; don't start services, migrate, or open windows.
        guard !Self.isRunningUnitTests else {
            Preferences.registerDefaults()
            return
        }
        // Before registering defaults, so registered values don't look like existing settings.
        LegacyMigration.runAtLaunch()
        Preferences.registerDefaults()

        Self.applyActivationPolicy()
        // One dark look for every window, sheet, alert and menu (matches the main window).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.make()

        mainDatabase = Self.openDatabase(fileName: "yas.sqlite", importLegacyRules: true)
        #if DEBUG
        let history = DemoDataSource.isRequestedByLaunchArgument ? demoDatabase : mainDatabase
        #else
        let history = mainDatabase
        #endif
        let store = Store(geo: GeoIPService(), rulesDatabase: mainDatabase, history: history)
        let extensionManager = ExtensionManager()
        let xpc = XPCClient(store: store)
        let approvals = ApprovalPanelController(store: store, xpc: xpc)
        self.store = store
        self.extensionManager = extensionManager
        self.xpc = xpc
        self.approvals = approvals
        statusItem = StatusItemController(store: store, approvals: approvals)

        let main = MainWindowController(store: store) { kind in
            Self.makePage(kind, store: store, extensionManager: extensionManager)
        }
        mainWindowController = main
        main.showWindow(nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(extensionStateChanged), name: ExtensionManager.stateDidChange, object: extensionManager)
        // Show real connections right away; switch to the filter once it reports enabled.
        applySource(DataSourceSelection.select(demoRequested: demoRequested, filterEnabled: false))
        extensionManager.refresh()
        NSApp.activate()

        // Retention: on launch, then every 6 hours (cheap when nothing is old).
        store.pruneHistory()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.store?.pruneHistory() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    /// A fresh page for the detail pane or a detached window.
    private static func makePage(_ kind: DetailPageKind, store: Store, extensionManager: ExtensionManager) -> DetailPage {
        switch kind {
        case .map:
            let map = MapViewController(store: store)
            map.onCountrySelected = { name in store.filterText = name }
            return map
        case .rules: return RulesPageController(store: store)
        case .history: return HistoryPageController(store: store)
        case .traffic: return TrafficPageController(store: store)
        case .settings: return SettingsPageController(store: store, extensionManager: extensionManager)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flushHistory()
    }

    private static func openDatabase(fileName: String, importLegacyRules: Bool) -> HistoryDatabase? {
        let logger = Logger(subsystem: "com.gful.yas", category: "App")
        guard let url = HistoryDatabase.defaultURL(fileName: fileName) else { return nil }
        do {
            let database = try HistoryDatabase(url: url)
            if importLegacyRules, let legacy = Store.legacyRulesURL() {
                let imported = try database.importLegacyRules(from: legacy)
                if imported > 0 { logger.notice("Imported \(imported) rules from rules.json") }
            }
            return database
        } catch {
            logger.error("Could not open \(fileName, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    #if DEBUG
    /// Separate file so demo traffic never mixes with real history.
    private lazy var demoDatabase: HistoryDatabase? = Self.openDatabase(fileName: "yas-demo.sqlite", importLegacyRules: false)
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    /// Dock icon or menu bar only.
    nonisolated static func activationPolicy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    /// Applied at launch before any window shows, and when the setting changes.
    /// Switching at runtime re-activates so open windows stay in front.
    static func applyActivationPolicy(activate: Bool = false) {
        NSApp.setActivationPolicy(activationPolicy(showInDock: Preferences.showInDock))
        if activate { NSApp.activate() }
    }

    // MARK: - Extension state

    @objc private func extensionStateChanged() {
        guard let extensionManager else { return }
        let state = extensionManager.state
        if state == .unknown || state == .activating { return }
        applySource(DataSourceSelection.select(demoRequested: demoRequested, filterEnabled: state == .enabled))

        guard !hasResolvedInitialState else { return }
        hasResolvedInitialState = true
        // First run only: afterwards the MONITOR ONLY tag and the Window menu reopen it.
        if state != .enabled, !demoRequested, !Preferences.hasShownOnboarding {
            Preferences.hasShownOnboarding = true
            showOnboarding(nil)
        }
    }

    /// Switches what feeds the Store: the filter (XPC), the libproc monitor, or the demo.
    private func applySource(_ source: FlowSource) {
        guard let store, let xpc else { return }
        if source != .monitor { monitor?.stop() }
        if source != .filter { xpc.stop() }
        #if DEBUG
        if source != .demo { stopDemo() }
        #endif

        switch source {
        case .filter:
            if store.history !== mainDatabase { store.attachHistory(mainDatabase) }
            xpc.start()
        case .monitor:
            if store.history !== mainDatabase { store.attachHistory(mainDatabase) }
            let monitor = self.monitor ?? ConnectionMonitor(store: store)
            self.monitor = monitor
            monitor.start()
        case .demo:
            #if DEBUG
            startDemo()
            #endif
        }
        store.setSource(source)
        mainWindowController?.setSourceBadge(for: source)
    }

    #if DEBUG
    private func startDemo() {
        guard let store, demo == nil else { return }
        logger.notice("Starting demo data source")
        if store.history !== demoDatabase { store.attachHistory(demoDatabase) }
        let demo = DemoDataSource(store: store)
        demo.start()
        self.demo = demo
    }

    private func stopDemo() {
        guard let demo else { return }
        demo.stop()
        self.demo = nil
    }
    #endif

    // MARK: - Windows (also reached through the responder chain)

    @objc func showMainWindow(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        NSApp.activate()
    }

    /// Standard About panel with the full name as its subtitle.
    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: String(localized: "Yet Another Shield"),
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    /// ⇧⌘M: collapse or expand the detail pane (whatever page it shows).
    @objc func toggleDetailPane(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        mainWindowController?.toggleDetailPane()
    }

    @objc func focusSearch(_ sender: Any?) {
        NSApp.activate()
        mainWindowController?.focusSearch(sender)
    }

    // Pages: View menu ⌘1…⌘5, ⌘, and the menu bar item. Each shows the page in the
    // main window's detail pane (expanding it if collapsed).
    @objc func showMap(_ sender: Any?) { showPage(.map) }
    @objc func showRules(_ sender: Any?) { showPage(.rules) }
    @objc func showHistory(_ sender: Any?) { showPage(.history) }
    @objc func showTraffic(_ sender: Any?) { showPage(.traffic) }
    @objc func showSettings(_ sender: Any?) { showPage(.settings) }

    private func showPage(_ kind: DetailPageKind) {
        mainWindowController?.showPage(kind)
        NSApp.activate()
    }

    /// ⌥ alternates in the View menu; the menu item's tag is the page's index.
    @objc func openPageInNewWindow(_ sender: NSMenuItem) {
        guard DetailPageKind.allCases.indices.contains(sender.tag) else { return }
        mainWindowController?.openInNewWindow(DetailPageKind.allCases[sender.tag])
    }

    @objc func showOnboarding(_ sender: Any?) {
        guard let store, let extensionManager else { return }
        let controller = onboardingWindowController ?? OnboardingWindowController(store: store, extensionManager: extensionManager)
        onboardingWindowController = controller
        controller.showWindow(nil)
        NSApp.activate()
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Keeps "Hide Detail Pane" / "Show Detail Pane" in step with the pane.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDetailPane(_:)) {
            menuItem.title = Preferences.isDetailPaneHidden
                ? String(localized: "Show Detail Pane") : String(localized: "Hide Detail Pane")
        }
        return true
    }
}
