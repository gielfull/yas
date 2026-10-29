import Foundation
import os

/// One-time move of data from the app's former name, OpenShield (renamed to YAS
/// on 2026-09-21). The old names below are intentional: they are what's on disk.
///
/// - Files: `~/Library/Application Support/OpenShield/*` → `…/YAS/`, with the
///   databases renamed (`openshield.sqlite` → `yas.sqlite`, demo likewise). A
///   database moves together with its `-wal` / `-shm` files, or not at all.
/// - Settings: known keys are copied from the `com.gful.openshield` defaults
///   domain into the current one. The old domain is left alone.
///
/// Idempotent and never overwrites anything that already exists under YAS.
enum LegacyMigration {
    static let legacyFolderName = "OpenShield"
    static let currentFolderName = "YAS"
    static let legacyDefaultsDomain = "com.gful.openshield"
    /// Set in the current domain once settings were copied.
    static let defaultsDoneKey = "legacyDefaultsMigrated"
    static let renamedDatabases = ["openshield.sqlite": "yas.sqlite", "openshield-demo.sqlite": "yas-demo.sqlite"]
    private static let sqliteSiblingSuffixes = ["", "-wal", "-shm"]

    struct FileReport: Equatable {
        var moved: [String] = []
        /// Left in the old folder because the destination already exists.
        var skipped: [String] = []
    }

    // MARK: - Files

    static func migrateFiles(applicationSupport: URL, fileManager: FileManager = .default) throws -> FileReport {
        let legacy = applicationSupport.appendingPathComponent(legacyFolderName, isDirectory: true)
        let current = applicationSupport.appendingPathComponent(currentFolderName, isDirectory: true)
        var report = FileReport()
        guard fileManager.fileExists(atPath: legacy.path) else { return report }
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)

        var remaining = Set(try fileManager.contentsOfDirectory(atPath: legacy.path))

        // Databases move as a group (main file + WAL + SHM) so a new database never
        // gets an old WAL next to it.
        for (oldName, newName) in renamedDatabases.sorted(by: { $0.key < $1.key }) {
            let members = sqliteSiblingSuffixes.map { (oldName + $0, newName + $0) }.filter { remaining.contains($0.0) }
            guard !members.isEmpty else { continue }
            members.forEach { remaining.remove($0.0) }
            let destinationTaken = sqliteSiblingSuffixes.contains {
                fileManager.fileExists(atPath: current.appendingPathComponent(newName + $0).path)
            }
            if destinationTaken {
                report.skipped += members.map(\.0)
                continue
            }
            for (from, to) in members {
                try fileManager.moveItem(at: legacy.appendingPathComponent(from), to: current.appendingPathComponent(to))
                report.moved.append("\(from) → \(to)")
            }
        }

        for name in remaining.sorted() {
            let destination = current.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                report.skipped.append(name)
                continue
            }
            try fileManager.moveItem(at: legacy.appendingPathComponent(name), to: destination)
            report.moved.append(name)
        }

        if (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
            try? fileManager.removeItem(at: legacy)
        }
        return report
    }

    // MARK: - Settings

    /// Copies `keys` that exist in `legacy` and aren't saved in `current` (whose
    /// persistent domain is `currentDomain`), once. Only saved values count as set:
    /// registered defaults are process-wide and would otherwise hide every key.
    @discardableResult
    static func migrateDefaults(
        from legacy: UserDefaults, to current: UserDefaults, currentDomain: String, keys: [String]
    ) -> [String] {
        let saved = current.persistentDomain(forName: currentDomain) ?? [:]
        guard saved[defaultsDoneKey] == nil else { return [] }
        var copied: [String] = []
        for key in keys where saved[key] == nil {
            guard let value = legacy.object(forKey: key) else { continue }
            current.set(value, forKey: key)
            copied.append(key)
        }
        current.set(true, forKey: defaultsDoneKey)
        return copied
    }

    // MARK: - App launch

    static func runAtLaunch() {
        let logger = Logger(subsystem: "com.gful.yas", category: "Migration")
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            do {
                let report = try migrateFiles(applicationSupport: support)
                if !report.moved.isEmpty || !report.skipped.isEmpty {
                    logger.notice("Moved from OpenShield: \(report.moved.joined(separator: ", "), privacy: .public); kept (YAS copy exists): \(report.skipped.joined(separator: ", "), privacy: .public)")
                }
            } catch {
                logger.error("File migration failed: \(String(describing: error), privacy: .public)")
            }
        }
        if let legacy = UserDefaults(suiteName: legacyDefaultsDomain) {
            let domain = Bundle.main.bundleIdentifier ?? "com.gful.yas"
            let copied = migrateDefaults(from: legacy, to: .standard, currentDomain: domain, keys: Preferences.migratableKeys)
            if !copied.isEmpty {
                logger.notice("Copied settings from OpenShield: \(copied.joined(separator: ", "), privacy: .public)")
            }
        }
    }
}
