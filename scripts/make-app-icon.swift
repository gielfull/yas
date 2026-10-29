#!/usr/bin/env swift
// Renders YAS's app icon into YAS/Resources/Assets.xcassets/AppIcon.appiconset
// at every size macOS needs, and rewrites Contents.json.
//
//   swift scripts/make-app-icon.swift
//
// Design: dark-to-warm squircle (the sidebar gradient) with an orange shield carrying
// the map-arc motif (home dot + arc), the same shape as the menu bar glyph in
// YAS/Views/StatusIcon.swift (ShieldGlyph).
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("YAS/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Same outline as ShieldGlyph.path in the app.
func shieldPath(in rect: CGRect) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
    let path = CGMutablePath()
    path.move(to: p(0.5, 0.97))
    path.addQuadCurve(to: p(0.9, 0.83), control: p(0.7, 0.9))
    path.addLine(to: p(0.9, 0.52))
    path.addQuadCurve(to: p(0.5, 0.03), control: p(0.88, 0.17))
    path.addQuadCurve(to: p(0.1, 0.52), control: p(0.12, 0.17))
    path.addLine(to: p(0.1, 0.83))
    path.addQuadCurve(to: p(0.5, 0.97), control: p(0.3, 0.9))
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let unit = size / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: 824pt body centred in 1024, continuous-ish corners.
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit, color: color(0x000000, 0.45))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x26262A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x2C2C31), color(0x2A2427), color(0x5A2718)] as CFArray,
                                locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Faint graticule, a nod to the map.
    ctx.setStrokeColor(color(0xFFFFFF, 0.05))
    ctx.setLineWidth(max(1, 4 * unit))
    for fraction in stride(from: 0.2, through: 0.8, by: 0.2) {
        ctx.move(to: CGPoint(x: body.minX, y: body.minY + body.height * fraction))
        ctx.addLine(to: CGPoint(x: body.maxX, y: body.minY + body.height * fraction))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Shield.
    let shieldRect = CGRect(x: 262 * unit, y: 190 * unit, width: 500 * unit, height: 600 * unit)
    let shield = shieldPath(in: shieldRect)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 24 * unit, color: color(0x000000, 0.4))
    ctx.addPath(shield)
    ctx.setFillColor(color(0xFF8C1F))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shield)
    ctx.clip()
    let orange = CGGradient(colorsSpace: space, colors: [color(0xFFB04A), color(0xFF6A13)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(orange, start: CGPoint(x: 0, y: shieldRect.maxY), end: CGPoint(x: 0, y: shieldRect.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(shield)
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(max(1, 6 * unit))
    ctx.strokePath()

    // Arc from home (dark dot) to a destination (white dot).
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: shieldRect.minX + x * shieldRect.width, y: shieldRect.minY + y * shieldRect.height)
    }
    let home = p(0.3, 0.33), destination = p(0.72, 0.62)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x26262A))
    ctx.setLineWidth(max(1.5, 34 * unit))
    ctx.move(to: home)
    ctx.addQuadCurve(to: destination, control: p(0.42, 0.74))
    ctx.strokePath()
    let dot = max(2, 44 * unit)
    ctx.setFillColor(color(0x26262A))
    ctx.fillEllipse(in: CGRect(x: home.x - dot, y: home.y - dot, width: dot * 2, height: dot * 2))
    let small = max(1.5, 30 * unit)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: destination.x - small, y: destination.y - small, width: small * 2, height: small * 2))

    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: pixels).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
