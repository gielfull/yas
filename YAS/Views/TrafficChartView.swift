import AppKit

/// Stacked area chart of received (bottom) and sent (top) bytes per slot, drawn
/// with Core Graphics, with a hover crosshair and tooltip.
final class TrafficChartView: NSView {
    var points: [TrafficPoint] = [] {
        didSet {
            if let hoverIndex, hoverIndex >= points.count { self.hoverIndex = nil }
            needsDisplay = true
        }
    }

    /// Replaces the chart with an explanation (e.g. no byte counts in monitor mode).
    var unavailableMessage: String? {
        didSet { needsDisplay = true }
    }

    var step: Int = 60 {
        didSet { needsDisplay = true }
    }

    private var hoverIndex: Int? {
        didSet { if hoverIndex != oldValue { needsDisplay = true } }
    }

    private let insets = NSEdgeInsets(top: 34, left: 70, bottom: 28, right: 18)
    private let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor(white: 1, alpha: 0.5),
    ]

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Traffic chart"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    private var plotRect: NSRect {
        NSRect(
            x: bounds.minX + insets.left, y: bounds.minY + insets.bottom,
            width: max(1, bounds.width - insets.left - insets.right),
            height: max(1, bounds.height - insets.top - insets.bottom))
    }

    private func x(at index: Int) -> CGFloat {
        let plot = plotRect
        guard points.count > 1 else { return plot.midX }
        return plot.minX + plot.width * CGFloat(index) / CGFloat(points.count - 1)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect
        let maximum = points.map { Double($0.bytesIn) + Double($0.bytesOut) }.max() ?? 0
        let axis = ChartScale.axis(forMaximum: maximum)
        func y(_ value: Double) -> CGFloat {
            plot.minY + plot.height * CGFloat(value / axis.upper)
        }

        // Grid + Y labels.
        for tick in axis.ticks {
            let lineY = y(tick).rounded() + 0.5
            NSColor(white: 1, alpha: tick == 0 ? 0.18 : 0.07).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: lineY))
            line.line(to: NSPoint(x: plot.maxX, y: lineY))
            line.lineWidth = 1
            line.stroke()
            let label = NSAttributedString(string: ByteCountFormatter.string(for: UInt64(tick)), attributes: labelAttributes)
            label.draw(at: NSPoint(x: plot.minX - label.size().width - 8, y: lineY - label.size().height / 2))
        }

        drawLegend()

        guard unavailableMessage == nil, !points.isEmpty, maximum > 0 else {
            // Wrapped and centered inside the plot, so narrow panes don't run it over the axis.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let empty = NSAttributedString(
                string: unavailableMessage ?? String(localized: "No traffic in this range"),
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 1, alpha: 0.45),
                             .paragraphStyle: paragraph])
            let width = max(80, plot.width - 40)
            let size = empty.boundingRect(
                with: NSSize(width: width, height: plot.height), options: [.usesLineFragmentOrigin]).size
            empty.draw(with: NSRect(x: plot.midX - width / 2, y: plot.midY - ceil(size.height) / 2,
                                    width: width, height: ceil(size.height)),
                       options: [.usesLineFragmentOrigin])
            drawXLabels(plot: plot)
            return
        }

        // Received from 0, sent stacked on top.
        let received = points.map { Double($0.bytesIn) }
        let stacked = points.map { Double($0.bytesIn) + Double($0.bytesOut) }
        drawArea(top: stacked, bottom: received, color: Theme.sent, y: y)
        drawArea(top: received, bottom: nil, color: Theme.received, y: y)
        drawXLabels(plot: plot)

        if let hoverIndex, points.indices.contains(hoverIndex) {
            drawHover(index: hoverIndex, plot: plot)
        }
    }

    private func drawArea(top: [Double], bottom: [Double]?, color: NSColor, y: (Double) -> CGFloat) {
        let plot = plotRect
        let area = NSBezierPath()
        let edge = NSBezierPath()
        for index in top.indices {
            let point = NSPoint(x: x(at: index), y: y(top[index]))
            if index == 0 {
                area.move(to: point)
                edge.move(to: point)
            } else {
                area.line(to: point)
                edge.line(to: point)
            }
        }
        if let bottom {
            for index in bottom.indices.reversed() {
                area.line(to: NSPoint(x: x(at: index), y: y(bottom[index])))
            }
        } else {
            area.line(to: NSPoint(x: x(at: top.count - 1), y: plot.minY))
            area.line(to: NSPoint(x: x(at: 0), y: plot.minY))
        }
        area.close()
        color.withAlphaComponent(0.32).setFill()
        area.fill()
        color.withAlphaComponent(0.95).setStroke()
        edge.lineWidth = 1.5
        edge.lineJoinStyle = .round
        edge.stroke()
    }

    private func drawLegend() {
        var origin = NSPoint(x: plotRect.minX, y: bounds.maxY - 22)
        for (title, color) in [(String(localized: "Received"), Theme.received), (String(localized: "Sent"), Theme.sent)] {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y + 3, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            let label = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.8),
            ])
            label.draw(at: NSPoint(x: origin.x + 15, y: origin.y + 1))
            origin.x += 15 + label.size().width + 18
        }
        let perSlot = NSAttributedString(
            string: String(format: String(localized: "Bytes per %@"), slotDescription),
            attributes: labelAttributes)
        perSlot.draw(at: NSPoint(x: plotRect.maxX - perSlot.size().width, y: origin.y + 1))
    }

    private var slotDescription: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: TimeInterval(step)) ?? "\(step)s"
    }

    private func drawXLabels(plot: NSRect) {
        guard points.count > 1 else { return }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(step >= 3600 ? "EEE j" : "jmm")
        let labelCount = min(6, points.count)
        for label in 0..<labelCount {
            let index = Int((Double(label) / Double(labelCount - 1) * Double(points.count - 1)).rounded())
            let text = NSAttributedString(string: formatter.string(from: points[index].start), attributes: labelAttributes)
            let size = text.size()
            let centerX = min(max(x(at: index), plot.minX + size.width / 2), plot.maxX - size.width / 2)
            text.draw(at: NSPoint(x: centerX - size.width / 2, y: plot.minY - size.height - 6))
        }
    }

    private func drawHover(index: Int, plot: NSRect) {
        let lineX = x(at: index).rounded() + 0.5
        NSColor(white: 1, alpha: 0.55).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: lineX, y: plot.minY))
        line.line(to: NSPoint(x: lineX, y: plot.maxY))
        line.setLineDash([3, 3], count: 2, phase: 0)
        line.stroke()

        let point = points[index]
        let formatter = DateFormatter()
        formatter.dateStyle = step >= 3600 ? .medium : .none
        formatter.timeStyle = .short
        let end = point.start.addingTimeInterval(TimeInterval(step))
        let lines: [(String, NSColor)] = [
            ("\(formatter.string(from: point.start)) – \(formatter.string(from: end))", NSColor(white: 1, alpha: 0.9)),
            ("↓ " + String(format: String(localized: "Received %@"), ByteCountFormatter.string(for: point.bytesIn)), Theme.received),
            ("↑ " + String(format: String(localized: "Sent %@"), ByteCountFormatter.string(for: point.bytesOut)), Theme.sent),
        ]
        let rendered = lines.map { NSAttributedString(string: $0.0, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: $0.1,
        ]) }
        let width = (rendered.map { $0.size().width }.max() ?? 0) + 20
        let lineHeight: CGFloat = 16
        let height = CGFloat(rendered.count) * lineHeight + 12
        var box = NSRect(x: lineX + 10, y: plot.maxY - height - 4, width: width, height: height)
        if box.maxX > bounds.maxX - 4 { box.origin.x = lineX - 10 - width }
        NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.95).setFill()
        let background = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        background.fill()
        NSColor(white: 1, alpha: 0.15).setStroke()
        background.stroke()
        for (row, text) in rendered.enumerated() {
            text.draw(at: NSPoint(x: box.minX + 10, y: box.maxY - 6 - lineHeight * CGFloat(row + 1) + 2))
        }
    }

    // MARK: - Hover

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard points.count > 0, plotRect.insetBy(dx: -6, dy: 0).contains(location) else {
            hoverIndex = nil
            return
        }
        let fraction = (location.x - plotRect.minX) / plotRect.width
        hoverIndex = min(max(Int((fraction * CGFloat(points.count - 1)).rounded()), 0), points.count - 1)
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
    }
}
