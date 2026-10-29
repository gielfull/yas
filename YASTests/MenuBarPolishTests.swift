import AppKit
import YASShared
import XCTest
@testable import YAS

final class PauseScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testDeadlinePassedWhileQuitRestoresThePreviousMode() {
        let state = PauseSchedule.restore(
            savedMode: .allowAll, pausedUntil: now.addingTimeInterval(-1), modeBeforePause: .requireApproval, now: now)
        XCTAssertEqual(state, .init(mode: .requireApproval, pausedUntil: nil, modeBeforePause: nil))
    }

    func testDeadlineExactlyNowCountsAsPassed() {
        let state = PauseSchedule.restore(savedMode: .allowAll, pausedUntil: now, modeBeforePause: .blockAll, now: now)
        XCTAssertEqual(state.mode, .blockAll)
        XCTAssertNil(state.pausedUntil)
    }

    func testFutureDeadlineStaysPausedInAllowAll() {
        let until = now.addingTimeInterval(600)
        let state = PauseSchedule.restore(savedMode: .blockList, pausedUntil: until, modeBeforePause: .blockList, now: now)
        XCTAssertEqual(state, .init(mode: .allowAll, pausedUntil: until, modeBeforePause: .blockList))
    }

    func testIncompleteRecordIsDiscarded() {
        XCTAssertEqual(
            PauseSchedule.restore(savedMode: .blockList, pausedUntil: now.addingTimeInterval(600), modeBeforePause: nil, now: now),
            .init(mode: .blockList, pausedUntil: nil, modeBeforePause: nil))
        XCTAssertEqual(
            PauseSchedule.restore(savedMode: .blockAll, pausedUntil: nil, modeBeforePause: .allowAll, now: now),
            .init(mode: .blockAll, pausedUntil: nil, modeBeforePause: nil))
    }

    func testMinutesRemainingRoundsUpAndNeverShowsZero() {
        XCTAssertEqual(PauseSchedule.minutesRemaining(until: now.addingTimeInterval(15 * 60), now: now), 15)
        XCTAssertEqual(PauseSchedule.minutesRemaining(until: now.addingTimeInterval(11 * 60 + 1), now: now), 12)
        XCTAssertEqual(PauseSchedule.minutesRemaining(until: now.addingTimeInterval(59), now: now), 1)
        XCTAssertEqual(PauseSchedule.minutesRemaining(until: now.addingTimeInterval(-30), now: now), 1)
    }
}

final class ActivationPolicyTests: XCTestCase {
    func testDockSettingMapsToActivationPolicy() {
        XCTAssertEqual(AppDelegate.activationPolicy(showInDock: true), .regular)
        XCTAssertEqual(AppDelegate.activationPolicy(showInDock: false), .accessory)
    }

    func testShowInDockIsPersistedAndDefaultsToTrue() {
        let key = "showInDock"
        let saved = StoredDefaults([key])
        defer { saved.restore() }

        UserDefaults.standard.removeObject(forKey: key)
        Preferences.registerDefaults()
        XCTAssertTrue(Preferences.showInDock, "Dock icon by default")
        Preferences.showInDock = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
        XCTAssertFalse(Preferences.showInDock)
    }
}

@MainActor
final class StatusIconTests: XCTestCase {
    private func opaquePixels(_ rep: NSBitmapImageRep) -> Set<Int> {
        var result: Set<Int> = []
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                result.insert(y * rep.pixelsWide + x)
            }
        }
        return result
    }

    func testEveryModeHasADistinctTemplateGlyphAtBothScales() throws {
        var glyphs: [Set<Int>] = []
        for mode in FilterMode.allCases {
            let image = StatusIcon.image(for: mode, pendingApprovals: 0)
            XCTAssertTrue(image.isTemplate, "\(mode) must be a template so the menu bar tints it")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            let widths = image.representations.map(\.pixelsWide).sorted()
            XCTAssertEqual(widths, [18, 36], "1x and 2x")
            let rep = try XCTUnwrap(StatusIcon.render(mode: mode, badge: 0, scale: 2))
            let pixels = opaquePixels(rep)
            XCTAssertGreaterThan(pixels.count, 150, "\(mode) glyph is visible")
            glyphs.append(pixels)
        }
        XCTAssertEqual(Set(glyphs).count, FilterMode.allCases.count, "modes are distinguishable")
    }

    func testBadgeChangesTheGlyphAndItsDescription() throws {
        let plain = try XCTUnwrap(StatusIcon.render(mode: .blockList, badge: 0, scale: 2))
        let badged = try XCTUnwrap(StatusIcon.render(mode: .blockList, badge: 3, scale: 2))
        XCTAssertNotEqual(opaquePixels(plain), opaquePixels(badged))
        XCTAssertNotEqual(
            StatusIcon.accessibilityDescription(mode: .blockList, pendingApprovals: 0),
            StatusIcon.accessibilityDescription(mode: .blockList, pendingApprovals: 3))
    }
}

/// Every string is localized, every key has a finished Spanish translation.
final class LocalizationTests: XCTestCase {
    private let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func catalog(_ name: String) throws -> [String: Any] {
        let url = projectRoot.appendingPathComponent("YAS/Resources/\(name).xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any])
    }

    /// Every string unit under a localization, including plural variations.
    private func units(_ localization: Any?) -> [[String: Any]] {
        guard let localization = localization as? [String: Any] else { return [] }
        var result: [[String: Any]] = []
        if let unit = localization["stringUnit"] as? [String: Any] { result.append(unit) }
        if let variations = localization["variations"] as? [String: Any] {
            for case let kind as [String: Any] in variations.values {
                for case let variant as [String: Any] in kind.values {
                    result += units(variant)
                }
            }
        }
        return result
    }

    func testEveryKeyHasFinishedEnglishAndSpanish() throws {
        for name in ["Localizable", "InfoPlist"] {
            let strings = try catalog(name)
            XCTAssertFalse(strings.isEmpty, name)
            for (key, value) in strings {
                let localizations = (value as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                for language in ["en", "es"] {
                    let languageUnits = units(localizations[language])
                    XCTAssertFalse(languageUnits.isEmpty, "\(name): '\(key)' has no \(language) value")
                    for unit in languageUnits {
                        XCTAssertEqual(unit["state"] as? String, "translated", "\(name): '\(key)' \(language) is not translated")
                        XCTAssertFalse((unit["value"] as? String ?? "").isEmpty, "\(name): '\(key)' \(language) is empty")
                    }
                }
            }
        }
    }

    func testEveryLocalizedLiteralInTheSourcesIsInTheCatalog() throws {
        let keys = Set(try catalog("Localizable").keys)
        for (file, source) in try sources() {
            // Literals without interpolation map 1:1 to keys.
            let regex = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let literal = String(source[range])
                guard !literal.contains("\\(") else { continue }
                let key = literal.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
                XCTAssertTrue(keys.contains(key), "\(file): '\(key)' is missing from Localizable.xcstrings")
            }
        }
    }

    func testNoHardCodedProseInUserFacingAPIs() throws {
        // A literal starting with a letter passed straight to a UI text API.
        let pattern = #"(title|withTitle|labelWithString|wrappingLabelWithString|toolTip|placeholderString|setAccessibilityLabel|messageText|informativeText|addItem\(withTitle)\s*[:=(]\s*"[A-Za-z]"#
        let regex = try NSRegularExpression(pattern: pattern)
        for (file, source) in try sources() {
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    XCTFail("\(file):\(number + 1) hard-coded UI string: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    func testSpanishIsCompiledIntoTheApp() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "es", ofType: "lproj"), "es.lproj missing from the app")
        let spanish = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(spanish.localizedString(forKey: "Settings…", value: nil, table: nil), "Ajustes…")
        XCTAssertEqual(spanish.localizedString(forKey: "Quit YAS", value: nil, table: nil), "Salir de YAS")
        let usage = spanish.localizedString(forKey: "NSSystemExtensionUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(usage.hasPrefix("YAS usa"), usage)
    }

    private func sources() throws -> [(String, String)] {
        let folder = projectRoot.appendingPathComponent("YAS")
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var result: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(result.count, 20, "found the app sources")
        return result
    }
}

/// Saves only what's really stored for `keys` (not registered defaults) and puts it
/// back afterwards, removing keys that weren't stored. Keeps tests from leaving
/// settings in the app's real defaults domain.
struct StoredDefaults {
    private let values: [String: Any?]

    init(_ keys: [String]) {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        values = Dictionary(uniqueKeysWithValues: keys.map { ($0, domain[$0]) })
    }

    func restore() {
        for (key, value) in values {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
