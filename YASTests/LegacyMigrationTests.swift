import XCTest
@testable import YAS

/// One-time move from the app's former name (OpenShield); old names are the point here.
final class LegacyMigrationTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("LegacyMigration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func write(_ relativePath: String, _ text: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relativePath: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(relativePath))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testMovesAndRenamesDatabasesAndOtherFiles() throws {
        try write("OpenShield/openshield.sqlite", "main")
        try write("OpenShield/openshield.sqlite-wal", "wal")
        try write("OpenShield/openshield.sqlite-shm", "shm")
        try write("OpenShield/openshield-demo.sqlite", "demo")
        try write("OpenShield/rules.json.imported", "rules")

        let report = try LegacyMigration.migrateFiles(applicationSupport: root, fileManager: fileManager)

        XCTAssertEqual(read("YAS/yas.sqlite"), "main")
        XCTAssertEqual(read("YAS/yas.sqlite-wal"), "wal", "WAL moves with its database")
        XCTAssertEqual(read("YAS/yas.sqlite-shm"), "shm")
        XCTAssertEqual(read("YAS/yas-demo.sqlite"), "demo")
        XCTAssertEqual(read("YAS/rules.json.imported"), "rules", "other files keep their names")
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertEqual(report.moved.count, 5)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("OpenShield").path),
                       "the emptied old folder is removed")
    }

    func testNeverOverwritesExistingYASDataAndIsIdempotent() throws {
        try write("OpenShield/openshield.sqlite", "old main")
        try write("OpenShield/openshield.sqlite-wal", "old wal")
        try write("OpenShield/openshield-demo.sqlite", "old demo")
        try write("OpenShield/notes.txt", "old notes")
        try write("YAS/yas.sqlite", "new main") // already migrated/used: its group must not move
        try write("YAS/notes.txt", "new notes")

        let first = try LegacyMigration.migrateFiles(applicationSupport: root, fileManager: fileManager)
        XCTAssertEqual(read("YAS/yas.sqlite"), "new main")
        XCTAssertNil(read("YAS/yas.sqlite-wal"), "an old WAL never lands next to a different database")
        XCTAssertEqual(read("YAS/notes.txt"), "new notes")
        XCTAssertEqual(read("YAS/yas-demo.sqlite"), "old demo", "unrelated files still move")
        XCTAssertEqual(Set(first.skipped), ["openshield.sqlite", "openshield.sqlite-wal", "notes.txt"])
        XCTAssertEqual(read("OpenShield/openshield.sqlite"), "old main", "skipped files stay where they were")

        let second = try LegacyMigration.migrateFiles(applicationSupport: root, fileManager: fileManager)
        XCTAssertTrue(second.moved.isEmpty, "running again moves nothing")
        XCTAssertEqual(read("YAS/yas.sqlite"), "new main")
    }

    func testNothingToDoWithoutTheOldFolder() throws {
        let report = try LegacyMigration.migrateFiles(applicationSupport: root, fileManager: fileManager)
        XCTAssertEqual(report, .init())
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("YAS").path))
    }

    func testCopiesKnownSettingsOnceWithoutOverwriting() throws {
        let legacyName = "test.legacy.\(UUID().uuidString)"
        let currentName = "test.current.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacyName))
        let current = try XCTUnwrap(UserDefaults(suiteName: currentName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            current.removePersistentDomain(forName: currentName)
        }
        legacy.set("blockAll", forKey: "filterMode")
        legacy.set(true, forKey: "isMapHidden")
        legacy.set(7, forKey: "historyRetentionDays")
        legacy.set("secret", forKey: "someUnknownKey")
        current.set(30, forKey: "historyRetentionDays") // the user already chose in YAS

        // The test host has registered defaults for these keys; they must not count as "already set".
        let copied = LegacyMigration.migrateDefaults(
            from: legacy, to: current, currentDomain: currentName,
            keys: ["filterMode", "isMapHidden", "historyRetentionDays", "homeCountryOverride"])
        XCTAssertEqual(Set(copied), ["filterMode", "isMapHidden"])
        XCTAssertEqual(current.string(forKey: "filterMode"), "blockAll")
        XCTAssertEqual(current.integer(forKey: "historyRetentionDays"), 30, "existing YAS settings win")
        XCTAssertNil(current.object(forKey: "someUnknownKey"), "only known keys are copied")
        XCTAssertEqual(legacy.string(forKey: "filterMode"), "blockAll", "the old domain is left alone")

        legacy.set("allowAll", forKey: "filterMode")
        current.removeObject(forKey: "filterMode")
        XCTAssertTrue(LegacyMigration.migrateDefaults(from: legacy, to: current, currentDomain: currentName, keys: ["filterMode"]).isEmpty,
                      "runs once")
    }

    func testMigratableKeysCoverThePreferences() {
        for key in ["showInDock", "filterMode", "isMapHidden", "mapPaneWidth", "historyRetentionDays", "NSWindow Frame MainWindow"] {
            XCTAssertTrue(Preferences.migratableKeys.contains(key), key)
        }
    }
}
