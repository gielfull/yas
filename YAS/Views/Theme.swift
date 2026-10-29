import AppKit
import YASShared

/// Colors, fonts and metrics shared by the main window, map and panels.
enum Theme {
    static let pillOrange = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.12, alpha: 1)
    static let activeGreen = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.35, alpha: 1)
    static let idleGrey = NSColor(white: 0.55, alpha: 1)
    static let blockedRed = NSColor(srgbRed: 1.0, green: 0.32, blue: 0.30, alpha: 1)
    static let pendingOrange = NSColor.systemOrange
    static let separator = NSColor(white: 1, alpha: 0.09)
    static let arc = NSColor(srgbRed: 0.78, green: 0.86, blue: 1.0, alpha: 0.55)
    static let arcHighlighted = NSColor(srgbRed: 0.35, green: 0.72, blue: 1.0, alpha: 0.95)
    static let arcDimmed = NSColor(srgbRed: 0.78, green: 0.86, blue: 1.0, alpha: 0.16)
    static let mapTint = NSColor(srgbRed: 0.04, green: 0.13, blue: 0.50, alpha: 0.48)
    static let panelBackground = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
    static let received = NSColor(srgbRed: 0.33, green: 0.66, blue: 1.0, alpha: 1)
    static let sent = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.12, alpha: 1)
    static let controlBorder = NSColor(white: 1, alpha: 0.14)

    static let listLeftTop = NSColor(srgbRed: 0.145, green: 0.145, blue: 0.150, alpha: 0.96)
    static let listLeftMiddle = NSColor(srgbRed: 0.160, green: 0.145, blue: 0.145, alpha: 0.93)
    static let listLeftBottom = NSColor(srgbRed: 0.330, green: 0.160, blue: 0.130, alpha: 0.88)

    static let sidebarWidth: CGFloat = 440

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    /// Two-tone symbol: `glyph` for the foreground mark, `fill` for the shape.
    static func paletteSymbol(_ name: String, pointSize: CGFloat, glyph: NSColor, fill: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [glyph, fill]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}

extension FilterMode {
    var title: String {
        switch self {
        case .allowAll: String(localized: "Allow All")
        case .blockList: String(localized: "Block List")
        case .requireApproval: String(localized: "Require Approval")
        case .blockAll: String(localized: "Block All")
        }
    }

    var summary: String {
        switch self {
        case .allowAll: String(localized: "Allow every connection and only record it.")
        case .blockList: String(localized: "Allow everything except what your block rules match.")
        case .requireApproval: String(localized: "Ask before any app without a rule connects.")
        case .blockAll: String(localized: "Block every connection except YAS's own.")
        }
    }

    var symbolName: String {
        switch self {
        case .allowAll: "checkmark.circle.fill"
        case .blockList: "line.3.horizontal.decrease.circle.fill"
        case .requireApproval: "questionmark.circle.fill"
        case .blockAll: "xmark.circle.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .allowAll: Theme.activeGreen
        case .blockList: NSColor.systemBlue
        case .requireApproval: NSColor.systemYellow
        case .blockAll: Theme.blockedRed
        }
    }

    /// Template symbol for the menu bar.
    var statusSymbolName: String {
        switch self {
        case .allowAll: "shield"
        case .blockList: "checkmark.shield"
        case .requireApproval: "shield.lefthalf.filled"
        case .blockAll: "xmark.shield"
        }
    }

    /// Menu order: most permissive to most restrictive.
    static let menuOrder: [FilterMode] = [.allowAll, .blockList, .requireApproval, .blockAll]
}

extension Verdict {
    var title: String {
        switch self {
        case .allowed: String(localized: "Allowed")
        case .blocked: String(localized: "Blocked")
        case .approved: String(localized: "Approved")
        case .pending: String(localized: "Waiting for approval")
        }
    }

    var symbolName: String {
        switch self {
        case .allowed: "checkmark.circle.fill"
        case .blocked: "xmark.octagon.fill"
        case .approved: "checkmark.seal.fill"
        case .pending: "clock.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .allowed, .approved: Theme.activeGreen
        case .blocked: Theme.blockedRed
        case .pending: Theme.pendingOrange
        }
    }
}

extension AppIdentity {
    /// "Apple", "Developer ID (TEAMID)" or an unsigned warning.
    var signatureDescription: String {
        if isAppleSigned && isValidlySigned { return String(localized: "Signed by Apple") }
        if isValidlySigned, let teamID {
            return String(format: String(localized: "Verified developer (%@)"), teamID)
        }
        if isValidlySigned { return String(localized: "Signed (ad hoc)") }
        return String(localized: "Unsigned or invalid signature")
    }

    var hasWarningSignature: Bool { !hasTrustedSigningIdentity }
}

extension NSTextField {
    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

extension ByteCountFormatter {
    /// File-style byte count that always shows a number ("0 bytes", not "Zero KB").
    static func string(for bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
