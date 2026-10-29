import AppKit
import YASShared

/// Which app the History page (and Traffic, Rules) is narrowed to.
struct AppHistoryFilter: Hashable {
    let name: String
    let executablePath: String
    let identities: [AppIdentity]

    init(app: AppSummary) {
        name = app.name
        executablePath = app.executablePath
        identities = app.identities
    }
}

/// Time range of the History page.
enum HistoryRange: Int, CaseIterable {
    case hour, day, week, month, all

    var title: String {
        switch self {
        case .hour: String(localized: "Last hour")
        case .day: String(localized: "Last 24 hours")
        case .week: String(localized: "Last 7 days")
        case .month: String(localized: "Last 30 days")
        case .all: String(localized: "All history")
        }
    }

    func since(now: Date = Date()) -> Date? {
        switch self {
        case .hour: now.addingTimeInterval(-3600)
        case .day: now.addingTimeInterval(-86_400)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        case .all: nil
        }
    }
}

/// History page: paged from SQLite, newest first.
/// Lives in the detail pane or a detached window.
@MainActor
final class HistoryPageController: NSViewController, DetailPage {
    private typealias Column = HistoryColumnPolicy.Column

    let pageKind = DetailPageKind.history
    /// Clearing the app filter from the page (Show All Apps) — the pane deselects the list.
    var onClearAppFilter: (() -> Void)?
    private var protocolColumnVisible = true
    /// Without a Verdict column the host text carries the verdict's colour.
    private var verdictColumnVisible = true
    private var fittedWidth: CGFloat = 0

    private static let pageSize = 200

    private let store: Store
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let verdictPopUp = NSPopUpButton()
    private let rangePopUp = NSPopUpButton()
    private let statusLabel = NSTextField.label(size: 11, color: .secondaryLabelColor)
    /// Filter bar: one row when wide; search on its own row above the pop-ups when narrow.
    private let filterRows = NSStackView()
    private let searchRow = NSStackView()
    private let controlsRow = NSStackView()
    private var filterBarIsWrapped: Bool?
    private let emptyLabel = NSTextField.label(size: 13, color: .secondaryLabelColor)
    private let header = AppHistoryHeaderView()
    private var dataSource: NSTableViewDiffableDataSource<Int, UUID>!

    private var records: [UUID: FlowRecord] = [:]
    private var order: [UUID] = []
    private var appFilter: AppHistoryFilter?
    private var isLoading = false
    private var reachedEnd = false
    /// Bumped whenever the query changes, so stale pages are dropped.
    private var generation = 0
    private var lastLiveRefresh = Date.distantPast
    private var liveRefreshScheduled = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(historyChanged), name: Store.historyDidChange, object: store)
        center.addObserver(self, selector: #selector(rulesChanged), name: Store.rulesDidChange, object: store)
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = makeContent()
        configureDataSource()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadFromStart()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyColumnPolicy()
    }

    /// Narrows History to one app (nil = all apps).
    func setAppFilter(_ filter: AppHistoryFilter?) {
        guard filter != appFilter else { return }
        appFilter = filter
        guard isViewLoaded else { return }
        header.isHidden = filter == nil
        reloadFromStart()
    }

    /// Query for the current filters (internal for tests).
    var queryForTesting: HistoryQuery { currentQuery }

    private var isOnScreen: Bool { isViewLoaded && view.window?.isVisible == true && view.superview != nil }

    /// Hides less important columns when the pane is narrow.
    private func applyColumnPolicy() {
        layOutFilterBar()
        let visible = Set(HistoryColumnPolicy.visibleColumns(
            forWidth: scrollView.contentSize.width, spacing: tableView.intercellSpacing.width))
        var changed = false
        for column in tableView.tableColumns {
            guard let kind = Column(rawValue: column.identifier.rawValue) else { continue }
            let hidden = !visible.contains(kind)
            if column.isHidden != hidden {
                column.isHidden = hidden
                changed = true
            }
        }
        protocolColumnVisible = visible.contains(.proto)
        verdictColumnVisible = visible.contains(.verdict)
        for column in tableView.tableColumns {
            guard let kind = Column(rawValue: column.identifier.rawValue) else { continue }
            column.minWidth = HistoryColumnPolicy.minimumWidth(of: kind, protocolMerged: !protocolColumnVisible)
        }
        if changed { tableView.reloadData() }
        // Fit the remaining columns to the pane instead of scrolling sideways.
        let available = scrollView.contentSize.width
        if abs(fittedWidth - available) > 0.5 || changed {
            fittedWidth = available
            tableView.sizeToFit()
        }
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        searchField.placeholderString = String(localized: "Search app, host, IP or country")
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(filtersChanged(_:))

        verdictPopUp.addItem(withTitle: String(localized: "All verdicts"))
        for verdict in Verdict.allCases {
            verdictPopUp.addItem(withTitle: verdict.title)
            verdictPopUp.lastItem?.representedObject = verdict.rawValue
        }
        verdictPopUp.target = self
        verdictPopUp.action = #selector(filtersChanged(_:))

        for range in HistoryRange.allCases {
            rangePopUp.addItem(withTitle: range.title)
            rangePopUp.lastItem?.tag = range.rawValue
        }
        rangePopUp.selectItem(withTag: HistoryRange.day.rawValue)
        rangePopUp.target = self
        rangePopUp.action = #selector(filtersChanged(_:))

        for row in [searchRow, controlsRow] {
            row.orientation = .horizontal
            row.spacing = 8
        }
        filterRows.orientation = .vertical
        filterRows.alignment = .leading
        filterRows.spacing = 8
        filterRows.addArrangedSubview(searchRow)
        filterRows.addArrangedSubview(controlsRow)
        // The search field takes whatever width its row leaves over; the pop-ups keep theirs.
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        searchField.setContentHuggingPriority(.init(200), for: .horizontal)
        searchField.setContentCompressionResistancePriority(.init(235), for: .horizontal)
        for popUp in [verdictPopUp, rangePopUp] {
            popUp.setContentHuggingPriority(.required, for: .horizontal)
            popUp.setContentCompressionResistancePriority(.init(245), for: .horizontal)
        }
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        for row in [searchRow, controlsRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: filterRows.widthAnchor).isActive = true
        }
        setFilterBarWrapped(false)

        header.isHidden = appFilter == nil
        header.showAllButton.target = self
        header.showAllButton.action = #selector(showAllApps(_:))

        configureTable()
        emptyLabel.stringValue = String(localized: "No connections match.")
        emptyLabel.isHidden = true

        let stack = NSStackView(views: [header, filterRows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        filterRows.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let root = NSView()
        for view in [stack, scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: stack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 80),
        ])
        return root
    }

    /// One row needs the search minimum, both pop-ups and the gaps; otherwise wrap.
    private func layOutFilterBar() {
        // Reading `view` before it has loaded would start loadView again (this runs from
        // notifications that can fire while the table is being built).
        guard isViewLoaded else { return }
        let available = view.bounds.width - 28
        let oneRow = 140 + verdictPopUp.intrinsicContentSize.width + rangePopUp.intrinsicContentSize.width + 16 + 90
        setFilterBarWrapped(available < oneRow)
        // The count is a nicety: hide it rather than show "2…".
        let controls = filterBarIsWrapped == true
            ? verdictPopUp.intrinsicContentSize.width + rangePopUp.intrinsicContentSize.width + 16
            : 140 + verdictPopUp.intrinsicContentSize.width + rangePopUp.intrinsicContentSize.width + 24
        statusLabel.isHidden = available - controls < statusLabel.intrinsicContentSize.width
    }

    private func setFilterBarWrapped(_ wrapped: Bool) {
        guard filterBarIsWrapped != wrapped else { return }
        filterBarIsWrapped = wrapped
        for view in [searchField, verdictPopUp, rangePopUp, statusLabel] as [NSView] {
            view.removeFromSuperview()
        }
        if wrapped {
            searchRow.setViews([searchField], in: .leading)
            controlsRow.setViews([verdictPopUp, rangePopUp, statusLabel], in: .leading)
        } else {
            searchRow.setViews([searchField, verdictPopUp, rangePopUp, statusLabel], in: .leading)
            controlsRow.setViews([], in: .leading)
        }
        controlsRow.isHidden = !wrapped
    }

    private func configureTable() {
        let titles: [Column: String] = [
            .time: String(localized: "Time"), .app: String(localized: "App"), .host: String(localized: "Host"),
            .port: String(localized: "Port"), .proto: String(localized: "Protocol"),
            .country: String(localized: "Country"), .verdict: String(localized: "Verdict"),
        ]
        let widths: [Column: CGFloat] = [.time: 140, .app: 160, .host: 230, .port: 50, .proto: 64, .country: 130, .verdict: 120]
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = titles[column] ?? ""
            tableColumn.width = widths[column] ?? 100
            tableColumn.minWidth = HistoryColumnPolicy.minimumWidth(of: column, protocolMerged: false)
            tableView.addTableColumn(tableColumn)
        }
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityLabel(String(localized: "Connections"))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
    }

    private func configureDataSource() {
        dataSource = NSTableViewDiffableDataSource<Int, UUID>(tableView: tableView) { [weak self] _, column, _, id in
            guard let self, let record = self.records[id], let kind = Column(rawValue: column.identifier.rawValue) else {
                return NSView()
            }
            return Self.centered(self.cell(for: record, column: kind))
        }
    }

    /// Cell container that centers its content vertically in the row.
    private static func centered(_ content: NSView) -> NSView {
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func cell(for record: FlowRecord, column: Column) -> NSView {
        switch column {
        case .time:
            return NSTextField.label(Self.timeFormatter.string(from: record.timestamp), size: 12, color: .secondaryLabelColor)
        case .app:
            let icon = NSImageView(image: AppIconService.shared.icon(forExecutablePath: record.app.executablePath))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let name = NSTextField.label(record.appName, size: 12)
            name.toolTip = record.app.executablePath
            let stack = NSStackView(views: [icon, name])
            stack.spacing = 5
            return stack
        case .host:
            var color: NSColor = record.hostIsReverseDNS ? .secondaryLabelColor : .labelColor
            var lines = ["\(record.displayHost)\n\(record.ip)"]
            if record.hostIsReverseDNS { lines.append(String(localized: "Name from reverse DNS")) }
            if !verdictColumnVisible, let (title, tint) = notableVerdict(for: record) {
                color = tint
                lines.append(title)
            }
            let label = NSTextField.label(record.displayHost, size: 12, color: color)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = lines.joined(separator: "\n")
            return label
        case .port:
            return NSTextField.label(
                HistoryColumnPolicy.portText(port: record.port, proto: record.proto, protocolColumnVisible: protocolColumnVisible),
                size: 12, color: .secondaryLabelColor)
        case .proto:
            return NSTextField.label(record.proto.rawValue.uppercased(), size: 12, color: .secondaryLabelColor)
        case .country:
            let text = record.country.map { "\(CountryCentroids.flag(for: $0)) \(CountryCentroids.name(for: $0))" }
                ?? String(localized: "Unknown country")
            return NSTextField.label(text, size: 12, color: record.country == nil ? .tertiaryLabelColor : .labelColor)
        case .verdict:
            // Monitor-only rows were observed, not filtered: say so, and flag what a rule would block.
            let symbol: String
            let title: String
            let tint: NSColor
            if record.source == .monitor {
                let blocked = store.wouldBlock(record)
                symbol = blocked ? "hand.raised.fill" : "eye.fill"
                title = blocked ? String(localized: "Would block") : String(localized: "Observed")
                tint = blocked ? Theme.pendingOrange : .secondaryLabelColor
            } else {
                symbol = record.verdict.symbolName
                title = record.verdict.title
                tint = record.verdict.tint
            }
            let icon = NSImageView(image: Theme.symbol(symbol, pointSize: 11, weight: .semibold) ?? NSImage())
            icon.contentTintColor = tint
            let label = NSTextField.label(title, size: 12, color: tint)
            let stack = NSStackView(views: [icon, label])
            stack.spacing = 4
            return stack
        }
    }

    /// Verdicts worth flagging when the Verdict column is hidden (plain allowed/observed are not).
    private func notableVerdict(for record: FlowRecord) -> (String, NSColor)? {
        if record.source == .monitor {
            return store.wouldBlock(record) ? (String(localized: "Would block"), Theme.pendingOrange) : nil
        }
        switch record.verdict {
        case .allowed: return nil
        default: return (record.verdict.title, record.verdict.tint)
        }
    }

    // MARK: - Querying

    private var currentQuery: HistoryQuery {
        var query = HistoryQuery()
        query.text = searchField.stringValue
        query.verdict = (verdictPopUp.selectedItem?.representedObject as? String).flatMap(Verdict.init(rawValue:))
        query.since = HistoryRange(rawValue: rangePopUp.selectedTag())?.since()
        query.appKeys = appFilter.map { Array(Set($0.identities.map(\.matchKey))) }
        return query
    }

    @objc private func filtersChanged(_ sender: Any?) {
        reloadFromStart()
    }

    @objc private func showAllApps(_ sender: Any?) {
        if let onClearAppFilter { onClearAppFilter() } else { setAppFilter(nil) }
    }

    private func reloadFromStart() {
        generation += 1
        records.removeAll()
        order.removeAll()
        reachedEnd = false
        isLoading = false
        applySnapshot(animated: false)
        tableView.scrollRowToVisible(0)
        loadNextPage()
        refreshHeader()
    }

    private func loadNextPage() {
        guard !isLoading, !reachedEnd else { return }
        guard let history = store.history else {
            statusLabel.stringValue = String(localized: "History is unavailable.")
            layOutFilterBar()
            return
        }
        isLoading = true
        let generation = generation
        let query = currentQuery
        let cursor = order.last.flatMap { records[$0] }.map { HistoryCursor(timestamp: $0.timestamp, id: $0.id) }
        Task {
            let page = (try? await history.flows(matching: query, after: cursor, limit: Self.pageSize)) ?? []
            guard generation == self.generation else { return }
            self.isLoading = false
            self.reachedEnd = page.count < Self.pageSize
            self.merge(page)
            // Keep filling until the view is scrollable.
            if !self.reachedEnd, self.isNearBottom { self.loadNextPage() }
        }
    }

    /// Newly recorded flows: re-read the newest page and merge, at most once a second,
    /// only while the user looks at the top (so the list doesn't jump while reading).
    @objc private func historyChanged() {
        guard isOnScreen, !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        let delay = max(0, 1 - Date().timeIntervalSince(lastLiveRefresh))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.liveRefreshScheduled = false
            self.lastLiveRefresh = Date()
            guard let history = self.store.history else { return }
            if self.order.isEmpty {
                self.reloadFromStart()
                return
            }
            guard self.scrollView.contentView.bounds.minY < 40 else { return }
            let generation = self.generation
            let page = (try? await history.flows(matching: self.currentQuery, limit: Self.pageSize)) ?? []
            guard generation == self.generation else { return }
            self.merge(page)
            self.refreshHeader()
        }
    }

    @objc private func rulesChanged() {
        refreshHeader()
    }

    private func merge(_ page: [FlowRecord]) {
        for record in page { records[record.id] = record }
        order = records.values.sorted {
            $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.id.uuidString > $1.id.uuidString
        }.map(\.id)
        applySnapshot(animated: false)
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(order, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: animated)
        emptyLabel.isHidden = !order.isEmpty || isLoading
        let count = order.count
        statusLabel.stringValue = reachedEnd
            ? String(localized: "\(count) connections")
            : String(localized: "\(count)+ connections")
        layOutFilterBar()
    }

    private var isNearBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY > tableView.bounds.height - 400
    }

    @objc private func scrolled() {
        if isNearBottom { loadNextPage() }
    }

    private func refreshHeader() {
        guard let filter = appFilter, let history = store.history else { return }
        header.configure(filter: filter, totals: nil, ruleState: store.ruleState(for: filter.identities))
        let keys = Array(Set(filter.identities.map(\.matchKey)))
        Task {
            guard let totals = try? await history.totals(forAppKeys: keys), self.appFilter == filter else { return }
            self.header.configure(filter: filter, totals: totals, ruleState: self.store.ruleState(for: filter.identities))
        }
    }

    // MARK: - Context menu actions

    private func clickedRecord() -> FlowRecord? {
        let row = tableView.clickedRow
        guard row >= 0, let id = dataSource.itemIdentifier(forRow: row) else { return nil }
        return records[id]
    }

    @objc private func blockApp(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? FlowRecordBox else { return }
        // Whole app group (helpers included), same as the main list.
        store.setAppRule(.block, for: store.groupIdentities(for: record.value.app))
    }

    @objc private func allowApp(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? FlowRecordBox else { return }
        store.setAppRule(.allow, for: store.groupIdentities(for: record.value.app))
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

/// Reference wrapper so a record can ride in `NSMenuItem.representedObject`.
private final class FlowRecordBox: NSObject {
    let value: FlowRecord
    init(_ value: FlowRecord) { self.value = value }
}

extension HistoryPageController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let record = clickedRecord() else { return }
        func add(_ title: String, _ action: Selector, _ object: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            menu.addItem(item)
        }
        add(String(localized: "Block App"), #selector(blockApp(_:)), FlowRecordBox(record))
        add(String(localized: "Allow App"), #selector(allowApp(_:)), FlowRecordBox(record))
        if let host = record.host {
            menu.addItem(.separator())
            add(String(localized: "Block Domain"), #selector(blockDomain(_:)), host)
            add(String(localized: "Allow Domain"), #selector(allowDomain(_:)), host)
            menu.addItem(.separator())
            add(String(localized: "Copy Host"), #selector(copyText(_:)), host)
        } else {
            menu.addItem(.separator())
        }
        add(String(localized: "Copy IP Address"), #selector(copyText(_:)), record.ip)
    }
}

/// App detail header: icon, name, totals and rule status.
private final class AppHistoryHeaderView: NSView {
    let showAllButton = NSButton(title: String(localized: "Show All Apps"), target: nil, action: nil)
    private let iconView = NSImageView()
    private let nameLabel = NSTextField.label(size: 17, weight: .bold)
    private let totalsLabel = NSTextField.label(size: 12, color: .secondaryLabelColor)
    private let seenLabel = NSTextField.label(size: 11, color: .tertiaryLabelColor)
    private let ruleLabel = NSTextField.label(size: 12, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [nameLabel, totalsLabel, seenLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [iconView, text, spacer, ruleLabel, showAllButton])
        row.alignment = .centerY
        row.spacing = 12
        // Narrow panes truncate the text and drop the rule label rather than widen the page.
        for label in [nameLabel, totalsLabel, seenLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        }
        row.setVisibilityPriority(.detachOnlyIfNecessary, for: ruleLabel)
        // Stack views refuse to clip their content by default; let them.
        text.setClippingResistancePriority(.init(240), for: .horizontal)
        row.setClippingResistancePriority(.init(240), for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(filter: AppHistoryFilter, totals: AppHistoryTotals?, ruleState: AppSummary.RuleState) {
        iconView.image = AppIconService.shared.icon(forExecutablePath: filter.executablePath)
        nameLabel.stringValue = filter.name
        if let totals {
            totalsLabel.stringValue = String(
                format: String(localized: "%lld connections · %lld blocked · %@ received · %@ sent"),
                totals.connections, totals.blocked,
                ByteCountFormatter.string(for: totals.bytesIn), ByteCountFormatter.string(for: totals.bytesOut))
            if let first = totals.firstSeen, let last = totals.lastSeen {
                seenLabel.stringValue = String(
                    format: String(localized: "First seen %@ · Last seen %@"),
                    first.formatted(date: .abbreviated, time: .shortened),
                    last.formatted(date: .abbreviated, time: .shortened))
            } else {
                seenLabel.stringValue = ""
            }
        } else {
            totalsLabel.stringValue = String(localized: "Loading…")
            seenLabel.stringValue = ""
        }
        switch ruleState {
        case .blocked:
            ruleLabel.stringValue = String(localized: "Blocked by rule")
            ruleLabel.textColor = Theme.blockedRed
        case .allowed:
            ruleLabel.stringValue = String(localized: "Allowed by rule")
            ruleLabel.textColor = Theme.activeGreen
        case .none:
            ruleLabel.stringValue = String(localized: "No app rule")
            ruleLabel.textColor = .secondaryLabelColor
        }
    }
}
