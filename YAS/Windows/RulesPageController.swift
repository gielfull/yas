import AppKit
import YASShared
import UniformTypeIdentifiers

/// Rules that concern one app (its app and app+domain rules); nil = all rules. Pure, tested.
enum RulesPageFilter {
    static func rules(_ all: [Rule], for filter: AppHistoryFilter?) -> [Rule] {
        guard let filter else { return all }
        let keys = Set(filter.identities.map(\.matchKey))
        return all.filter { rule in
            switch rule.target {
            case .app(let identity), .appDomain(let identity, _): keys.contains(identity.matchKey)
            case .domain: false
            }
        }
    }
}

/// Rules page: enable toggle, delete, add sheet, JSON import/export. Lives in the
/// detail pane or a detached window; follows the app selected in the main list.
@MainActor
final class RulesPageController: NSViewController, DetailPage {
    let pageKind = DetailPageKind.rules
    private var appFilter: AppHistoryFilter?
    /// Sheets and panels attach to whichever window hosts the page.
    private var window: NSWindow? { isViewLoaded ? view.window : nil }
    private enum Column: String, CaseIterable {
        case enabled, action, kind, target, expires, note, created
    }

    private let store: Store
    private let tableView = NSTableView()
    private let removeButton = NSButton()
    private let countLabel = NSTextField.label(size: 11, color: .secondaryLabelColor)
    private var rules: [Rule] = []
    private var addSheet: AddRuleSheetController?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: Store.rulesDidChange, object: store)
    }

    override func loadView() {
        view = makeContent()
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Narrow pane: drop the least important columns first.
        let width = view.bounds.width
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.created.rawValue))?.isHidden = width < 720
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(Column.note.rawValue))?.isHidden = width < 560
    }

    /// Shows only the rules for the app selected in the main list (nil = all).
    func setAppFilter(_ filter: AppHistoryFilter?) {
        guard filter != appFilter else { return }
        appFilter = filter
        if isViewLoaded { reload() }
    }

    var visibleRulesForTesting: [Rule] { RulesPageFilter.rules(store.rules, for: appFilter) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeContent() -> NSView {
        let titles: [Column: String] = [
            .enabled: String(localized: "On"),
            .action: String(localized: "Action"),
            .kind: String(localized: "Type"),
            .target: String(localized: "Target"),
            .expires: String(localized: "Expires"),
            .note: String(localized: "Note"),
            .created: String(localized: "Created"),
        ]
        let widths: [Column: CGFloat] = [.enabled: 34, .action: 60, .kind: 70, .target: 240, .expires: 110, .note: 150, .created: 120]
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = titles[column] ?? ""
            tableColumn.width = widths[column] ?? 100
            tableColumn.minWidth = column == .enabled ? 34 : 60
            if column == .enabled { tableColumn.maxWidth = 40 }
            tableView.addTableColumn(tableColumn)
        }
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(String(localized: "Rules"))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(addRule(_:)))
        addButton.toolTip = String(localized: "Add rule")
        addButton.setAccessibilityLabel(String(localized: "Add rule"))
        removeButton.image = NSImage(named: NSImage.removeTemplateName)
        removeButton.bezelStyle = addButton.bezelStyle
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.toolTip = String(localized: "Delete selected rules")
        removeButton.setAccessibilityLabel(String(localized: "Delete selected rules"))
        let importButton = NSButton(title: String(localized: "Import…"), target: self, action: #selector(importRules(_:)))
        let exportButton = NSButton(title: String(localized: "Export…"), target: self, action: #selector(exportRules(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [addButton, removeButton, countLabel, spacer, importButton, exportButton])
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        return root
    }

    @objc private func reload() {
        let selected = Set(tableView.selectedRowIndexes.compactMap { rules.indices.contains($0) ? rules[$0].id : nil })
        rules = RulesPageFilter.rules(store.rules, for: appFilter)
        tableView.reloadData()
        let rows = IndexSet(rules.enumerated().filter { selected.contains($0.element.id) }.map(\.offset))
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
        countLabel.stringValue = String(localized: "\(rules.count) rules")
    }

    // MARK: - Actions

    @objc private func addRule(_ sender: Any?) {
        guard let window else { return }
        let sheet = AddRuleSheetController(store: store)
        addSheet = sheet
        sheet.onFinish = { [weak self] rule in
            if let rule { self?.store.addRule(rule) }
            self?.addSheet = nil
        }
        window.beginSheet(sheet.sheet)
    }

    @objc private func removeSelected(_ sender: Any?) {
        let ids = Set(tableView.selectedRowIndexes.compactMap { rules.indices.contains($0) ? rules[$0].id : nil })
        store.removeRules(ids: ids)
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard rules.indices.contains(row) else { return }
        store.setRule(rules[row].id, enabled: sender.state == .on)
    }

    @objc private func importRules(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importRules(from: url) }
        }
    }

    private func importRules(from url: URL) {
        do {
            let imported = try PayloadCoder.decode([Rule].self, from: Data(contentsOf: url))
            let added = store.mergeRules(imported)
            let alert = NSAlert()
            alert.messageText = String(localized: "Imported \(added) rules")
            if added < imported.count {
                alert.informativeText = String(localized: "Rules that already exist were skipped.")
            }
            if let window { alert.beginSheetModal(for: window) }
        } catch {
            showError(error)
        }
    }

    @objc private func exportRules(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "YAS Rules") + ".json"
        let data: Data
        do {
            data = try PayloadCoder.encode(store.rules)
        } catch {
            showError(error)
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    self?.showError(error)
                }
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Presentation

    static func kindTitle(_ target: RuleTarget) -> String {
        switch target {
        case .app: String(localized: "App")
        case .domain: String(localized: "Domain")
        case .appDomain: String(localized: "App + Domain")
        }
    }

    static func targetTitle(_ target: RuleTarget) -> String {
        let icons = AppIconService.shared
        switch target {
        case .app(let app):
            // Name the process itself: a rule on "Google Chrome Helper" isn't a rule on Chrome.
            let appName = icons.displayName(forExecutablePath: app.executablePath)
            let processName = AppIconService.processName(forExecutablePath: app.executablePath)
            return processName == appName ? appName : "\(processName) (\(appName))"
        case .domain(let domain, let includeSubdomains):
            return includeSubdomains
                ? String(format: String(localized: "%@ and subdomains"), domain)
                : domain
        case .appDomain(let app, let domain):
            return "\(icons.displayName(forExecutablePath: app.executablePath)) → \(domain)"
        }
    }
}

extension RulesPageController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard rules.indices.contains(row) else { return }
        let rule = rules[row]
        if rule.expiresAt != nil {
            let item = NSMenuItem(title: String(localized: "Remove Expiry"), action: #selector(removeExpiry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rule.id.uuidString
            menu.addItem(item)
        }
        let delete = NSMenuItem(title: String(localized: "Delete Rule"), action: #selector(deleteClicked(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = rule.id.uuidString
        menu.addItem(delete)
    }

    @objc private func removeExpiry(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) else { return }
        store.setRuleExpiry(id, to: nil)
    }

    @objc private func deleteClicked(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) else { return }
        store.removeRules(ids: [id])
    }
}

extension RulesPageController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
        let rule = rules[row]
        switch column {
        case .enabled:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            checkbox.state = rule.isEnabled ? .on : .off
            checkbox.setAccessibilityLabel(String(localized: "Enabled"))
            return checkbox
        case .action:
            let label = NSTextField.label(
                rule.action == .block ? String(localized: "Block") : String(localized: "Allow"),
                size: 12, weight: .semibold,
                color: rule.action == .block ? Theme.blockedRed : Theme.activeGreen)
            return label
        case .kind:
            return NSTextField.label(Self.kindTitle(rule.target), size: 12, color: .secondaryLabelColor)
        case .target:
            let label = NSTextField.label(Self.targetTitle(rule.target), size: 12)
            if case .app(let app) = rule.target { label.toolTip = app.executablePath }
            if case .appDomain(let app, _) = rule.target { label.toolTip = app.executablePath }
            label.textColor = rule.isEnabled ? .labelColor : .tertiaryLabelColor
            return label
        case .expires:
            guard let expiresAt = rule.expiresAt else {
                return NSTextField.label("—", size: 12, color: .tertiaryLabelColor)
            }
            let time = Calendar.current.isDateInToday(expiresAt)
                ? expiresAt.formatted(date: .omitted, time: .shortened)
                : expiresAt.formatted(date: .abbreviated, time: .shortened)
            let label = NSTextField.label(String(localized: "Until \(time)"), size: 12, color: .systemOrange)
            label.toolTip = String(localized: "Right-click to make this rule permanent.")
            return label
        case .note:
            return NSTextField.label(rule.note ?? "", size: 12, color: .secondaryLabelColor)
        case .created:
            return NSTextField.label(Self.dateFormatter.string(from: rule.createdAt), size: 12, color: .secondaryLabelColor)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }
}

/// Sheet for a new rule: type, app, domain, action.
@MainActor
final class AddRuleSheetController: NSObject {
    let sheet: NSWindow
    var onFinish: ((Rule?) -> Void)?

    private let store: Store
    private let kindPopUp = NSPopUpButton()
    private let appPopUp = NSPopUpButton()
    private let domainField = NSTextField()
    private let subdomainsCheckbox = NSButton(checkboxWithTitle: String(localized: "Include subdomains"), target: nil, action: nil)
    private let actionPopUp = NSPopUpButton()
    private let addButton = NSButton()
    private var appChoices: [AppIdentity] = []
    private var appRow: NSGridRow?
    private var domainRow: NSGridRow?
    private var subdomainsRow: NSGridRow?

    init(store: Store) {
        self.store = store
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        sheet.contentView = makeContent()
        kindChanged(nil)
    }

    private func makeContent() -> NSView {
        kindPopUp.addItems(withTitles: [
            String(localized: "App"), String(localized: "Domain"), String(localized: "App + Domain"),
        ])
        kindPopUp.target = self
        kindPopUp.action = #selector(kindChanged(_:))

        // Known apps (unfiltered), then a chooser.
        var seen = Set<String>()
        for flow in store.flows.reversed() where seen.insert(flow.app.matchKey).inserted {
            appChoices.append(flow.app)
        }
        let icons = AppIconService.shared
        appChoices.sort {
            icons.displayName(forExecutablePath: $0.executablePath)
                .localizedCaseInsensitiveCompare(icons.displayName(forExecutablePath: $1.executablePath)) == .orderedAscending
        }
        rebuildAppMenu(selecting: nil)
        appPopUp.target = self
        appPopUp.action = #selector(appChanged(_:))

        domainField.placeholderString = String(localized: "example.com")
        domainField.delegate = self
        subdomainsCheckbox.state = .on
        actionPopUp.addItems(withTitles: [String(localized: "Block"), String(localized: "Allow")])

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Type:")), kindPopUp],
            [NSTextField(labelWithString: String(localized: "App:")), appPopUp],
            [NSTextField(labelWithString: String(localized: "Domain:")), domainField],
            [NSGridCell.emptyContentView, subdomainsCheckbox],
            [NSTextField(labelWithString: String(localized: "Action:")), actionPopUp],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        appRow = grid.row(at: 1)
        domainRow = grid.row(at: 2)
        subdomainsRow = grid.row(at: 3)
        domainField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        appPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        addButton.title = String(localized: "Add Rule")
        addButton.bezelStyle = .push
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(add(_:))
        let buttons = NSStackView(views: [cancel, addButton])

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return stack
    }

    private func rebuildAppMenu(selecting identity: AppIdentity?) {
        appPopUp.removeAllItems()
        let icons = AppIconService.shared
        for app in appChoices {
            let item = NSMenuItem(title: icons.displayName(forExecutablePath: app.executablePath), action: nil, keyEquivalent: "")
            let icon = icons.icon(forExecutablePath: app.executablePath).copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = app.executablePath
            appPopUp.menu?.addItem(item)
        }
        if !appChoices.isEmpty { appPopUp.menu?.addItem(.separator()) }
        appPopUp.menu?.addItem(NSMenuItem(title: String(localized: "Choose Application…"), action: nil, keyEquivalent: ""))
        if let identity, let index = appChoices.firstIndex(of: identity) {
            appPopUp.selectItem(at: index)
        }
    }

    private var selectedApp: AppIdentity? {
        let index = appPopUp.indexOfSelectedItem
        return appChoices.indices.contains(index) ? appChoices[index] : nil
    }

    @objc private func kindChanged(_ sender: Any?) {
        let kind = kindPopUp.indexOfSelectedItem
        appRow?.isHidden = kind == 1
        domainRow?.isHidden = kind == 0
        subdomainsRow?.isHidden = kind != 1
        validate()
    }

    @objc private func appChanged(_ sender: Any?) {
        guard appPopUp.indexOfSelectedItem == appPopUp.numberOfItems - 1 else {
            validate()
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: sheet) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK, let url = panel.url, let identity = CodeSignature.identity(forAppAt: url) {
                    if !self.appChoices.contains(identity) { self.appChoices.insert(identity, at: 0) }
                    self.rebuildAppMenu(selecting: identity)
                } else {
                    self.appPopUp.selectItem(at: 0)
                }
                self.validate()
            }
        }
    }

    private func validate() {
        let kind = kindPopUp.indexOfSelectedItem
        let hasDomain = !DomainMatcher.normalize(domainField.stringValue).isEmpty
        switch kind {
        case 0: addButton.isEnabled = selectedApp != nil
        case 1: addButton.isEnabled = hasDomain
        default: addButton.isEnabled = selectedApp != nil && hasDomain
        }
    }

    @objc private func add(_ sender: Any?) {
        let action: RuleAction = actionPopUp.indexOfSelectedItem == 0 ? .block : .allow
        let domain = DomainMatcher.normalize(domainField.stringValue)
        let target: RuleTarget
        switch kindPopUp.indexOfSelectedItem {
        case 0:
            guard let app = selectedApp else { return }
            target = .app(app)
        case 1:
            guard !domain.isEmpty else { return }
            target = .domain(domain, includeSubdomains: subdomainsCheckbox.state == .on)
        default:
            guard let app = selectedApp, !domain.isEmpty else { return }
            target = .appDomain(app, domain)
        }
        finish(Rule(target: target, action: action))
    }

    @objc private func cancel(_ sender: Any?) {
        finish(nil)
    }

    private func finish(_ rule: Rule?) {
        sheet.sheetParent?.endSheet(sheet)
        onFinish?(rule)
    }
}

extension AddRuleSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        validate()
    }
}
