import AppKit

/// Main window: transparent titlebar over a split of the app list and the detail
/// pane (Map / Rules / History / Traffic / Settings pages).
@MainActor
final class MainWindowController: NSWindowController {
    static let detailPaneDidChange = Notification.Name("YAS.MainWindow.detailPaneDidChange")

    private let listController: AppListViewController
    private let paneController: DetailPaneViewController
    private let split = FlushSplitViewController()
    private let listItem: NSSplitViewItem
    private let paneItem: NSSplitViewItem
    private var refreshTimer: Timer?
    private let makePage: (DetailPageKind) -> DetailPage
    private(set) var paneState: DetailPaneState
    private lazy var detached: DetachedPageRegistry<DetachedPageWindowController> = DetachedPageRegistry { [unowned self] kind in
        DetachedPageWindowController(page: self.makeDetachedPage(kind)) { [weak self] kind in
            self?.detached.closed(kind)
        }
    }

    /// The sidebar has one fixed width; only the detail pane grows with the window.
    private static let listWidth: CGFloat = Theme.sidebarWidth
    private static let paneMinimum: CGFloat = 360
    private static let expandedMinimumWidth: CGFloat = listWidth + paneMinimum
    private static let minimumHeight: CGFloat = 520

    init(store: Store, makePage: @escaping (DetailPageKind) -> DetailPage) {
        self.makePage = makePage
        paneState = DetailPaneState.load()
        listController = AppListViewController(store: store)
        paneController = DetailPaneViewController(store: store, makePage: makePage)
        listItem = NSSplitViewItem(viewController: listController)
        paneItem = NSSplitViewItem(viewController: paneController)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "YAS")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar gives the title bar its standard taller height, so the
        // traffic lights, title and header tabs (all centered on one line) get room above them.
        window.toolbar = NSToolbar(identifier: "MainWindowToolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        // Before the frame is restored: a collapsed pane's saved (narrow) frame must not
        // be clamped up to the two-pane minimum.
        Self.applySizeLimits(to: window, collapsed: paneState.isCollapsed)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)

        split.splitView = FlushSplitView()
        split.splitView.isVertical = true
        listItem.minimumThickness = Self.listWidth
        listItem.maximumThickness = Self.listWidth
        // The pane absorbs every window resize; the list never changes width.
        listItem.holdingPriority = NSLayoutConstraint.Priority(260)
        listItem.canCollapse = false
        paneItem.minimumThickness = Self.paneMinimum
        paneItem.canCollapse = true
        split.addSplitViewItem(listItem)
        split.addSplitViewItem(paneItem)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 820))
        if !window.setFrameUsingName("MainWindow") { window.center() }
        // The old draggable divider's saved position no longer applies.
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames MainSplit")

        listController.onAppsChanged = { [weak self] apps in self?.appsChanged(apps) }
        listController.onSelectionChanged = { [weak self] app in self?.listSelectionChanged(app) }
        listController.onShowHistory = { [weak self] app in
            self?.listController.select(appID: app.id)
            self?.showPage(.history)
        }
        listController.onSelectTab = { [weak self] kind in self?.tabClicked(kind) }
        listController.onOpenInNewWindow = { [weak self] kind in self?.openInNewWindow(kind) }
        paneController.onClearAppFilter = { [weak self] in self?.listController.deselectAll() }
        paneController.onDetach = { [weak self] kind in self?.openInNewWindow(kind) }
        paneController.show(paneState.page)
        // Preferences decide, not the split view's own autosave; applied before the
        // window is shown so the pane never flashes.
        restorePaneVisibility()
        syncMap()
        listController.updateTabs(selected: paneState.page, isCollapsed: paneState.isCollapsed)

        // Active/Idle depends on the clock, not only on new flows.
        let timer = Timer(timeInterval: 5, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.listController.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var hasShownWindow = false

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Don't start with the caret in the filter field.
        if !hasShownWindow {
            hasShownWindow = true
            window?.makeFirstResponder(nil)
        }
    }

    // MARK: - Pages

    /// Menu items and ⌘1…⌘5: show the page, expanding the pane if it was collapsed.
    func showPage(_ kind: DetailPageKind) {
        showWindow(nil)
        var state = paneState
        state.select(kind)
        apply(state)
    }

    /// Sidebar tabs: clicking the page already shown collapses the pane.
    private func tabClicked(_ kind: DetailPageKind) {
        if kind == paneState.page, !paneState.isCollapsed {
            setDetailPaneHidden(true)
        } else {
            showPage(kind)
        }
    }

    /// ⇧⌘M. Not @objc on purpose: the action goes to AppDelegate.toggleDetailPane(_:),
    /// which also validates the menu title; a same-named action here would shadow it.
    func toggleDetailPane() {
        setDetailPaneHidden(!paneState.isCollapsed)
    }

    func setDetailPaneHidden(_ hidden: Bool) {
        var state = paneState
        state.isCollapsed = hidden
        apply(state)
    }

    private func apply(_ state: DetailPaneState) {
        let old = paneState
        guard state != old else { return }
        paneState = state
        state.save()
        if state.page != old.page {
            paneController.show(state.page)
            syncMap()
        }
        if state.isCollapsed != old.isCollapsed, let window {
            if state.isCollapsed { collapsePane(in: window, animated: true) } else { expandPane(in: window, animated: true) }
        }
        listController.updateTabs(selected: state.page, isCollapsed: state.isCollapsed)
        NotificationCenter.default.post(name: Self.detailPaneDidChange, object: self)
    }

    /// One detached window per page; a second request brings it forward.
    func openInNewWindow(_ kind: DetailPageKind) {
        let controller = detached.open(kind)
        controller.showWindow(nil)
        NSApp.activate()
    }

    private func makeDetachedPage(_ kind: DetailPageKind) -> DetailPage {
        let page = makePage(kind)
        if let map = page as? MapViewController {
            map.update(apps: listController.apps)
        }
        return page
    }

    /// Currently open detached pages (for tests and the menu).
    var detachedKinds: Set<DetailPageKind> { detached.openKinds }

    private func appsChanged(_ apps: [AppSummary]) {
        (paneController.loadedPage(.map) as? MapViewController)?.update(apps: apps)
        (detached.window(for: .map)?.page as? MapViewController)?.update(apps: apps)
    }

    /// A map created after launch starts with the list's current apps and selection.
    private func syncMap() {
        guard let map = paneController.loadedPage(.map) as? MapViewController else { return }
        map.update(apps: listController.apps)
        map.highlightedAppID = listController.selectedApp?.id
    }

    private func listSelectionChanged(_ app: AppSummary?) {
        (paneController.loadedPage(.map) as? MapViewController)?.highlightedAppID = app?.id
        paneController.setAppFilter(app.map(AppHistoryFilter.init(app:)))
    }

    // MARK: - Collapsing the pane

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func collapsePane(in window: NSWindow, animated: Bool) {
        let paneWidth = paneController.view.frame.width
        if paneWidth >= Self.paneMinimum { Preferences.mapPaneWidth = Double(paneWidth) }
        paneController.isPaneVisible = false

        switch MapCollapseLayout.collapse(
            windowFrame: window.frame, listWidth: Self.listWidth, isFullScreen: isFullScreen) {
        case .resizeWindow(let frame):
            // Let the pane shrink to nothing while the window narrows, then collapse it.
            paneItem.minimumThickness = 0
            window.minSize.width = Self.listWidth
            window.setFrame(frame, display: true, animate: animated)
            paneItem.isCollapsed = true
            Self.applySizeLimits(to: window, collapsed: true)
        case .paneOnly:
            // Full screen can't shrink: the list is the only view left, so it fills the screen.
            listItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
            setCollapsed(true, animated: animated)
        }
        paneItem.minimumThickness = Self.paneMinimum
    }

    private func expandPane(in window: NSWindow, animated: Bool) {
        Self.applySizeLimits(to: window, collapsed: false)
        listItem.maximumThickness = Self.listWidth
        let plan = MapCollapseLayout.expand(
            windowFrame: window.frame, mapWidth: CGFloat(Preferences.mapPaneWidth),
            visibleFrame: window.screen?.visibleFrame, isFullScreen: isFullScreen,
            minimumExpandedWidth: Self.expandedMinimumWidth)
        switch plan {
        case .resizeWindow(let frame):
            // Bring the pane back at zero width, then grow the window: the list stays put.
            // While the pane was hidden the list's fixed width was the window's only width
            // constraint; lift it for the resize, or the window can't grow past it.
            listItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
            defer { listItem.maximumThickness = Self.listWidth }
            paneItem.minimumThickness = 0
            paneItem.isCollapsed = false
            split.splitView.setPosition(split.splitView.bounds.width, ofDividerAt: 0)
            split.splitView.layoutSubtreeIfNeeded()
            window.setFrame(frame, display: true, animate: animated)
            split.splitView.setPosition(Self.listWidth, ofDividerAt: 0)
        case .paneOnly:
            setCollapsed(false, animated: animated)
        }
        paneItem.minimumThickness = Self.paneMinimum
        paneController.isPaneVisible = true
    }

    /// Collapsed: the window is exactly the sidebar's width (only its height resizes).
    /// Expanded: at least sidebar + pane minimum, no upper bound.
    private static func applySizeLimits(to window: NSWindow, collapsed: Bool) {
        let unbounded = CGFloat.greatestFiniteMagnitude
        if collapsed {
            window.minSize = NSSize(width: listWidth, height: minimumHeight)
            window.maxSize = NSSize(width: listWidth, height: unbounded)
        } else {
            window.minSize = NSSize(width: expandedMinimumWidth, height: minimumHeight)
            window.maxSize = NSSize(width: unbounded, height: unbounded)
        }
    }

    private func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard animated else {
            paneItem.isCollapsed = collapsed
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            paneItem.animator().isCollapsed = collapsed
        }
    }

    private func restorePaneVisibility() {
        guard let window else { return }
        if paneState.isCollapsed {
            paneController.isPaneVisible = false
            paneItem.isCollapsed = true
            // A frame saved while the sidebar was resizable may be wider than it is now.
            var frame = window.frame
            if frame.width != Self.listWidth {
                frame.size.width = Self.listWidth
                window.setFrame(frame, display: false)
            }
        } else if paneItem.isCollapsed || window.frame.width < Self.expandedMinimumWidth {
            // Shown per preferences but restored narrow (e.g. quit while hidden, then changed).
            paneItem.isCollapsed = true
            expandPane(in: window, animated: false)
        }
    }

    func setSourceBadge(for source: FlowSource) {
        listController.setSourceBadge(for: source)
    }

    /// ⌘F
    @objc func focusSearch(_ sender: Any?) {
        showWindow(nil)
        listController.focusSearch()
    }
}

/// Split view with no visible divider, so the pane butts flush against the sidebar.
private final class FlushSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
}

/// The sidebar has a fixed width, so the divider is not draggable (no resize cursor).
private final class FlushSplitViewController: NSSplitViewController {
    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int
    ) -> NSRect {
        .zero
    }
}
