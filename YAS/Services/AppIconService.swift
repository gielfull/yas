import AppKit
import YASShared

/// Icons and display names for the processes behind flows, cached by path.
@MainActor
final class AppIconService {
    static let shared = AppIconService()

    private var icons: [String: NSImage] = [:]
    private var names: [String: String] = [:]

    /// Outermost `.app` bundle containing `executablePath`, so helpers like
    /// `Google Chrome.app/.../Google Chrome Helper.app/.../Google Chrome Helper`
    /// resolve to Google Chrome.
    nonisolated static func appBundleURL(forExecutablePath executablePath: String) -> URL? {
        let components = (executablePath as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
    }

    /// Name of one process: its own (innermost) .app bundle, e.g. "Google Chrome
    /// Helper (GPU)", else the command name. Works without the bundle on disk.
    nonisolated static func processName(forExecutablePath path: String) -> String {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" {
                let info = Bundle(url: url)?.infoDictionary
                return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return commandName(forExecutablePath: path)
    }

    /// Name for a non-bundle executable. Tools installed per version (e.g.
    /// `~/.local/share/claude/versions/2.1.277`) are named after their folder, not
    /// the version number.
    nonisolated static func commandName(forExecutablePath path: String) -> String {
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        guard let last = components.last else { return path }
        func isVersion(_ text: String) -> Bool {
            let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
            return trimmed.first?.isNumber == true && trimmed.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }
                && trimmed.contains(".")
        }
        guard isVersion(last) else { return last }
        for component in components.dropLast().reversed() where !isVersion(component) && component != "versions" && component != "bin" {
            return component
        }
        return last
    }

    func icon(forExecutablePath path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon: NSImage
        if let bundleURL = Self.appBundleURL(forExecutablePath: path),
           FileManager.default.fileExists(atPath: bundleURL.path) {
            icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        } else if FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if Self.appBundleURL(forExecutablePath: path) != nil {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        } else {
            icon = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        icons[path] = icon
        return icon
    }

    /// Icon of the process's own (innermost) .app, e.g. a helper's; else the app's.
    func processIcon(forExecutablePath path: String) -> NSImage {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" {
                guard FileManager.default.fileExists(atPath: url.path) else { break }
                let key = "process:" + url.path
                if let cached = icons[key] { return cached }
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icons[key] = icon
                return icon
            }
            url.deleteLastPathComponent()
        }
        return icon(forExecutablePath: path)
    }

    func displayName(forExecutablePath path: String) -> String {
        if let cached = names[path] { return cached }
        let name: String
        if let bundleURL = Self.appBundleURL(forExecutablePath: path) {
            let bundle = Bundle(url: bundleURL)
            let info = bundle?.localizedInfoDictionary ?? [:]
            let fallback = bundle?.infoDictionary ?? [:]
            name = (info["CFBundleDisplayName"] as? String)
                ?? (fallback["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? (fallback["CFBundleName"] as? String)
                ?? bundleURL.deletingPathExtension().lastPathComponent
        } else {
            name = Self.commandName(forExecutablePath: path)
        }
        names[path] = name
        return name
    }
}
