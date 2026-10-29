import AppKit
import YASShared

/// YAS's shield outline in a unit square (y up), shared by the menu bar
/// glyphs. scripts/make-app-icon.swift draws the same shape for the app icon.
enum ShieldGlyph {
    static func path(in rect: CGRect) -> CGPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let path = CGMutablePath()
        path.move(to: point(0.5, 0.97))
        path.addQuadCurve(to: point(0.9, 0.83), control: point(0.7, 0.9))
        path.addLine(to: point(0.9, 0.52))
        path.addQuadCurve(to: point(0.5, 0.03), control: point(0.88, 0.17))
        path.addQuadCurve(to: point(0.1, 0.52), control: point(0.12, 0.17))
        path.addLine(to: point(0.1, 0.83))
        path.addQuadCurve(to: point(0.5, 0.97), control: point(0.3, 0.9))
        path.closeSubpath()
        return path
    }

    /// The map arc motif: a curve from "home" (dot) to a destination.
    static func arc(in rect: CGRect) -> (curve: CGPath, home: CGPoint) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let curve = CGMutablePath()
        curve.move(to: point(0.3, 0.33))
        curve.addQuadCurve(to: point(0.72, 0.62), control: point(0.42, 0.74))
        return (curve, point(0.3, 0.33))
    }
}

/// Template images for the status item: one glyph per mode, optional count badge.
@MainActor
enum StatusIcon {
    static let pointSize = NSSize(width: 18, height: 18)

    static func image(for mode: FilterMode, pendingApprovals: Int) -> NSImage {
        let image = NSImage(size: pointSize)
        for scale in [1, 2] {
            if let rep = render(mode: mode, badge: pendingApprovals, scale: CGFloat(scale)) {
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(mode: mode, pendingApprovals: pendingApprovals)
        return image
    }

    nonisolated static func accessibilityDescription(mode: FilterMode, pendingApprovals: Int) -> String {
        guard pendingApprovals > 0 else { return String(format: String(localized: "YAS: %@"), mode.title) }
        return String(localized: "YAS: \(mode.title), \(pendingApprovals) pending approvals")
    }

    /// Draws into a bitmap of `pointSize` × `scale` pixels. Only alpha matters:
    /// the menu bar tints template images for light and dark appearances.
    static func render(mode: FilterMode, badge: Int, scale: CGFloat) -> NSBitmapImageRep? {
        let pixels = Int(pointSize.width * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = pointSize
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let black = CGColor(gray: 0, alpha: 1)
        context.setFillColor(black)
        context.setStrokeColor(black)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let shieldRect = CGRect(x: 1.5, y: 0.75, width: 15, height: 16.5)
        let shield = ShieldGlyph.path(in: shieldRect)

        switch mode {
        case .allowAll:
            context.setLineWidth(1.4)
            context.addPath(shield)
            context.strokePath()
        case .blockList:
            context.setLineWidth(1.4)
            context.addPath(shield)
            context.strokePath()
            let arc = ShieldGlyph.arc(in: shieldRect)
            context.setLineWidth(1.3)
            context.addPath(arc.curve)
            context.strokePath()
            context.fillEllipse(in: CGRect(x: arc.home.x - 1.6, y: arc.home.y - 1.6, width: 3.2, height: 3.2))
        case .requireApproval:
            context.setLineWidth(1.4)
            context.addPath(shield)
            context.strokePath()
            drawText("?", in: shieldRect.insetBy(dx: 0, dy: 1.5), size: 10.5, weight: .bold, context: context, clear: false)
        case .blockAll:
            context.addPath(shield)
            context.fillPath()
            context.setBlendMode(.clear)
            context.setLineWidth(1.8)
            let center = CGPoint(x: shieldRect.midX, y: shieldRect.midY + 0.6)
            let arm: CGFloat = 3.3
            context.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
            context.addLine(to: CGPoint(x: center.x + arm, y: center.y + arm))
            context.move(to: CGPoint(x: center.x - arm, y: center.y + arm))
            context.addLine(to: CGPoint(x: center.x + arm, y: center.y - arm))
            context.strokePath()
            context.setBlendMode(.normal)
        }

        if badge > 0 {
            // Knock out a ring so the badge reads against the shield, then a solid dot
            // with the count knocked out of it.
            let radius: CGFloat = 5
            let center = CGPoint(x: pointSize.width - radius, y: pointSize.height - radius)
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: center.x - radius - 1.2, y: center.y - radius - 1.2,
                                           width: (radius + 1.2) * 2, height: (radius + 1.2) * 2))
            context.setBlendMode(.normal)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let text = badge > 9 ? "9+" : "\(badge)"
            drawText(text, in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
                     size: badge > 9 ? 6 : 7.5, weight: .heavy, context: context, clear: true)
        }
        return rep
    }

    private static func drawText(
        _ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, context: CGContext, clear: Bool
    ) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.black,
        ])
        let bounds = string.size()
        if clear { context.setBlendMode(.clear) }
        string.draw(at: CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
        if clear { context.setBlendMode(.normal) }
    }
}
