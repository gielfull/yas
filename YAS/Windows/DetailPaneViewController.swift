import AppKit
import YASShared

/// Right side of the main window: hosts one page at a time under a shared top bar
/// (page title, "Showing: App ✕" chip, page controls, Open in New Window, mode pill).
/// The mode pill lives here, not on a page, so the mode is reachable from every page.
@MainActor
final class DetailPaneViewController: NSViewController {
    /// Top bar height; pages other than the full-bleed map start below it.
    static let barHeight: CGFloat = 58

    private let store: Store
    private let makePage: (DetailPageKind) -> DetailPage
    private var pages: [DetailPageKind: DetailPage] = [:]
    private(set) var currentKind: DetailPageKind?
    private var appFilter: AppHistoryFilter?

    /// The chip's ✕ (and the pages' own "show all" buttons): the list deselects.
    var onClearAppFilter: (() -> Void)?
    var onDetach: ((DetailPageKind) -> Void)?
    /// Whether the pane itself is visible (collapsed panes suspend the map).
    var isPaneVisible = true {
        didSet {
            guard isPaneVisible != oldValue else { return }
            if isPaneVisible { attachContent() } else { content.removeFromSuperview() }
            updateMapSuspension()
        }
    }

    private let pageHost = NSView()
    private let titleLabel = NSTextField.label(size: 15, weight: .bold, color: .white)
    private let chip = FilterChipView()
    private let accessoryHost = NSView()
    private let detachBackground = FloatingControlView(cornerRadius: 17)
    private let modePill = ModePillView()
    private var pageTop: NSLayoutConstraint?

    init(store: Store, makePage: @escaping (DetailPageKind) -> DetailPage) {
        self.store = store
        self.makePage = makePage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = PaneBackgroundView()

        titleLabel.lineBreakMode = .byTruncatingTail
        // The title outlasts the chip when the bar runs out of room; both stay below the
        // split holding priorities so the bar never pushes the pane wider.
        titleLabel.setContentCompressionResistancePriority(.init(245), for: .horizontal)
        chip.setContentCompressionResistancePriority(.init(230), for: .horizontal)
        chip.clearButton.target = self
        chip.clearButton.action = #selector(clearAppFilter(_:))
        chip.isHidden = true

        let detachButton = MapIconButton(
            symbol: "macwindow.badge.plus", pointSize: 14, toolTip: "",
            target: self, action: #selector(detachCurrentPage(_:)))
        detachBackground.addSubview(detachButton)
        self.detachButton = detachButton

        modePill.onSelect = { [weak self] mode in self?.store.setMode(mode) }
        modePill.update(mode: store.mode)

        pageHost.clipsToBounds = true
        // A stack view drops the hidden chip from layout; a hidden plain subview would still take its width.
        let titleStack = NSStackView(views: [titleLabel, chip])
        titleStack.spacing = 10
        titleStack.setClippingResistancePriority(.init(230), for: .horizontal)
        for view in [pageHost, titleStack, accessoryHost, detachBackground, modePill] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let pageTop = pageHost.topAnchor.constraint(equalTo: content.topAnchor)
        self.pageTop = pageTop
        NSLayoutConstraint.activate([
            pageTop,
            pageHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            modePill.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            modePill.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            detachBackground.centerYAnchor.constraint(equalTo: modePill.centerYAnchor),
            detachBackground.trailingAnchor.constraint(equalTo: modePill.leadingAnchor, constant: -10),
            detachBackground.widthAnchor.constraint(equalToConstant: 34),
            detachBackground.heightAnchor.constraint(equalToConstant: 34),
            detachButton.centerXAnchor.constraint(equalTo: detachBackground.centerXAnchor),
            detachButton.centerYAnchor.constraint(equalTo: detachBackground.centerYAnchor),

            accessoryHost.centerYAnchor.constraint(equalTo: modePill.centerYAnchor),
            accessoryHost.trailingAnchor.constraint(equalTo: detachBackground.leadingAnchor, constant: -10),

            titleStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            titleStack.centerYAnchor.constraint(equalTo: modePill.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: accessoryHost.leadingAnchor, constant: -10),
        ])
        view = root
        attachContent()
    }

    private var detachButton: MapIconButton?

    /// Everything in the pane. Detached while the pane is collapsed or animating, so
    /// the bar's and the page's minimum widths never hold the window open.
    private let content = NSView()

    private func attachContent() {
        guard content.superview == nil else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(modeChanged), name: Store.modeDidChange, object: store)
        center.addObserver(self, selector: #selector(sourceChanged), name: Store.sourceDidChange, object: store)
        updateChrome()
    }

    // MARK: - Pages

    /// The page instance hosted in this pane (created on first use).
    func page(_ kind: DetailPageKind) -> DetailPage {
        if let page = pages[kind] { return page }
        let page = makePage(kind)
        if kind.followsListSelection { page.setAppFilter(appFilter) }
        if let history = page as? HistoryPageController {
            history.onClearAppFilter = { [weak self] in self?.onClearAppFilter?() }
        } else if let traffic = page as? TrafficPageController {
            traffic.onClearAppFilter = { [weak self] in self?.onClearAppFilter?() }
        }
        pages[kind] = page
        return page
    }

    /// The page if it was created already (the map needs app updates only if it exists).
    func loadedPage(_ kind: DetailPageKind) -> DetailPage? { pages[kind] }

    func show(_ kind: DetailPageKind) {
        _ = view
        guard kind != currentKind else { return }
        if let currentKind, let old = pages[currentKind] {
            old.view.removeFromSuperview()
            old.removeFromParent()
            old.toolbarAccessory?.removeFromSuperview()
        }
        currentKind = kind
        let page = page(kind)
        addChild(page)
        page.view.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(page.view)
        // Pages must compress to the pane's minimum width (360): the pane width is the
        // split's decision, never the page's.
        NSLayoutConstraint.activate([
            page.view.topAnchor.constraint(equalTo: pageHost.topAnchor),
            page.view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            page.view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
        ])
        if let accessory = page.toolbarAccessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessoryHost.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.topAnchor.constraint(equalTo: accessoryHost.topAnchor),
                accessory.bottomAnchor.constraint(equalTo: accessoryHost.bottomAnchor),
                accessory.leadingAnchor.constraint(equalTo: accessoryHost.leadingAnchor),
                accessory.trailingAnchor.constraint(equalTo: accessoryHost.trailingAnchor),
            ])
        }
        updateChrome()
        updateMapSuspension()
    }

    /// The app selected in the list; forwarded to the pages that follow it.
    func setAppFilter(_ filter: AppHistoryFilter?) {
        guard filter != appFilter else { return }
        appFilter = filter
        for (kind, page) in pages where kind.followsListSelection {
            page.setAppFilter(filter)
        }
        updateChrome()
    }

    private func updateMapSuspension() {
        guard let map = pages[.map] as? MapViewController else { return }
        map.isSuspended = !(isPaneVisible && currentKind == .map)
    }

    // MARK: - Chrome

    private func updateChrome() {
        guard isViewLoaded, let kind = currentKind else { return }
        let isMap = kind == .map
        titleLabel.stringValue = kind.title
        titleLabel.isHidden = isMap
        if let filter = appFilter, kind.followsListSelection {
            chip.configure(name: filter.name)
            chip.isHidden = false
        } else {
            chip.isHidden = true
        }
        let detachTitle = String(localized: "Open \(kind.title) in New Window")
        detachButton?.toolTip = detachTitle + " (⌥⌘\(kind.keyEquivalent))"
        detachButton?.setAccessibilityLabel(detachTitle)
        modePill.isEnforcing = store.isEnforcing
        // The map runs under the bar; other pages start below it.
        pageTop?.constant = isMap ? 0 : Self.barHeight
        (view as? PaneBackgroundView)?.showsBar = !isMap
    }

    @objc private func modeChanged() {
        modePill.update(mode: store.mode)
    }

    @objc private func sourceChanged() {
        updateChrome()
    }

    @objc private func clearAppFilter(_ sender: Any?) {
        onClearAppFilter?()
    }

    @objc private func detachCurrentPage(_ sender: Any?) {
        guard let currentKind else { return }
        onDetach?(currentKind)
    }
}

/// Window-background fill with a hairline under the top bar (hidden behind the map).
private final class PaneBackgroundView: NSView {
    var showsBar = true {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard showsBar else { return }
        Theme.separator.setFill()
        NSRect(x: 0, y: DetailPaneViewController.barHeight - 1, width: bounds.width, height: 1).fill()
    }
}

/// "Showing: Google Chrome ✕" — the list selection the pages are narrowed to.
private final class FilterChipView: NSView {
    let clearButton = NSButton()
    private let label = NSTextField.label(size: 12, weight: .medium, color: .white)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        clearButton.isBordered = false
        clearButton.image = Theme.symbol("xmark.circle.fill", pointSize: 12, weight: .medium)
        clearButton.contentTintColor = NSColor(white: 1, alpha: 0.6)
        clearButton.toolTip = String(localized: "Show all apps")
        clearButton.setAccessibilityLabel(String(localized: "Show all apps"))
        for view in [label, clearButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(name: String) {
        label.stringValue = String(localized: "Showing: \(name)")
        setAccessibilityLabel(label.stringValue)
    }
}
