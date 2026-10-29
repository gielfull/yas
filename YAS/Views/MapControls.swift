import AppKit
import YASShared

/// Dark translucent rounded container for the floating map controls.
class FloatingControlView: NSVisualEffectView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.controlBorder.cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Borderless symbol button used inside the floating controls.
final class MapIconButton: NSButton {
    init(symbol: String, pointSize: CGFloat = 15, toolTip: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        image = Theme.symbol(symbol, pointSize: pointSize, weight: .semibold)
        imagePosition = .imageOnly
        contentTintColor = .white
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSymbol(_ name: String, pointSize: CGFloat = 15) {
        image = Theme.symbol(name, pointSize: pointSize, weight: .semibold)
    }
}

/// Image view that lets clicks fall through to the control underneath.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The mode pill: a pull-down `NSPopUpButton` over a capsule tinted by the mode.
final class ModePillView: NSView {
    let popUpButton = NSPopUpButton(frame: .zero, pullsDown: true)
    var onSelect: ((FilterMode) -> Void)?
    /// Monitor-only: the mode is saved but not enforced. Said in the menu and tooltip rather
    /// than a permanent label under the pill.
    var isEnforcing = true {
        didSet {
            guard isEnforcing != oldValue else { return }
            buildMenu()
            update(mode: currentMode)
        }
    }
    private var currentMode: FilterMode = .blockList

    private let chevron = PassthroughImageView()
    private let background: FloatingControlView

    init() {
        background = FloatingControlView(cornerRadius: 17)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        popUpButton.isBordered = false
        popUpButton.translatesAutoresizingMaskIntoConstraints = false
        (popUpButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popUpButton.imagePosition = .imageLeading

        chevron.image = Theme.symbol("chevron.down", pointSize: 10, weight: .bold)
        chevron.contentTintColor = NSColor(white: 1, alpha: 0.85)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        addSubview(popUpButton)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            popUpButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            popUpButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            popUpButton.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -2),

            chevron.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
        ])
        buildMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The whole capsule is the hit target: clicks on the chevron or the padding
    /// (which sit outside the popup's frame) would otherwise land on the background.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        return popUpButton.frame.contains(local) ? popUpButton : self
    }

    override func mouseDown(with event: NSEvent) {
        popUpButton.performClick(nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        // Pull-down buttons display item 0 and never list it.
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for mode in FilterMode.menuOrder {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.image = Theme.paletteSymbol(mode.symbolName, pointSize: 13, glyph: .white, fill: mode.tint)
            item.toolTip = mode.summary
            menu.addItem(item)
        }
        if !isEnforcing {
            menu.addItem(.separator())
            let note = NSMenuItem(title: Self.monitorOnlyNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.toolTip = Self.monitorOnlyDetail
            menu.addItem(note)
        }
        popUpButton.menu = menu
    }

    private static let monitorOnlyNote = String(localized: "Modes apply once the filter is active")
    private static let monitorOnlyDetail = String(localized: "YAS is in monitor-only mode. Your mode and rules are saved and take effect when the filter extension is enabled.")

    func update(mode: FilterMode) {
        currentMode = mode
        popUpButton.toolTip = isEnforcing
            ? String(localized: "Filter mode")
            : String(localized: "Filter mode") + "\n" + Self.monitorOnlyNote
        guard let header = popUpButton.menu?.item(at: 0) else { return }
        header.attributedTitle = NSAttributedString(
            string: " \(mode.title)",
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white])
        header.image = Theme.paletteSymbol(mode.symbolName, pointSize: 14, glyph: NSColor(white: 0.08, alpha: 1), fill: mode.tint)
        popUpButton.synchronizeTitleAndSelectedItem()
        for item in popUpButton.itemArray.dropFirst() {
            item.state = (item.representedObject as? String) == mode.rawValue ? .on : .off
        }
        background.layer?.borderColor = mode.tint.withAlphaComponent(0.85).cgColor
        background.layer?.borderWidth = 1.5
        popUpButton.setAccessibilityLabel(String(localized: "Filter mode"))
        popUpButton.setAccessibilityValue(mode.title)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FilterMode(rawValue: raw) else { return }
        onSelect?(mode)
    }
}

/// Vertically stacked + / − buttons.
final class ZoomControlView: FloatingControlView {
    let zoomInButton: MapIconButton
    let zoomOutButton: MapIconButton

    init(target: AnyObject, zoomIn: Selector, zoomOut: Selector) {
        zoomInButton = MapIconButton(symbol: "plus", pointSize: 14, toolTip: String(localized: "Zoom in"), target: target, action: zoomIn)
        zoomOutButton = MapIconButton(symbol: "minus", pointSize: 14, toolTip: String(localized: "Zoom out"), target: target, action: zoomOut)
        super.init(cornerRadius: 9)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        for view in [zoomInButton, zoomOutButton, divider] { addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 72),
            zoomInButton.topAnchor.constraint(equalTo: topAnchor),
            zoomInButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            zoomInButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            zoomInButton.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            zoomOutButton.topAnchor.constraint(equalTo: divider.bottomAnchor),
            zoomOutButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            zoomOutButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            zoomOutButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
