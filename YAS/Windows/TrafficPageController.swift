import AppKit
import YASShared

/// Traffic: sent/received chart from `traffic_buckets` plus a
/// per-app breakdown for the selected range. Selecting an app (here or in the main
/// list) filters the chart. Lives in the detail pane or a detached window.
@MainActor
final class TrafficPageController: NSViewController, DetailPage {
    let pageKind = DetailPageKind.traffic
    var onClearAppFilter: (() -> Void)?
    /// Identities of the app chosen in the main list (chart filter even before it has rows).
    private var appFilterKeys: [String]?
    private var isReloadingTable = false
    private var fittedWidth: CGFloat = 0

    private enum Column: String, CaseIterable {
        case app, received, sent, total, connections, share
    }

    private let store: Store
    private let rangeControl = NSSegmentedControl()
    private let filterLabel = NSTextField.label(size: 13, weight: .semibold)
    private let clearFilterButton = NSButton()
    private let totalsLabel = NSTextField.label(size: 12, color: .secondaryLabelColor)
    private let chart = TrafficChartView()
    private let tableView = NSTableView()
    private var rows: [AppTrafficShare] = []
    private var range: TrafficRange = .hour
    private var selectedAppID: String?
    private var generation = 0
    private var refreshScheduled = false
    private var lastRefresh = Date.distantPast

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyChanged), name: Store.historyDidChange, object: store)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = makeContent()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// Narrow panes: drop Share, then Connections (chart and table stay stacked).
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.share.rawValue))?.isHidden = width < 640
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.connections.rawValue))?.isHidden = width < 520
        if abs(fittedWidth - width) > 0.5 {
            fittedWidth = width
            tableView.sizeToFit()
        }
    }

    /// Follows the app selected in the main list (nil = all apps).
    func setAppFilter(_ filter: AppHistoryFilter?) {
        selectedAppID = filter?.identities.first.map(Store.groupKey(for:))
        appFilterKeys = filter.map { Array(Set($0.identities.map(\.matchKey))) }
        if isViewLoaded {
            updateFilterLabel()
            reload()
        }
    }

    /// Chart filter keys (internal for tests).
    var selectedAppIDForTesting: String? { selectedAppID }

    private var isOnScreen: Bool { isViewLoaded && view.window?.isVisible == true && view.superview != nil }

    // MARK: - Layout

    private func makeContent() -> NSView {
        rangeControl.segmentCount = TrafficRange.allCases.count
        for range in TrafficRange.allCases {
            rangeControl.setLabel(range.shortTitle, forSegment: range.rawValue)
            rangeControl.setWidth(52, forSegment: range.rawValue)
        }
        rangeControl.selectedSegment = range.rawValue
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged(_:))
        rangeControl.setAccessibilityLabel(String(localized: "Time range"))

        clearFilterButton.isBordered = false
        clearFilterButton.image = Theme.symbol("xmark.circle.fill", pointSize: 12, weight: .medium)
        clearFilterButton.contentTintColor = .secondaryLabelColor
        clearFilterButton.toolTip = String(localized: "Show all apps")
        clearFilterButton.setAccessibilityLabel(String(localized: "Show all apps"))
        clearFilterButton.target = self
        clearFilterButton.action = #selector(clearFilter(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [rangeControl, filterLabel, clearFilterButton, spacer, totalsLabel])
        bar.spacing = 10
        // Narrow panes drop the totals first, then the app label, never the range control.
        bar.setVisibilityPriority(.detachOnlyIfNecessary, for: totalsLabel)
        bar.setClippingResistancePriority(.init(240), for: .horizontal)
        bar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 900), for: filterLabel)
        bar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 900), for: clearFilterButton)
        for label in [totalsLabel, filterLabel] {
            label.setContentCompressionResistancePriority(.init(240), for: .horizontal)
            label.lineBreakMode = .byTruncatingTail
        }

        chart.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let root = NSView()
        for view in [bar, chart, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            chart.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            chart.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            chart.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            chart.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.45),
            scroll.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        updateFilterLabel()
        return root
    }

    private func configureTable() {
        let titles: [Column: String] = [
            .app: String(localized: "App"), .received: String(localized: "Received"), .sent: String(localized: "Sent"),
            .total: String(localized: "Total"), .connections: String(localized: "Connections"),
            .share: String(localized: "Share"),
        ]
        let widths: [Column: CGFloat] = [.app: 230, .received: 100, .sent: 100, .total: 100, .connections: 100, .share: 170]
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = titles[column] ?? ""
            tableColumn.width = widths[column] ?? 100
            tableColumn.minWidth = 60
            if column != .app && column != .share {
                tableColumn.headerCell.alignment = .right
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.style = .fullWidth
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(String(localized: "Traffic by app"))
    }

    // MARK: - Data

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        range = TrafficRange(rawValue: sender.selectedSegment) ?? .hour
        reload()
    }

    @objc private func clearFilter(_ sender: Any?) {
        if let onClearAppFilter {
            onClearAppFilter()
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Live update, at most every 2 seconds.
    @objc private func historyChanged() {
        guard isOnScreen, !refreshScheduled else { return }
        refreshScheduled = true
        let delay = max(0, 2 - Date().timeIntervalSince(lastRefresh))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.refreshScheduled = false
            self.reload()
        }
    }

    private func reload() {
        guard let history = store.history else { return }
        lastRefresh = Date()
        generation += 1
        let generation = generation
        let range = range
        let (start, end) = range.window(now: Date())
        let selectedKeys = rows.first { $0.id == selectedAppID }.map { $0.identities.map(\.matchKey) }
        Task {
            let appRows = (try? await history.appTraffic(from: start, to: end)) ?? []
            let shares = TrafficShares.compute(appRows, groupKey: Store.groupKey(for:)) {
                AppIconService.shared.displayName(forExecutablePath: $0.identity.executablePath)
            }
            // The selection may map to more identities now (a helper appeared).
            let keys = shares.first { $0.id == self.selectedAppID }.map { $0.identities.map(\.matchKey) }
                ?? selectedKeys ?? (self.selectedAppID == nil ? nil : self.appFilterKeys)
            let series = (try? await history.trafficSeries(from: start, to: end, step: range.step, appKeys: keys)) ?? []
            guard generation == self.generation else { return }
            self.apply(rows: shares, series: TrafficSeries.filled(series, from: start, to: end, step: range.step))
        }
    }

    private func apply(rows newRows: [AppTrafficShare], series: [TrafficPoint]) {
        rows = newRows
        // Reloading clears the table selection; that's not the user clearing the filter.
        isReloadingTable = true
        tableView.reloadData()
        if let selectedAppID, let index = rows.firstIndex(where: { $0.id == selectedAppID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        isReloadingTable = false
        chart.step = range.step
        chart.points = series
        chart.unavailableMessage = store.hasByteCounts
            ? nil
            : String(localized: "Traffic statistics need the filter extension. YAS is in monitor-only mode: it sees connections, not bytes.")
        let bytesIn = series.reduce(UInt64(0)) { $0 &+ $1.bytesIn }
        let bytesOut = series.reduce(UInt64(0)) { $0 &+ $1.bytesOut }
        totalsLabel.stringValue = "↓ \(ByteCountFormatter.string(for: bytesIn))   ↑ \(ByteCountFormatter.string(for: bytesOut))"
        updateFilterLabel()
    }

    private func updateFilterLabel() {
        let selected = rows.first { $0.id == selectedAppID }
        filterLabel.stringValue = selected?.name ?? String(localized: "All apps")
        clearFilterButton.isHidden = selected == nil
    }
}

extension TrafficPageController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
        let item = rows[row]
        let content: NSView
        switch column {
        case .app:
            let icon = NSImageView(image: AppIconService.shared.icon(forExecutablePath: item.executablePath))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let stack = NSStackView(views: [icon, NSTextField.label(item.name, size: 13, weight: .medium)])
            stack.spacing = 7
            content = stack
        case .received:
            content = numberLabel(ByteCountFormatter.string(for: item.bytesIn), color: Theme.received)
        case .sent:
            content = numberLabel(ByteCountFormatter.string(for: item.bytesOut), color: Theme.sent)
        case .total:
            content = numberLabel(ByteCountFormatter.string(for: item.total), color: .labelColor)
        case .connections:
            content = numberLabel(item.connections.formatted(), color: .secondaryLabelColor)
        case .share:
            content = ShareBarView(share: item.share)
        }
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        let isNumeric = column != .app && column != .share
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            isNumeric
                ? content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6)
                : content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            column == .share
                ? content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)
                : content.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -12),
        ])
        return cell
    }

    private func numberLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField.label(text, size: 12, color: color)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.alignment = .right
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloadingTable else { return }
        let row = tableView.selectedRow
        let newSelection = rows.indices.contains(row) ? rows[row].id : nil
        guard newSelection != selectedAppID else { return }
        selectedAppID = newSelection
        updateFilterLabel()
        reload()
    }
}

/// Horizontal share bar with a percentage.
private final class ShareBarView: NSView {
    private let share: Double
    private let label = NSTextField.label(size: 11, color: .secondaryLabelColor)

    init(share: Double) {
        self.share = min(max(share, 0), 1)
        super.init(frame: .zero)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.stringValue = self.share.formatted(.percent.precision(.fractionLength(0...1)))
        label.alignment = .right
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 44),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityValue(label.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 3, width: max(0, bounds.width - 50), height: 6)
        NSColor(white: 1, alpha: 0.1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        var fill = track
        fill.size.width = max(share > 0 ? 3 : 0, track.width * share)
        Theme.received.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}
