import AppKit
import YASShared
import XCTest
@testable import YAS

final class DetailPageTests: XCTestCase {
    private let chrome = AppIdentity(
        bundleID: "com.google.Chrome", signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        isAppleSigned: false, isValidlySigned: true)
    private let chromeHelper = AppIdentity(
        bundleID: "com.google.Chrome.helper", signingID: "com.google.Chrome.helper", teamID: "EQHXZ8M8AV",
        executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        isAppleSigned: false, isValidlySigned: true)
    private let curl = AppIdentity(
        bundleID: nil, signingID: "com.apple.curl", teamID: nil,
        executablePath: "/usr/bin/curl", isAppleSigned: true, isValidlySigned: true)

    // MARK: - Page kinds and persistence

    func testPagesFollowSidebarAndShortcutOrder() {
        XCTAssertEqual(DetailPageKind.allCases, [.map, .rules, .history, .traffic, .settings])
        XCTAssertEqual(DetailPageKind.allCases.map(\.keyEquivalent), ["1", "2", "3", "4", "5"],
                       "⌘2 Rules, ⌘3 History, ⌘4 Traffic keep their old shortcuts")
        XCTAssertEqual(DetailPageKind.allCases.filter(\.followsListSelection), [.rules, .history, .traffic])
    }

    func testStoredPageFallsBackToMap() {
        XCTAssertEqual(DetailPageKind.fromStored("traffic"), .traffic)
        XCTAssertEqual(DetailPageKind.fromStored(nil), .map)
        XCTAssertEqual(DetailPageKind.fromStored("connections"), .map)
    }

    func testPaneStatePersists() {
        let saved = StoredDefaults(["detailPage", "isMapHidden"])
        defer { saved.restore() }

        UserDefaults.standard.removeObject(forKey: "detailPage")
        UserDefaults.standard.removeObject(forKey: "isMapHidden")
        Preferences.registerDefaults()
        XCTAssertEqual(DetailPaneState.load(), DetailPaneState(page: .map, isCollapsed: false))

        DetailPaneState(page: .settings, isCollapsed: true).save()
        XCTAssertEqual(UserDefaults.standard.string(forKey: "detailPage"), "settings")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "isMapHidden") as? Bool, true,
                       "the collapsed pane keeps the key of the old Hide Map setting")
        XCTAssertEqual(DetailPaneState.load(), DetailPaneState(page: .settings, isCollapsed: true))
    }

    // MARK: - Collapse behaviour with tabs

    func testSelectingAPageExpandsACollapsedPane() {
        var state = DetailPaneState(page: .map, isCollapsed: true)
        XCTAssertTrue(state.select(.history), "reports that the pane had to expand")
        XCTAssertEqual(state, DetailPaneState(page: .history, isCollapsed: false))
        XCTAssertFalse(state.select(.rules))
        XCTAssertEqual(state.page, .rules)

        state.toggleCollapsed()
        XCTAssertEqual(state, DetailPaneState(page: .rules, isCollapsed: true), "collapsing keeps the page")
        state.toggleCollapsed()
        XCTAssertFalse(state.isCollapsed)
    }

    // MARK: - Detached windows

    @MainActor
    func testDetachedRegistryKeepsOneWindowPerPage() {
        final class Window {}
        var made: [DetailPageKind] = []
        let registry = DetachedPageRegistry<Window> { kind in
            made.append(kind)
            return Window()
        }
        let traffic = registry.open(.traffic)
        XCTAssertTrue(registry.open(.traffic) === traffic, "reopening brings back the same window")
        _ = registry.open(.rules)
        XCTAssertEqual(made, [.traffic, .rules])
        XCTAssertEqual(registry.openKinds, [.traffic, .rules])

        registry.closed(.traffic)
        XCTAssertNil(registry.window(for: .traffic))
        XCTAssertFalse(registry.open(.traffic) === traffic, "a closed page opens fresh")
        XCTAssertEqual(made, [.traffic, .rules, .traffic])
    }

    // MARK: - Narrow widths

    func testHistoryColumnsDropByImportanceUntilTheyFit() {
        typealias Column = HistoryColumnPolicy.Column
        func visible(_ width: CGFloat) -> [Column] { HistoryColumnPolicy.visibleColumns(forWidth: width, spacing: 17) }
        // All seven at minimum: 644 + 7 × 17 = 763.
        XCTAssertEqual(visible(763), Column.allCases, "exactly enough keeps every column")
        XCTAssertEqual(visible(762), [.time, .app, .host, .port, .country, .verdict], "protocol merges into port first")
        // Without protocol, port needs 70: time, app, host, port, country, verdict = 604 + 102 = 706.
        XCTAssertEqual(visible(706), [.time, .app, .host, .port, .country, .verdict])
        XCTAssertEqual(visible(705), [.time, .app, .host, .port, .verdict])
        // 494 + 85 = 579.
        XCTAssertEqual(visible(579), [.time, .app, .host, .port, .verdict])
        XCTAssertEqual(visible(578), [.app, .host, .port, .verdict])
        // 366 + 68 = 434; below that only app, host, port (270 + 51 = 321) remain.
        XCTAssertEqual(visible(434), [.app, .host, .port, .verdict])
        XCTAssertEqual(visible(433), [.app, .host, .port])
        XCTAssertEqual(visible(200), [.app, .host, .port], "app, host and port always stay")
    }

    func testHistoryColumnsFitTheNarrowestPane() {
        // The pane's minimum is 360pt: whatever remains must fit it at minimum widths.
        let columns = HistoryColumnPolicy.visibleColumns(forWidth: 360, spacing: 17)
        let merged = !columns.contains(.proto)
        let needed = columns.reduce(CGFloat(0)) { $0 + HistoryColumnPolicy.minimumWidth(of: $1, protocolMerged: merged) + 17 }
        XCTAssertLessThanOrEqual(needed, 360)
    }

    func testPortMergesProtocolWhenItsColumnIsHidden() {
        XCTAssertEqual(HistoryColumnPolicy.portText(port: 443, proto: .tcp, protocolColumnVisible: true), "443")
        XCTAssertEqual(HistoryColumnPolicy.portText(port: 53, proto: .udp, protocolColumnVisible: false), "53/UDP")
    }

    // MARK: - List selection → pages

    @MainActor
    private func makeStore() -> Store {
        let store = Store(geo: GeoIPService(databaseURL: nil), persistsPreferences: false) {
            ($0 as NSString).lastPathComponent
        }
        store.ingest([chrome, chromeHelper, curl].map {
            FlowEvent(id: UUID(), timestamp: Date(), app: $0, remoteHost: nil, remoteIP: "1.1.1.1", remotePort: 443,
                      proto: .tcp, direction: .outbound, verdict: .allowed, matchedRuleID: nil)
        })
        return store
    }

    @MainActor
    private func makePane(_ store: Store) -> DetailPaneViewController {
        DetailPaneViewController(store: store) { kind in
            switch kind {
            case .rules: RulesPageController(store: store)
            case .history: HistoryPageController(store: store)
            case .traffic: TrafficPageController(store: store)
            case .map, .settings: PlaceholderPage(kind: kind)
            }
        }
    }

    @MainActor
    func testListSelectionFiltersHistoryTrafficAndRules() throws {
        let store = makeStore()
        let chromeApp = try XCTUnwrap(store.appSummaries().first { $0.identities.contains(chrome) })
        store.addRule(Rule(target: .app(chrome), action: .block))
        store.addRule(Rule(target: .appDomain(chromeHelper, "google.com"), action: .allow))
        store.addRule(Rule(target: .app(curl), action: .block))
        store.addRule(Rule(target: .domain("ads.example", includeSubdomains: true), action: .block))

        let pane = makePane(store)
        pane.show(.history)
        let history = try XCTUnwrap(pane.loadedPage(.history) as? HistoryPageController)
        XCTAssertNil(history.queryForTesting.appKeys)

        pane.setAppFilter(AppHistoryFilter(app: chromeApp))
        XCTAssertEqual(Set(history.queryForTesting.appKeys ?? []), [chrome.matchKey, chromeHelper.matchKey])

        // Pages created after the selection start filtered.
        pane.show(.traffic)
        let traffic = try XCTUnwrap(pane.loadedPage(.traffic) as? TrafficPageController)
        XCTAssertEqual(traffic.selectedAppIDForTesting, chromeApp.id)
        pane.show(.rules)
        let rules = try XCTUnwrap(pane.loadedPage(.rules) as? RulesPageController)
        XCTAssertEqual(rules.visibleRulesForTesting.count, 2, "Chrome's app and app+domain rules only")

        // Clearing the list selection shows everything again, on every page.
        pane.setAppFilter(nil)
        XCTAssertNil(history.queryForTesting.appKeys)
        XCTAssertNil(traffic.selectedAppIDForTesting)
        XCTAssertEqual(rules.visibleRulesForTesting.count, 4)
    }

    @MainActor
    func testClearingFromAPageAsksTheListToDeselect() throws {
        let store = makeStore()
        let pane = makePane(store)
        var cleared = 0
        pane.onClearAppFilter = { cleared += 1 }
        pane.show(.history)
        let history = try XCTUnwrap(pane.loadedPage(.history) as? HistoryPageController)
        history.onClearAppFilter?()
        XCTAssertEqual(cleared, 1)
    }

    func testRulesFilterExcludesGlobalDomainRules() {
        let rules = [
            Rule(target: .app(curl), action: .block),
            Rule(target: .domain("example.com", includeSubdomains: false), action: .block),
        ]
        XCTAssertEqual(RulesPageFilter.rules(rules, for: nil), rules)
    }
}

/// Stand-in for pages whose real views need MapKit or the extension manager.
@MainActor
private final class PlaceholderPage: NSViewController, DetailPage {
    let pageKind: DetailPageKind

    init(kind: DetailPageKind) {
        pageKind = kind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() { view = NSView() }
}
