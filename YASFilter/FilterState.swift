import Foundation
import YASShared

/// Extension-side tunables that are not rules. Persisted with the rules; there is
/// no XPC method to change them yet, so they hold their defaults unless the state
/// file is edited.
struct FilterSettings: Codable, Hashable, Sendable {
    static let timeoutRange: ClosedRange<TimeInterval> = 5...600

    /// Seconds a paused flow waits for the user's answer before `timeoutAction`.
    var approvalTimeout: TimeInterval
    /// Applied once (never persisted) when the user does not answer in time.
    var timeoutAction: RuleAction
    /// Applied to flows that need approval while no app is connected, and to every
    /// paused flow when the app disconnects or the filter stops.
    var noClientAction: RuleAction
    /// Cut connections that are already open when the rules or mode now block them
    /// (e.g. Disconnect, Block All). Off: rules only apply to new connections, and
    /// allowed flows get a final allow with no further inspection.
    var cutLiveConnections: Bool

    init(
        approvalTimeout: TimeInterval = 60,
        timeoutAction: RuleAction = .block,
        noClientAction: RuleAction = .allow,
        cutLiveConnections: Bool = true
    ) {
        self.approvalTimeout = approvalTimeout.clamped(to: Self.timeoutRange)
        self.timeoutAction = timeoutAction
        self.noClientAction = noClientAction
        self.cutLiveConnections = cutLiveConnections
    }

    /// Missing keys fall back to defaults so older files keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FilterSettings()
        self.init(
            approvalTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .approvalTimeout)
                ?? defaults.approvalTimeout,
            timeoutAction: try container.decodeIfPresent(RuleAction.self, forKey: .timeoutAction)
                ?? defaults.timeoutAction,
            noClientAction: try container.decodeIfPresent(RuleAction.self, forKey: .noClientAction)
                ?? defaults.noClientAction,
            cutLiveConnections: try container.decodeIfPresent(Bool.self, forKey: .cutLiveConnections)
                ?? defaults.cutLiveConnections
        )
    }
}

/// Everything the extension persists so filtering keeps working while the app is
/// closed. The app is the source of truth and overwrites the rules
/// and mode on every connect.
struct FilterState: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    /// Fail-open default: block rules apply, everything else is allowed.
    var mode: FilterMode
    var rules: [Rule]
    var settings: FilterSettings

    init(
        mode: FilterMode = .blockList,
        rules: [Rule] = [],
        settings: FilterSettings = FilterSettings()
    ) {
        self.version = Self.currentVersion
        self.mode = mode
        self.rules = rules
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        mode = try container.decodeIfPresent(FilterMode.self, forKey: .mode) ?? .blockList
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        settings = try container.decodeIfPresent(FilterSettings.self, forKey: .settings) ?? FilterSettings()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
