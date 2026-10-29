import AppKit
import YASShared

/// The pages of the main window's right (detail) pane, in sidebar and menu order.
enum DetailPageKind: String, CaseIterable, Sendable {
    case map, rules, history, traffic, settings

    var title: String {
        switch self {
        case .map: String(localized: "Map")
        case .rules: String(localized: "Rules")
        case .history: String(localized: "History")
        case .traffic: String(localized: "Traffic")
        case .settings: String(localized: "Settings")
        }
    }

    var symbolName: String {
        switch self {
        case .map: "map"
        case .rules: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .traffic: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }

    /// ⌘1…⌘5, in the same order as the sidebar icons.
    var keyEquivalent: String {
        String((DetailPageKind.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    /// Pages that follow the app selected in the list.
    var followsListSelection: Bool {
        switch self {
        case .history, .traffic, .rules: true
        case .map, .settings: false
        }
    }

    /// Stored raw value; anything unknown falls back to the map.
    static func fromStored(_ raw: String?) -> DetailPageKind {
        raw.flatMap(DetailPageKind.init(rawValue:)) ?? .map
    }
}

/// A page hosted in the detail pane or in its own window.
@MainActor
protocol DetailPage: NSViewController {
    var pageKind: DetailPageKind { get }
    /// The app selected in the list (nil = everything). Pages that don't filter ignore it.
    func setAppFilter(_ filter: AppHistoryFilter?)
    /// Page-specific controls for the pane's top bar (e.g. the map's pause/style buttons).
    var toolbarAccessory: NSView? { get }
}

extension DetailPage {
    func setAppFilter(_ filter: AppHistoryFilter?) {}
    var toolbarAccessory: NSView? { nil }
}

/// Which page is selected and whether the pane is collapsed (pure, persisted).
struct DetailPaneState: Equatable, Sendable {
    var page: DetailPageKind
    var isCollapsed: Bool

    /// Selecting a page always shows the pane. Returns whether the pane had to expand.
    @discardableResult
    mutating func select(_ kind: DetailPageKind) -> Bool {
        page = kind
        let expanded = isCollapsed
        isCollapsed = false
        return expanded
    }

    mutating func toggleCollapsed() {
        isCollapsed.toggle()
    }

    static func load() -> DetailPaneState {
        DetailPaneState(page: Preferences.detailPage, isCollapsed: Preferences.isDetailPaneHidden)
    }

    func save() {
        Preferences.detailPage = page
        Preferences.isDetailPaneHidden = isCollapsed
    }
}

/// At most one detached window per page; reopening returns the existing one.
@MainActor
final class DetachedPageRegistry<Window: AnyObject> {
    private var windows: [DetailPageKind: Window] = [:]
    private let make: (DetailPageKind) -> Window

    init(make: @escaping (DetailPageKind) -> Window) {
        self.make = make
    }

    /// The page's window, created on first use.
    func open(_ kind: DetailPageKind) -> Window {
        if let existing = windows[kind] { return existing }
        let window = make(kind)
        windows[kind] = window
        return window
    }

    /// Call when a detached window closes so the next open makes a fresh one.
    func closed(_ kind: DetailPageKind) {
        windows[kind] = nil
    }

    func window(for kind: DetailPageKind) -> Window? { windows[kind] }
    var openKinds: Set<DetailPageKind> { Set(windows.keys) }
}

/// Which History columns fit a width (pure, tested). Narrower panes merge Protocol into
/// Port, then drop Country, then Time.
enum HistoryColumnPolicy {
    enum Column: String, CaseIterable, Sendable {
        case time, app, host, port, proto, country, verdict
    }

    /// Narrowest each column can get and still read ("Today, 12:00:00 PM", "65535/TCP",
    /// "Would block"). Port is wider once it carries the protocol too.
    static func minimumWidth(of column: Column, protocolMerged: Bool) -> CGFloat {
        switch column {
        case .time: 128
        case .app: 90
        case .host: 110
        case .port: protocolMerged ? 70 : 50
        case .proto: 60
        case .country: 110
        case .verdict: 96
        }
    }

    /// Least important first. App, Host and Port always stay.
    static let dropOrder: [Column] = [.proto, .country, .time, .verdict]

    /// Drops columns in `dropOrder` until the rest fit `width` at their minimum widths,
    /// counting `spacing` (the table's intercell spacing) per visible column.
    static func visibleColumns(forWidth width: CGFloat, spacing: CGFloat) -> [Column] {
        var columns = Column.allCases
        func required() -> CGFloat {
            let merged = !columns.contains(.proto)
            return columns.reduce(0) { $0 + minimumWidth(of: $1, protocolMerged: merged) + spacing }
        }
        for column in dropOrder where required() > width {
            columns.removeAll { $0 == column }
        }
        return columns
    }

    /// Port cell text: merged with the protocol when that column is hidden.
    static func portText(port: Int, proto: TransportProtocol, protocolColumnVisible: Bool) -> String {
        protocolColumnVisible ? "\(port)" : "\(port)/\(proto.rawValue.uppercased())"
    }
}
