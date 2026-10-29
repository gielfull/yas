import AppKit
import YASShared

/// Left pane: title row, filter bar, and the outline of apps -> destinations.
@MainActor
final class AppListViewController: NSViewController {
    // Outline: App -> Process -> Destination, or App -> Destination when the app
    // has a single process. Nodes are cached by key so refreshes keep expansion.
    private final class AppNode: NSObject {
        let key: String
        var app: AppSummary
        /// `ProcessNode`s, or `DestinationNode`s for single-process apps.
        var children: [NSObject] = []

        init(app: AppSummary) {
            key = app.id
            self.app = app
        }
    }

    private final class ProcessNode: NSObject {
        let key: String
        var process: ProcessSummary
        var children: [DestinationNode] = []
        weak var parent: AppNode?

        init(key: String, process: ProcessSummary, parent: AppNode) {
            self.key = key
            self.process = process
            self.parent = parent
        }
    }

    private final class DestinationNode: NSObject {
        let key: String
        var destination: DestinationSummary
        weak var parent: AppNode?
        weak var process: ProcessNode?

        init(key: String, destination: DestinationSummary, parent: AppNode, process: ProcessNode?) {
            self.key = key
            self.destination = destination
            self.parent = parent
            self.process = process
        }
    }

    /// What a Disconnect menu item acts on.
    private final class DisconnectTarget: NSObject {
        let identities: [AppIdentity]
        let name: String
        let duration: DisconnectDuration?

        init(identities: [AppIdentity], name: String, duration: DisconnectDuration?) {
            self.identities = identities
            self.name = name
            self.duration = duration
        }
    }

    private let store: Store
    private let titleLabel = NSTextField.label(String(localized: "YAS"), size: 16, weight: .bold, color: .white)
    /// "MONITOR ONLY" / "DEMO" tag next to the title; clicking opens the setup assistant.
    private let badgeButton = NSButton()
    /// Detail pane tabs (Map, Rules, History, Traffic, Settings), in ⌘1…⌘5 order.
    private var tabButtons: [DetailPageKind: PaneTabButton] = [:]
    private let hiddenProcessesLabel = NSTextField.label(size: 11, color: NSColor(white: 1, alpha: 0.4))
    private let searchBar = SearchBarView()
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField.label(size: 13, color: NSColor(white: 1, alpha: 0.45))
    /// Under the empty-state text when the time window hides everything.
    private let showAllButton = NSButton(title: String(localized: "Show All"), target: nil, action: nil)
    private let throughputLabel = NSTextField.label(size: 11, color: NSColor(white: 1, alpha: 0.5))
    private var throughputTimer: Timer?
    private var titleLeading: NSLayoutConstraint?
    private var titleCenterY: NSLayoutConstraint?

    private var nodes: [AppNode] = []
    private var nodeCache: [String: AppNode] = [:]
    private var processCache: [String: ProcessNode] = [:]
    private var destinationCache: [String: DestinationNode] = [:]

    /// Latest apps shown in the list (after filtering), for the map.
    private(set) var apps: [AppSummary] = []
    var onAppsChanged: (([AppSummary]) -> Void)?
    /// The app of the selected row (nil = none); drives the map highlight and page filters.
    var onSelectionChanged: ((AppSummary?) -> Void)?
    /// Shows the History page for an app (double-click, context menu).
    var onShowHistory: ((AppSummary) -> Void)?
    var onSelectTab: ((DetailPageKind) -> Void)?
    var onOpenInNewWindow: ((DetailPageKind) -> Void)?
    private var isReloading = false

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shown next to the title when the list is fed by the demo data source.
    func setSourceBadge(for source: FlowSource) {
        let title: String?
        switch source {
        case .filter:
            title = nil
            badgeButton.toolTip = nil
        case .monitor:
            title = String(localized: "MONITOR ONLY")
            badgeButton.toolTip = String(localized: "Showing your apps' connections without the filter extension: nothing is blocked, byte counts and system processes aren't visible. Click to set up full filtering.")
        case .demo:
            title = String(localized: "DEMO")
            badgeButton.toolTip = String(localized: "Synthetic demo data (-demo launch argument).")
        }
        badgeButton.attributedTitle = NSAttributedString(
            string: title ?? "",
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: Theme.pillOrange])
        badgeButton.isHidden = title == nil
        badgeButton.setAccessibilityLabel(badgeButton.toolTip)
        updateThroughput()
        reload()
    }

    override func loadView() {
        let root = SidebarBackgroundView()

        let tabs = NSStackView(views: DetailPageKind.allCases.map(makeTabButton))
        tabs.spacing = 2
        // Stack views stretch at the default hugging; the tab strip must stay its natural width.
        tabs.setHuggingPriority(.required, for: .horizontal)
        badgeButton.isBordered = false
        badgeButton.isHidden = true
        // Above the split holding priorities, so the tag only truncates when it truly lacks room.
        badgeButton.setContentCompressionResistancePriority(.init(490), for: .horizontal)
        (badgeButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        badgeButton.action = #selector(AppDelegate.showOnboarding(_:))
        hiddenProcessesLabel.alignment = .right
        hiddenProcessesLabel.toolTip = String(localized: "Only the filter extension can see connections of system processes and other users' apps.")

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.textField.delegate = self
        searchBar.clearButton.target = self
        searchBar.clearButton.action = #selector(clearFilter(_:))
        searchBar.timeButton.target = self
        searchBar.timeButton.action = #selector(showTimeMenu(_:))
        searchBar.setTimeTitle(store.timeWindow.shortLabel)

        configureOutline()
        showAllButton.target = self
        showAllButton.action = #selector(showAllHistory(_:))
        showAllButton.controlSize = .small
        showAllButton.isHidden = true
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.lineBreakMode = .byWordWrapping

        throughputLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        throughputLabel.toolTip = String(localized: "Current throughput, all apps")
        for view in [titleLabel, badgeButton, hiddenProcessesLabel, tabs, searchBar, scrollView,
                     emptyLabel, showAllButton, throughputLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        let leading = titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 92)
        let centerY = titleLabel.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 26)
        titleLeading = leading
        titleCenterY = centerY
        NSLayoutConstraint.activate([
            leading,
            centerY,
            badgeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            badgeButton.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            // At the narrowest sidebar the MONITOR ONLY tag truncates rather than overlap the tabs.
            badgeButton.trailingAnchor.constraint(lessThanOrEqualTo: tabs.leadingAnchor, constant: -6),
            tabs.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            searchBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 62),
            searchBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),

            scrollView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: throughputLabel.topAnchor, constant: -8),

            throughputLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            throughputLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            hiddenProcessesLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            hiddenProcessesLabel.firstBaselineAnchor.constraint(equalTo: throughputLabel.firstBaselineAnchor),
            hiddenProcessesLabel.leadingAnchor.constraint(greaterThanOrEqualTo: throughputLabel.trailingAnchor, constant: 12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 60),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -60),
            showAllButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),
            showAllButton.centerXAnchor.constraint(equalTo: emptyLabel.centerXAnchor),
        ])
        view = root
    }

    // MARK: - Pane tabs

    private func makeTabButton(_ kind: DetailPageKind) -> NSView {
        let button = PaneTabButton(kind: kind)
        button.target = self
        button.action = #selector(tabClicked(_:))
        let menu = NSMenu()
        let item = NSMenuItem(
            title: String(localized: "Open \(kind.title) in New Window"), action: #selector(openTabInNewWindow(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = kind.rawValue
        menu.addItem(item)
        button.menu = menu
        tabButtons[kind] = button
        return button
    }

    /// Selected tab gets the capsule; none while the pane is collapsed.
    func updateTabs(selected: DetailPageKind, isCollapsed: Bool) {
        _ = view
        for (kind, button) in tabButtons {
            let isSelected = kind == selected && !isCollapsed
            button.isSelected = isSelected
            let shortcut = " (⌘\(kind.keyEquivalent))"
            button.toolTip = isSelected
                ? String(localized: "Hide Detail Pane") + " (⇧⌘M)"
                : kind.title + shortcut
        }
    }

    @objc private func tabClicked(_ sender: PaneTabButton) {
        onSelectTab?(sender.kind)
    }

    @objc private func openTabInNewWindow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = DetailPageKind(rawValue: raw) else { return }
        onOpenInNewWindow?(kind)
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 18
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(showHistoryForClickedRow(_:))
        outlineView.setAccessibilityLabel(String(localized: "Apps"))

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reload), name: Store.flowsDidChange, object: store)
        center.addObserver(self, selector: #selector(reload), name: Store.rulesDidChange, object: store)
        center.addObserver(self, selector: #selector(viewOptionsChanged), name: Store.viewOptionsDidChange, object: store)
        reload()
        updateThroughput()
        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.updateThroughput() }
        }
        RunLoop.main.add(timer, forMode: .common)
        throughputTimer = timer
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        alignTitleWithTrafficLights()
    }

    /// Places the title right of the window buttons, on their center line.
    private func alignTitleWithTrafficLights() {
        guard let zoom = view.window?.standardWindowButton(.zoomButton), zoom.superview != nil else { return }
        let frame = zoom.convert(zoom.bounds, to: view)
        let leading = frame.maxX + 22
        let centerY = view.bounds.height - frame.midY
        if titleLeading?.constant != leading { titleLeading?.constant = leading }
        if abs((titleCenterY?.constant ?? 0) - centerY) > 0.5 { titleCenterY?.constant = centerY }
    }

    private func updateThroughput() {
        let hidden = store.hiddenSystemProcesses
        hiddenProcessesLabel.stringValue = store.source == .monitor && hidden > 0
            ? String(localized: "\(hidden) system processes hidden")
            : ""
        guard store.hasByteCounts else {
            // No numbers that look real: libproc has no per-socket byte counters.
            throughputLabel.stringValue = "↓ —   ↑ —"
            throughputLabel.toolTip = String(localized: "Byte counts need the filter extension.")
            return
        }
        throughputLabel.toolTip = String(localized: "Current throughput, all apps")
        let rate = store.throughput()
        func perSecond(_ value: Double) -> String {
            String(format: String(localized: "%@/s"), ByteCountFormatter.string(for: UInt64(value.rounded())))
        }
        throughputLabel.stringValue = "↓ \(perSecond(rate.bytesIn))   ↑ \(perSecond(rate.bytesOut))"
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchBar.textField)
    }

    // MARK: - Data

    @objc private func viewOptionsChanged() {
        if searchBar.textField.stringValue != store.filterText {
            searchBar.textField.stringValue = store.filterText
        }
        searchBar.setTimeTitle(store.timeWindow.shortLabel)
        reload()
    }

    @objc func reload() {
        // reloadData/restoreSelection fire selection changes; report one after.
        isReloading = true
        defer {
            isReloading = false
            onSelectionChanged?(selectedApp)
        }
        let summaries = store.appSummaries()
        apps = summaries

        let expanded = expandedKeys()
        let selected = selectedKey()

        var newNodes: [AppNode] = []
        var liveProcesses: Set<String> = []
        var liveDestinations: Set<String> = []
        func destinationNodes(_ destinations: [DestinationSummary], prefix: String, app: AppNode, process: ProcessNode?) -> [DestinationNode] {
            destinations.map { destination in
                let key = "\(prefix)#\(destination.id)"
                liveDestinations.insert(key)
                let child = destinationCache[key] ?? DestinationNode(key: key, destination: destination, parent: app, process: process)
                child.destination = destination
                destinationCache[key] = child
                return child
            }
        }
        for summary in summaries {
            let node = nodeCache[summary.id] ?? AppNode(app: summary)
            node.app = summary
            if summary.processes.count > 1 {
                node.children = summary.processes.map { process in
                    let key = "\(summary.id)#\(process.id)"
                    liveProcesses.insert(key)
                    let processNode = processCache[key] ?? ProcessNode(key: key, process: process, parent: node)
                    processNode.process = process
                    processNode.children = destinationNodes(process.destinations, prefix: key, app: node, process: processNode)
                    processCache[key] = processNode
                    return processNode
                }
            } else {
                node.children = destinationNodes(summary.destinations, prefix: summary.id, app: node, process: nil)
            }
            nodeCache[summary.id] = node
            newNodes.append(node)
        }
        let liveApps = Set(summaries.map(\.id))
        nodeCache = nodeCache.filter { liveApps.contains($0.key) }
        processCache = processCache.filter { liveProcesses.contains($0.key) }
        destinationCache = destinationCache.filter { liveDestinations.contains($0.key) }
        nodes = newNodes

        // Refreshes (every 5 s and on new data) must not jump: keep scroll, expansion, selection.
        let scrollOrigin = scrollView.contentView.bounds.origin
        outlineView.reloadData()
        for node in nodes where expanded.contains(node.key) {
            outlineView.expandItem(node)
            for case let process as ProcessNode in node.children where expanded.contains(process.key) {
                outlineView.expandItem(process)
            }
        }
        restoreSelection(selected)
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateEmptyState()
        onAppsChanged?(summaries)
    }

    private func updateEmptyState() {
        let isEmpty = nodes.isEmpty
        emptyLabel.isHidden = !isEmpty
        emptyLabel.stringValue = store.filterText.isEmpty
            ? store.timeWindow.emptyMessage
            : String(localized: "No apps match the filter.")
        showAllButton.isHidden = !(isEmpty && store.filterText.isEmpty && store.timeWindow != .all)
    }

    @objc private func showAllHistory(_ sender: Any?) {
        store.timeWindow = .all
    }

    private func selectedKey() -> String? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        switch outlineView.item(atRow: row) {
        case let node as AppNode: return node.key
        case let node as ProcessNode: return node.key
        case let node as DestinationNode: return node.key
        default: return nil
        }
    }

    private func expandedKeys() -> Set<String> {
        var keys: Set<String> = []
        for row in 0..<outlineView.numberOfRows {
            let item = outlineView.item(atRow: row)
            guard outlineView.isItemExpanded(item) else { continue }
            if let node = item as? AppNode { keys.insert(node.key) }
            if let node = item as? ProcessNode { keys.insert(node.key) }
        }
        return keys
    }

    private func restoreSelection(_ key: String?) {
        guard let key else { return }
        let item: Any? = nodeCache[key] ?? processCache[key] ?? destinationCache[key]
        let row = item.map { outlineView.row(forItem: $0) } ?? -1
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    /// App of the selected row (a process or destination row counts as its app).
    var selectedApp: AppSummary? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        switch outlineView.item(atRow: row) {
        case let node as AppNode: return node.app
        case let node as ProcessNode: return node.parent?.app
        case let node as DestinationNode: return node.parent?.app
        default: return nil
        }
    }

    /// Selects an app's row (History for a right-clicked app).
    func select(appID: String) {
        guard let node = nodeCache[appID] else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// Clearing the pages' app filter clears the list selection.
    func deselectAll() {
        outlineView.deselectAll(nil)
    }

    // MARK: - Disconnect

    private func disconnect(_ identities: [AppIdentity], name: String, for duration: DisconnectDuration) {
        changeDisconnect(identities, actionName: String(localized: "Disconnect \(name)")) {
            store.disconnect(identities, for: duration)
        }
    }

    private func reconnect(_ identities: [AppIdentity], name: String) {
        changeDisconnect(identities, actionName: String(localized: "Reconnect \(name)")) {
            store.reconnect(identities)
        }
    }

    /// Applies a Disconnect/Reconnect and registers ⌘Z (and redo) for exactly that change.
    private func changeDisconnect(_ identities: [AppIdentity], actionName: String, _ change: () -> Void) {
        let before = store.disconnectRules(for: identities)
        change()
        if let undoManager = view.window?.undoManager {
            store.registerDisconnectUndo(undoManager, for: identities, restoring: before, actionName: actionName)
        }
    }

    @objc private func disconnectFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? DisconnectTarget else { return }
        if let duration = target.duration {
            disconnect(target.identities, name: target.name, for: duration)
        } else {
            reconnect(target.identities, name: target.name)
        }
    }

    private func rowModel(
        name: String, icon: NSImage, toolTip: String, isActive: Bool, ruleState: AppSummary.RuleState,
        disconnect: DisconnectStatus?, bytes: (UInt64, UInt64), destinationCount: Int
    ) -> ActionRowModel {
        ActionRowModel(
            name: name, icon: icon, toolTip: toolTip,
            status: RowStatus.make(isActive: isActive, ruleState: ruleState, disconnect: disconnect,
                                   enforcing: store.isEnforcing, now: Date()),
            bytes: bytes, destinationCount: destinationCount, disconnect: disconnect,
            controlToolTip: RowStatus.controlToolTip(disconnect: disconnect, enforcing: store.isEnforcing))
    }

    // MARK: - Actions

    @objc private func clearFilter(_ sender: Any?) {
        store.filterText = ""
        searchBar.textField.stringValue = ""
    }

    @objc private func showTimeMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for window in TimeWindow.allCases {
            let item = NSMenuItem(title: window.longLabel, action: #selector(selectTimeWindow(_:)), keyEquivalent: "")
            item.target = self
            item.tag = window.rawValue
            item.state = window == store.timeWindow ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    @objc private func selectTimeWindow(_ sender: NSMenuItem) {
        guard let window = TimeWindow(rawValue: sender.tag) else { return }
        store.timeWindow = window
    }

    /// Double-click: app detail for the row's app (the chevron still expands).
    @objc private func showHistoryForClickedRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        guard let node = (item as? AppNode) ?? (item as? ProcessNode)?.parent ?? (item as? DestinationNode)?.parent else { return }
        onShowHistory?(node.app)
    }

    @objc private func showHistory(_ sender: NSMenuItem) {
        guard let app = (sender.representedObject as? AppNode)?.app else { return }
        onShowHistory?(app)
    }

    @objc private func blockApp(_ sender: NSMenuItem) {
        guard let app = (sender.representedObject as? AppNode)?.app else { return }
        store.setAppRule(.block, for: app.identities)
    }

    @objc private func allowApp(_ sender: NSMenuItem) {
        guard let app = (sender.representedObject as? AppNode)?.app else { return }
        store.setAppRule(.allow, for: app.identities)
    }

    @objc private func blockDomain(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        store.setDomainRule(.block, domain: host)
    }

    @objc private func allowDomain(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        store.setDomainRule(.allow, domain: host)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Outline data source / delegate

extension AppListViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return nodes.count }
        if let node = item as? AppNode { return node.children.count }
        return (item as? ProcessNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return nodes[index] }
        if let node = item as? AppNode { return node.children[index] }
        return (item as? ProcessNode)?.children[index] ?? NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? AppNode { return !node.children.isEmpty }
        if let node = item as? ProcessNode { return !node.children.isEmpty }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch item {
        case is AppNode: AppCellView.rowHeight
        case is ProcessNode: AppCellView.processRowHeight
        default: DestinationCellView.rowHeight
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ListRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? AppNode {
            let app = node.app
            let cell = outlineView.makeView(withIdentifier: AppCellView.Style.app.identifier, owner: self) as? AppCellView
                ?? AppCellView(style: .app)
            cell.configure(with: rowModel(
                name: app.name, icon: AppIconService.shared.icon(forExecutablePath: app.executablePath),
                toolTip: app.executablePath, isActive: app.isActive, ruleState: app.ruleState,
                disconnect: app.disconnect, bytes: (app.bytesIn, app.bytesOut), destinationCount: app.destinations.count))
            // The whole group: every process of the app.
            cell.onDisconnect = { [weak self] duration in self?.disconnect(app.identities, name: app.name, for: duration) }
            cell.onReconnect = { [weak self] in self?.reconnect(app.identities, name: app.name) }
            return cell
        }
        if let node = item as? ProcessNode {
            let process = node.process
            let cell = outlineView.makeView(withIdentifier: AppCellView.Style.process.identifier, owner: self) as? AppCellView
                ?? AppCellView(style: .process)
            let bytes = process.destinations.reduce((UInt64(0), UInt64(0))) { ($0.0 &+ $1.bytesIn, $0.1 &+ $1.bytesOut) }
            cell.configure(with: rowModel(
                name: process.name, icon: AppIconService.shared.processIcon(forExecutablePath: process.identity.executablePath),
                toolTip: process.identity.executablePath, isActive: process.isActive, ruleState: process.ruleState,
                disconnect: process.disconnect, bytes: bytes, destinationCount: process.destinations.count))
            // Only this process's identity.
            cell.onDisconnect = { [weak self] duration in self?.disconnect([process.identity], name: process.name, for: duration) }
            cell.onReconnect = { [weak self] in self?.reconnect([process.identity], name: process.name) }
            return cell
        }
        if let node = item as? DestinationNode {
            let cell = outlineView.makeView(withIdentifier: DestinationCellView.identifier, owner: self) as? DestinationCellView
                ?? DestinationCellView()
            cell.configure(with: node.destination, enforcing: store.isEnforcing, hasByteCounts: store.hasByteCounts)
            return cell
        }
        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        onSelectionChanged?(selectedApp)
    }
}

// MARK: - Filter field

extension AppListViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        store.filterText = searchBar.textField.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            clearFilter(nil)
            return true
        }
        return false
    }
}

// MARK: - Context menu

extension AppListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        let appNode = (item as? AppNode) ?? (item as? ProcessNode)?.parent ?? (item as? DestinationNode)?.parent
        let destination = (item as? DestinationNode)?.destination

        func add(_ title: String, _ action: Selector, _ object: Any?) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = object
            menu.addItem(menuItem)
        }

        // Disconnect options for the clicked app (all processes) or process (just it).
        let disconnectTarget: (identities: [AppIdentity], name: String, status: DisconnectStatus?)?
        switch item {
        case let node as AppNode: disconnectTarget = (node.app.identities, node.app.name, node.app.disconnect)
        case let node as ProcessNode: disconnectTarget = ([node.process.identity], node.process.name, node.process.disconnect)
        default: disconnectTarget = nil
        }
        if let target = disconnectTarget {
            if target.status != nil {
                add(String(localized: "Reconnect"), #selector(disconnectFromMenu(_:)),
                    DisconnectTarget(identities: target.identities, name: target.name, duration: nil))
            } else {
                for duration in DisconnectDuration.allCases {
                    add(duration.menuTitle, #selector(disconnectFromMenu(_:)),
                        DisconnectTarget(identities: target.identities, name: target.name, duration: duration))
                }
            }
            menu.addItem(.separator())
        }

        if let appNode {
            add(String(localized: "Show History"), #selector(showHistory(_:)), appNode)
            menu.addItem(.separator())
            add(String(localized: "Block App"), #selector(blockApp(_:)), appNode)
            add(String(localized: "Allow App"), #selector(allowApp(_:)), appNode)
        }
        if let destination {
            menu.addItem(.separator())
            if let host = destination.host {
                add(String(localized: "Block Domain"), #selector(blockDomain(_:)), host)
                add(String(localized: "Allow Domain"), #selector(allowDomain(_:)), host)
                menu.addItem(.separator())
                add(String(localized: "Copy Host"), #selector(copyText(_:)), host)
            }
            add(String(localized: "Copy IP Address"), #selector(copyText(_:)), destination.ip)
        }
    }
}

/// Sidebar tab for a detail-pane page: dim symbol, white on a subtle capsule when selected.
private final class PaneTabButton: NSButton {
    let kind: DetailPageKind

    var isSelected = false {
        didSet {
            contentTintColor = isSelected ? .white : NSColor(white: 1, alpha: 0.6)
            layer?.backgroundColor = isSelected ? NSColor(white: 1, alpha: 0.16).cgColor : nil
            setAccessibilityValue(isSelected ? String(localized: "Selected") : nil)
        }
    }

    init(kind: DetailPageKind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = Theme.symbol(kind.symbolName, pointSize: 14, weight: .medium)
        contentTintColor = NSColor(white: 1, alpha: 0.6)
        wantsLayer = true
        layer?.cornerRadius = 13
        setAccessibilityLabel(kind.title)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
