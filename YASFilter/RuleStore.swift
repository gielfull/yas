import Foundation
import YASShared
import os

/// Rules, mode and settings, cached as JSON in the extension's container.
///
/// Reads are a lock and a copy-on-write struct copy, so the filter path can call
/// `snapshot` on every flow. Writes to disk happen on a background queue and
/// always write the latest state, so a burst of updates costs one file write each
/// but can never persist an older state last.
///
/// Every change bumps `generation` and rebuilds `ruleSnapshot` under the same
/// lock, so a snapshot's generation always matches its contents. Live-connection
/// checks compare generations instead of re-running the engine per data chunk.
final class RuleStore: Sendable {
    private struct Stored: Sendable {
        var state: FilterState
        var generation: UInt64 = 0
        var ruleSnapshot: RuleSnapshot

        init(state: FilterState) {
            self.state = state
            self.ruleSnapshot = Self.makeSnapshot(state, generation: 0)
        }

        mutating func update(_ body: (inout FilterState) -> Void) {
            body(&state)
            generation &+= 1
            ruleSnapshot = Self.makeSnapshot(state, generation: generation)
        }

        static func makeSnapshot(_ state: FilterState, generation: UInt64) -> RuleSnapshot {
            RuleSnapshot(generation: generation, mode: state.mode, rules: state.rules, settings: state.settings)
        }
    }

    private let stored = OSAllocatedUnfairLock(initialState: Stored(state: FilterState()))
    private let fileURL: URL?
    private let ioQueue = DispatchQueue(label: "com.gful.yas.filter.store", qos: .utility)

    /// - Parameter fileURL: nil keeps the store in memory only.
    init(fileURL: URL? = RuleStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/YASFilter/state.json` inside the
    /// extension's sandbox container (root's home, since the extension runs as root).
    static func defaultFileURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("YASFilter", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    var snapshot: FilterState { stored.withLock { $0.state } }
    var mode: FilterMode { stored.withLock { $0.state.mode } }
    var settings: FilterSettings { stored.withLock { $0.state.settings } }
    /// Changes whenever mode, rules or settings change.
    var generation: UInt64 { stored.withLock { $0.generation } }
    var ruleSnapshot: RuleSnapshot { stored.withLock { $0.ruleSnapshot } }

    /// Reads the cached state from disk. Call once at startup, before filtering.
    /// A missing or unreadable file leaves the fail-open defaults in place.
    func load() {
        guard let fileURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            Log.store.info("No cached state yet; using defaults")
            return
        } catch {
            Log.store.error("Could not read cached state: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            let loaded = try PayloadCoder.decode(FilterState.self, from: data)
            stored.withLock { $0.update { $0 = loaded } }
            Log.store.info(
                "Loaded \(loaded.rules.count) rules, mode \(loaded.mode.rawValue, privacy: .public)")
        } catch {
            Log.store.error("Cached state is corrupt, using defaults: \(error.localizedDescription, privacy: .public)")
        }
    }

    func replaceRules(_ rules: [Rule]) {
        stored.withLock { $0.update { $0.rules = rules } }
        persist()
    }

    func setMode(_ mode: FilterMode) {
        stored.withLock { $0.update { $0.mode = mode } }
        persist()
    }

    func setSettings(_ settings: FilterSettings) {
        stored.withLock { $0.update { $0.settings = settings } }
        persist()
    }

    /// Appends `rule`, or replaces the rule with the same ID.
    func addRule(_ rule: Rule) {
        stored.withLock { $0.update { state in
            if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
                state.rules[index] = rule
            } else {
                state.rules.append(rule)
            }
        } }
        persist()
    }

    func containsRule(id: UUID) -> Bool {
        stored.withLock { $0.state.rules.contains { $0.id == id } }
    }

    /// Blocks until pending writes finish. For shutdown.
    func flush() {
        ioQueue.sync {}
    }

    private func persist() {
        guard let fileURL else { return }
        ioQueue.async { [stored] in
            let current = stored.withLock { $0.state }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PayloadCoder.encode(current)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.store.error("Could not save state: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
