import Foundation
import YASShared

/// What the main list and map show: activity within the last N, or everything in memory.
/// Stored as its raw value; `all` is 0 so older stored values (seconds) still decode.
enum TimeWindow: Int, CaseIterable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600
    case oneDay = 86400
    /// Everything in memory (history is bounded by retention and the in-memory cap).
    case all = 0

    /// Nil for `all`.
    var duration: TimeInterval? { self == .all ? nil : TimeInterval(rawValue) }

    /// Decodes a stored value; anything unknown falls back to 5 minutes.
    static func fromStored(_ raw: Int?) -> TimeWindow {
        raw.flatMap(TimeWindow.init(rawValue:)) ?? .fiveMinutes
    }

    var shortLabel: String {
        switch self {
        case .oneMinute: String(localized: "1m")
        case .fiveMinutes: String(localized: "5m")
        case .fifteenMinutes: String(localized: "15m")
        case .oneHour: String(localized: "1h")
        case .oneDay: String(localized: "24h")
        case .all: String(localized: "All")
        }
    }

    var longLabel: String {
        switch self {
        case .oneMinute: String(localized: "Last minute")
        case .fiveMinutes: String(localized: "Last 5 minutes")
        case .fifteenMinutes: String(localized: "Last 15 minutes")
        case .oneHour: String(localized: "Last hour")
        case .oneDay: String(localized: "Last 24 hours")
        case .all: String(localized: "All history")
        }
    }

    /// Empty-state text for the main list.
    var emptyMessage: String {
        switch self {
        case .oneMinute: String(localized: "No connections in the last minute")
        case .fiveMinutes: String(localized: "No connections in the last 5 minutes")
        case .fifteenMinutes: String(localized: "No connections in the last 15 minutes")
        case .oneHour: String(localized: "No connections in the last hour")
        case .oneDay: String(localized: "No connections in the last 24 hours")
        case .all: String(localized: "No connections yet.\nApps appear here as they connect.")
        }
    }
}

/// How long flow history is kept in the database.
enum HistoryRetention: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var duration: TimeInterval { TimeInterval(rawValue) * 86_400 }

    var title: String {
        switch self {
        case .oneDay: String(localized: "1 day")
        case .sevenDays: String(localized: "7 days")
        case .thirtyDays: String(localized: "30 days")
        case .ninetyDays: String(localized: "90 days")
        }
    }
}

enum MapStyle: String, Sendable {
    case satellite
    case dark
}

/// Typed access to the app's UserDefaults. `UserDefaults` is thread-safe, so this
/// is not actor-isolated.
enum Preferences {
    private enum Key {
        static let showInDock = "showInDock"
        static let timeWindow = "timeWindow"
        static let filterMode = "filterMode"
        static let homeCountryOverride = "homeCountryOverride"
        static let mapStyle = "mapStyle"
        static let pausedUntil = "filteringPausedUntil"
        static let modeBeforePause = "modeBeforePause"
        static let historyRetentionDays = "historyRetentionDays"
        static let hasShownOnboarding = "hasShownOnboarding"
        static let isMapHidden = "isMapHidden"
        static let detailPage = "detailPage"
        static let mapPaneWidth = "mapPaneWidth"
        static let disconnectRuleIDs = "disconnectRuleIDs"
    }

    private static var defaults: UserDefaults { .standard }

    /// Settings worth carrying over from the app's former name (see LegacyMigration),
    /// including window/split frames saved by AppKit.
    static let migratableKeys: [String] = [
        Key.showInDock, Key.timeWindow, Key.filterMode, Key.homeCountryOverride, Key.mapStyle,
        Key.pausedUntil, Key.modeBeforePause, Key.historyRetentionDays, Key.hasShownOnboarding,
        Key.isMapHidden, Key.mapPaneWidth, Key.detailPage,
        "NSWindow Frame MainWindow", "NSSplitView Subview Frames MainSplit",
    ]

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.showInDock: true,
            Key.timeWindow: TimeWindow.fiveMinutes.rawValue,
            Key.filterMode: FilterMode.blockList.rawValue,
            Key.mapStyle: MapStyle.satellite.rawValue,
            Key.historyRetentionDays: HistoryRetention.thirtyDays.rawValue,
            Key.isMapHidden: false,
            Key.mapPaneWidth: 760.0,
        ])
    }

    static var showInDock: Bool {
        get { defaults.bool(forKey: Key.showInDock) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    static var timeWindow: TimeWindow {
        get { TimeWindow.fromStored(defaults.object(forKey: Key.timeWindow) as? Int) }
        set { defaults.set(newValue.rawValue, forKey: Key.timeWindow) }
    }

    static var filterMode: FilterMode {
        get { defaults.string(forKey: Key.filterMode).flatMap(FilterMode.init(rawValue:)) ?? .blockList }
        set { defaults.set(newValue.rawValue, forKey: Key.filterMode) }
    }

    /// ISO country code chosen by the user for the map's home end; nil = automatic.
    static var homeCountryOverride: String? {
        get { defaults.string(forKey: Key.homeCountryOverride) }
        set { defaults.set(newValue, forKey: Key.homeCountryOverride) }
    }

    static var mapStyle: MapStyle {
        get { defaults.string(forKey: Key.mapStyle).flatMap(MapStyle.init(rawValue:)) ?? .satellite }
        set { defaults.set(newValue.rawValue, forKey: Key.mapStyle) }
    }

    static var pausedUntil: Date? {
        get { defaults.object(forKey: Key.pausedUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.pausedUntil) }
    }

    static var modeBeforePause: FilterMode? {
        get { defaults.string(forKey: Key.modeBeforePause).flatMap(FilterMode.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: Key.modeBeforePause) }
    }

    static var historyRetention: HistoryRetention {
        get { HistoryRetention(rawValue: defaults.integer(forKey: Key.historyRetentionDays)) ?? .thirtyDays }
        set { defaults.set(newValue.rawValue, forKey: Key.historyRetentionDays) }
    }

    static var hasShownOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasShownOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasShownOnboarding) }
    }

    /// The right (detail) pane is collapsed: the main window shows only the list.
    /// Keeps the key from when the pane only held the map, so that choice carries over.
    static var isDetailPaneHidden: Bool {
        get { defaults.bool(forKey: Key.isMapHidden) }
        set { defaults.set(newValue, forKey: Key.isMapHidden) }
    }

    /// Page shown in the detail pane.
    static var detailPage: DetailPageKind {
        get { DetailPageKind.fromStored(defaults.string(forKey: Key.detailPage)) }
        set { defaults.set(newValue.rawValue, forKey: Key.detailPage) }
    }

    /// Map width to restore when the map is shown again.
    static var mapPaneWidth: Double {
        get { max(360, defaults.double(forKey: Key.mapPaneWidth)) }
        set { defaults.set(newValue, forKey: Key.mapPaneWidth) }
    }

    /// IDs (UUID strings) of rules created by Disconnect.
    static var disconnectRuleIDs: [String] {
        get { defaults.stringArray(forKey: Key.disconnectRuleIDs) ?? [] }
        set { defaults.set(newValue, forKey: Key.disconnectRuleIDs) }
    }
}
