import AppKit
import YASShared

/// Split capsule button: "Disconnect" (until undone) plus a chevron menu with timed
/// options; or a single neutral "Reconnect".
final class DisconnectControl: NSView {
    var onDisconnect: ((DisconnectDuration) -> Void)?
    var onReconnect: (() -> Void)?

    private let mainButton = NSButton()
    private let chevronButton = NSButton()
    private let divider = NSView()
    private var isReconnect = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        for button in [mainButton, chevronButton] {
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            addSubview(button)
        }
        mainButton.action = #selector(mainClicked(_:))
        chevronButton.action = #selector(chevronClicked(_:))
        chevronButton.image = Theme.symbol("chevron.down", pointSize: 8, weight: .bold)
        chevronButton.setAccessibilityLabel(String(localized: "Disconnect for a while"))
        chevronButton.toolTip = String(localized: "Disconnect for a while")
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            mainButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            mainButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: mainButton.trailingAnchor, constant: 6),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            chevronButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 3),
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 14),
            chevronButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(reconnect: Bool, toolTip: String) {
        isReconnect = reconnect
        let tint = reconnect ? NSColor(white: 1, alpha: 0.85) : Theme.blockedRed
        mainButton.attributedTitle = NSAttributedString(
            string: reconnect ? String(localized: "Reconnect") : String(localized: "Disconnect"),
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: tint])
        mainButton.toolTip = toolTip
        chevronButton.contentTintColor = tint
        chevronButton.isHidden = reconnect
        divider.isHidden = reconnect
        divider.layer?.backgroundColor = tint.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = (reconnect ? NSColor(white: 1, alpha: 0.1) : Theme.blockedRed.withAlphaComponent(0.16)).cgColor
        layer?.borderColor = (reconnect ? NSColor(white: 1, alpha: 0.2) : Theme.blockedRed.withAlphaComponent(0.4)).cgColor
    }


    @objc private func mainClicked(_ sender: Any?) {
        if isReconnect { onReconnect?() } else { onDisconnect?(.untilUndone) }
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        let menu = NSMenu()
        for duration in DisconnectDuration.allCases where duration != .untilUndone {
            let item = NSMenuItem(title: duration.menuTitle, action: #selector(timedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DurationBox(duration)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let permanent = NSMenuItem(title: String(localized: "Disconnect Until Undone"), action: #selector(timedChosen(_:)), keyEquivalent: "")
        permanent.target = self
        permanent.representedObject = DurationBox(.untilUndone)
        menu.addItem(permanent)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func timedChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DurationBox else { return }
        onDisconnect?(box.duration)
    }
}

/// Lets a duration ride in `NSMenuItem.representedObject`.
final class DurationBox: NSObject {
    let duration: DisconnectDuration
    init(_ duration: DisconnectDuration) { self.duration = duration }
}

/// What an app or process row shows (built by the list controller).
struct ActionRowModel {
    let name: String
    let icon: NSImage
    let toolTip: String
    let status: RowStatus
    let bytes: (inbound: UInt64, outbound: UInt64)
    let destinationCount: Int
    let disconnect: DisconnectStatus?
    let controlToolTip: String
}

/// App and process rows: icon, name, status, and a Disconnect control that appears
/// on hover (or while the row is selected) in place of the status.
final class AppCellView: NSTableCellView {
    enum Style {
        case app
        case process

        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier(self == .app ? "AppCell" : "ProcessCell")
        }
    }

    static let rowHeight: CGFloat = 50
    static let processRowHeight: CGFloat = 34

    var onDisconnect: ((DisconnectDuration) -> Void)?
    var onReconnect: (() -> Void)?

    private let iconView = NSImageView()
    private let nameLabel: NSTextField
    private let statusDot = NSView()
    private let statusLabel = NSTextField.label(size: 11, weight: .medium, color: NSColor(white: 1, alpha: 0.6))
    private let bytesLabel = NSTextField.label(size: 10.5, color: NSColor(white: 1, alpha: 0.38))
    private let separator = NSView()
    private let control = DisconnectControl()
    private var isHovered = false
    private var isRowSelected = false
    private var isDisconnected = false

    init(style: Style) {
        nameLabel = NSTextField.label(size: style == .app ? 15 : 13, weight: style == .app ? .medium : .regular, color: .white)
        super.init(frame: .zero)
        identifier = style.identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = style == .app ? 4.5 : 3.5
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.separator.cgColor
        separator.isHidden = style == .process
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bytesLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        bytesLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        control.isHidden = true
        control.onDisconnect = { [weak self] duration in self?.onDisconnect?(duration) }
        control.onReconnect = { [weak self] in self?.onReconnect?() }

        for view in [iconView, nameLabel, bytesLabel, statusDot, statusLabel, separator, control] { addSubview(view) }
        imageView = iconView
        textField = nameLabel

        let iconSize: CGFloat = style == .app ? 28 : 18
        let dotSize: CGFloat = style == .app ? 9 : 7
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: style == .app ? 12 : 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: bytesLabel.leadingAnchor, constant: -10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -10),

            bytesLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            bytesLabel.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -12),

            statusDot.widthAnchor.constraint(equalToConstant: dotSize),
            statusDot.heightAnchor.constraint(equalToConstant: dotSize),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -7),

            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            separator.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        // One tracking area for the cell's lifetime; .inVisibleRect follows resizes and
        // reuse, so refreshes don't reset it.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with model: ActionRowModel) {
        iconView.image = model.icon
        iconView.alphaValue = model.status.dimsIcon ? 0.45 : 1
        nameLabel.stringValue = model.name
        nameLabel.toolTip = model.toolTip

        let color: NSColor = switch model.status.tone {
        case .active: Theme.activeGreen
        case .idle: Theme.idleGrey
        case .blocked: Theme.blockedRed
        case .wouldBlock: Theme.pendingOrange
        }
        let emphasized = model.status.tone == .blocked || model.status.tone == .wouldBlock
        nameLabel.textColor = emphasized ? color : .white
        statusDot.layer?.backgroundColor = color.cgColor
        statusLabel.stringValue = model.status.text
        statusLabel.textColor = emphasized ? color : NSColor(white: 1, alpha: 0.6)
        if model.bytes.inbound > 0 || model.bytes.outbound > 0 {
            bytesLabel.stringValue = "↓\(ByteCountFormatter.string(for: model.bytes.inbound)) ↑\(ByteCountFormatter.string(for: model.bytes.outbound))"
            bytesLabel.toolTip = String(
                format: String(localized: "%@ received, %@ sent"),
                ByteCountFormatter.string(for: model.bytes.inbound), ByteCountFormatter.string(for: model.bytes.outbound))
        } else {
            bytesLabel.stringValue = ""
            bytesLabel.toolTip = nil
        }

        isDisconnected = model.disconnect != nil
        control.configure(reconnect: isDisconnected, toolTip: model.controlToolTip)

        // VoiceOver: one sentence per row, plus the same actions as the button.
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(String(localized: "\(model.name), \(model.status.text), \(model.destinationCount) destinations"))
        setAccessibilityCustomActions(accessibilityActions())

        // Refreshes reuse cells: re-derive hover from where the mouse is now.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = bounds.contains(point)
        }
        updateControlVisibility()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateControlVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateControlVisibility()
    }

    /// Called by `ListRowView` when selection changes: the control also shows for the
    /// selected row, so it's reachable without a mouse.
    func setRowSelected(_ selected: Bool) {
        isRowSelected = selected
        updateControlVisibility()
    }

    private func updateControlVisibility() {
        let show = isHovered || isRowSelected
        control.isHidden = !show
        statusLabel.isHidden = show
        statusDot.isHidden = show
        bytesLabel.isHidden = show
    }

    // MARK: - Accessibility actions

    private func accessibilityActions() -> [NSAccessibilityCustomAction] {
        if isDisconnected {
            return [NSAccessibilityCustomAction(name: String(localized: "Reconnect"), target: self, selector: #selector(accessibilityReconnect))]
        }
        return [
            NSAccessibilityCustomAction(name: DisconnectDuration.untilUndone.menuTitle, target: self, selector: #selector(accessibilityDisconnect)),
            NSAccessibilityCustomAction(name: DisconnectDuration.fiveMinutes.menuTitle, target: self, selector: #selector(accessibilityDisconnect5)),
            NSAccessibilityCustomAction(name: DisconnectDuration.fifteenMinutes.menuTitle, target: self, selector: #selector(accessibilityDisconnect15)),
            NSAccessibilityCustomAction(name: DisconnectDuration.oneHour.menuTitle, target: self, selector: #selector(accessibilityDisconnect60)),
            NSAccessibilityCustomAction(name: DisconnectDuration.untilTomorrow.menuTitle, target: self, selector: #selector(accessibilityDisconnectTomorrow)),
        ]
    }

    @objc private func accessibilityDisconnect() -> Bool { onDisconnect?(.untilUndone); return true }
    @objc private func accessibilityDisconnect5() -> Bool { onDisconnect?(.fiveMinutes); return true }
    @objc private func accessibilityDisconnect15() -> Bool { onDisconnect?(.fifteenMinutes); return true }
    @objc private func accessibilityDisconnect60() -> Bool { onDisconnect?(.oneHour); return true }
    @objc private func accessibilityDisconnectTomorrow() -> Bool { onDisconnect?(.untilTomorrow); return true }
    @objc private func accessibilityReconnect() -> Bool { onReconnect?(); return true }
}

/// Destination row: flag + country, host (or IP), port, count and verdict.
final class DestinationCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("DestinationCell")
    static let rowHeight: CGFloat = 28

    private let countryLabel = NSTextField.label(size: 11, weight: .medium, color: NSColor(white: 1, alpha: 0.55))
    /// Green dot while a connection to this destination is open.
    private let liveDot = NSView()
    private let hostLabel = NSTextField.label(size: 12.5, color: NSColor(white: 1, alpha: 0.88))
    private let detailLabel = NSTextField.label(size: 11, color: NSColor(white: 1, alpha: 0.5))
    private let verdictView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.maximumNumberOfLines = 1
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.alignment = .right
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        verdictView.translatesAutoresizingMaskIntoConstraints = false
        textField = hostLabel

        liveDot.translatesAutoresizingMaskIntoConstraints = false
        liveDot.wantsLayer = true
        liveDot.layer?.cornerRadius = 3
        liveDot.layer?.backgroundColor = Theme.activeGreen.cgColor

        for view in [liveDot, countryLabel, hostLabel, detailLabel, verdictView] { addSubview(view) }
        NSLayoutConstraint.activate([
            liveDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            liveDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            liveDot.widthAnchor.constraint(equalToConstant: 6),
            liveDot.heightAnchor.constraint(equalToConstant: 6),

            countryLabel.leadingAnchor.constraint(equalTo: liveDot.trailingAnchor, constant: 6),
            countryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countryLabel.widthAnchor.constraint(equalToConstant: 40),

            hostLabel.leadingAnchor.constraint(equalTo: countryLabel.trailingAnchor, constant: 4),
            hostLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),

            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: verdictView.leadingAnchor, constant: -8),

            verdictView.centerYAnchor.constraint(equalTo: centerYAnchor),
            verdictView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            verdictView.widthAnchor.constraint(equalToConstant: 14),
            verdictView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with destination: DestinationSummary, enforcing: Bool = true, hasByteCounts: Bool = true) {
        if let code = destination.countryCode {
            countryLabel.stringValue = "\(CountryCentroids.flag(for: code)) \(code)"
            countryLabel.toolTip = CountryCentroids.name(for: code)
        } else {
            countryLabel.stringValue = "🌐 ––"
            countryLabel.toolTip = String(localized: "Unknown country")
        }
        liveDot.isHidden = !destination.isLive
        liveDot.toolTip = destination.isLive ? String(localized: "Connection open now") : nil
        let baseAlpha: CGFloat = destination.isLive ? 0.9 : 0.62
        let hostColor: NSColor
        if destination.wouldBlock {
            hostColor = Theme.pendingOrange
        } else if destination.lastVerdict == .blocked {
            hostColor = Theme.blockedRed
        } else {
            // Reverse DNS names are a guess about the server, so they're dimmer.
            hostColor = NSColor(white: 1, alpha: destination.hostIsReverseDNS ? baseAlpha * 0.65 : baseAlpha)
        }
        // Attributed text replaces the label's line-break mode, so restate it: one line, truncated in the middle.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        var hostAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: hostColor, .font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: paragraph,
        ]
        if destination.wouldBlock {
            hostAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            hostAttributes[.strikethroughColor] = Theme.pendingOrange
        }
        hostLabel.attributedStringValue = NSAttributedString(string: destination.displayHost, attributes: hostAttributes)
        detailLabel.stringValue = "\(destination.proto == .udp ? "udp " : ""):\(destination.port)  ×\(destination.count)"

        // Only states that set a row apart get an icon: plain allowed (or merely observed, in
        // monitor mode) traffic shows nothing. The column keeps its width so counts stay aligned.
        if destination.wouldBlock {
            verdictView.image = Theme.symbol("hand.raised.fill", pointSize: 11, weight: .semibold)
            verdictView.contentTintColor = Theme.pendingOrange
            verdictView.toolTip = String(localized: "A rule would block this. Blocking requires the filter extension.")
        } else if !enforcing || destination.lastVerdict == .allowed {
            verdictView.image = nil
            verdictView.toolTip = nil
        } else {
            verdictView.image = Theme.symbol(destination.lastVerdict.symbolName, pointSize: 11, weight: .semibold)
            verdictView.contentTintColor = destination.lastVerdict.tint
            verdictView.toolTip = destination.lastVerdict.title
        }
        let country = destination.countryCode.map { CountryCentroids.name(for: $0) } ?? String(localized: "Unknown country")
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(String(
            localized: "\(destination.displayHost), \(country), port \(destination.port), connections: \(destination.count), \(destination.lastVerdict.title)"))

        let bytes = String(
            format: String(localized: "%@ received, %@ sent"),
            ByteCountFormatter.string(for: destination.bytesIn),
            ByteCountFormatter.string(for: destination.bytesOut))
        var lines = ["\(destination.displayHost)\n\(destination.ip) · \(destination.proto.rawValue.uppercased()) \(destination.port)"]
        if destination.hostIsReverseDNS { lines.append(String(localized: "Name from reverse DNS")) }
        lines.append(hasByteCounts ? bytes : String(localized: "Byte counts need the filter extension."))
        if destination.wouldBlock { lines.append(String(localized: "A rule would block this. Blocking requires the filter extension.")) }
        toolTip = lines.joined(separator: "\n")
    }
}

/// Row view with a soft rounded selection instead of the accent-colored bar.
final class ListRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for case let cell as AppCellView in subviews { cell.setRowSelected(isSelected) }
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? AppCellView)?.setRowSelected(isSelected)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        NSColor(white: 1, alpha: isEmphasized ? 0.10 : 0.07).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
