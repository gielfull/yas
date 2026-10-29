import AppKit

/// The rounded filter bar: magnifier, text field, clear button, divider and the
/// time window button ("5m" with a clock).
final class SearchBarView: NSView {
    let textField = NSTextField()
    let clearButton = NSButton()
    let timeButton = NSButton()

    private let magnifier = NSImageView()
    private let divider = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.03).cgColor

        magnifier.image = Theme.symbol("magnifyingglass", pointSize: 13, weight: .medium)
        magnifier.contentTintColor = NSColor(white: 1, alpha: 0.6)

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 14)
        textField.textColor = .white
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.cell?.isScrollable = true
        textField.placeholderAttributedString = NSAttributedString(
            string: String(localized: "Filter processes, domains (⌘F)"),
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.55), .font: NSFont.systemFont(ofSize: 14)])

        clearButton.isBordered = false
        clearButton.image = Theme.symbol("xmark.circle.fill", pointSize: 13, weight: .medium)
        clearButton.contentTintColor = NSColor(white: 1, alpha: 0.6)
        clearButton.toolTip = String(localized: "Clear filter")
        clearButton.setAccessibilityLabel(String(localized: "Clear filter"))

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor

        timeButton.isBordered = false
        timeButton.image = Theme.symbol("clock", pointSize: 12, weight: .medium)
        timeButton.imagePosition = .imageLeading
        timeButton.imageHugsTitle = true
        timeButton.contentTintColor = NSColor(white: 1, alpha: 0.75)
        timeButton.toolTip = String(localized: "Time window")
        timeButton.setAccessibilityLabel(String(localized: "Time window"))
        textField.setAccessibilityLabel(String(localized: "Filter processes, domains"))

        for view in [magnifier, textField, clearButton, divider, timeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        timeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeButton.setContentHuggingPriority(.required, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            magnifier.centerYAnchor.constraint(equalTo: centerYAnchor),

            textField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 7),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),

            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -10),
            clearButton.widthAnchor.constraint(equalToConstant: 18),

            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            divider.trailingAnchor.constraint(equalTo: timeButton.leadingAnchor, constant: -12),

            timeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTimeTitle(_ title: String) {
        timeButton.attributedTitle = NSAttributedString(
            string: " \(title)",
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.85), .font: NSFont.systemFont(ofSize: 14, weight: .medium)])
    }
}
