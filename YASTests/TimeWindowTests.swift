import YASShared
import XCTest
@testable import YAS

/// The main list follows the time window (activity model documented in Store).
@MainActor
final class TimeWindowListTests: XCTestCase {
    private let chrome = AppIdentity(
        bundleID: "com.google.Chrome", signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        isAppleSigned: false, isValidlySigned: true)
    private let slack = AppIdentity(
        bundleID: "com.tinyspeck.slackmacgap", signingID: "com.tinyspeck.slackmacgap", teamID: "BQR82RBBHL",
        executablePath: "/Applications/Slack.app/Contents/MacOS/Slack", isAppleSigned: false, isValidlySigned: true)
    private let curl = AppIdentity(
        bundleID: nil, signingID: "com.apple.curl", teamID: nil,
        executablePath: "/usr/bin/curl", isAppleSigned: true, isValidlySigned: true)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeStore(source: FlowSource = .filter) -> Store {
        let store = Store(geo: GeoIPService(databaseURL: nil), persistsPreferences: false) {
            AppIconService.appBundleURL(forExecutablePath: $0)?.deletingPathExtension().lastPathComponent
                ?? ($0 as NSString).lastPathComponent
        }
        store.setSource(source)
        return store
    }

    private func flow(_ app: AppIdentity, host: String = "x.com", port: Int = 443, secondsAgo: TimeInterval) -> FlowEvent {
        FlowEvent(id: UUID(), timestamp: now.addingTimeInterval(-secondsAgo), app: app, remoteHost: host,
                  remoteIP: "1.2.3.4", remotePort: port, proto: .tcp, direction: .outbound, verdict: .allowed, matchedRuleID: nil)
    }

    func testCutoffBoundaryIsInclusive() {
        let store = makeStore()
        store.timeWindow = .fiveMinutes
        store.ingest([flow(chrome, secondsAgo: 300)])
        XCTAssertEqual(store.appSummaries(now: now).map(\.name), ["Google Chrome"], "exactly at the cutoff is in")
        XCTAssertTrue(store.appSummaries(now: now.addingTimeInterval(0.001)).isEmpty, "a millisecond later it's out")
    }

    func testCountsAndBytesAreScopedToTheWindow() throws {
        let store = makeStore()
        let old = flow(chrome, secondsAgo: 600)
        let recent = [flow(chrome, secondsAgo: 100), flow(chrome, secondsAgo: 50)]
        store.ingest([old] + recent)
        store.apply([
            TrafficStat(flowID: old.id, bytesInDelta: 9_000, bytesOutDelta: 0, timestamp: old.timestamp),
            TrafficStat(flowID: recent[0].id, bytesInDelta: 300, bytesOutDelta: 30, timestamp: recent[0].timestamp),
        ], now: now)

        store.timeWindow = .fiveMinutes
        let windowed = try XCTUnwrap(store.appSummaries(now: now).first)
        XCTAssertEqual(windowed.destinations.first?.count, 2, "×N counts only flows in the window")
        XCTAssertEqual(windowed.flowCount, 2)
        XCTAssertEqual(windowed.bytesIn, 300, "bytes only of in-window flows")

        store.timeWindow = .all
        let everything = try XCTUnwrap(store.appSummaries(now: now).first)
        XCTAssertEqual(everything.destinations.first?.count, 3, "All = everything in memory")
        XCTAssertEqual(everything.bytesIn, 9_300)
    }

    func testLongLivedConnectionWithRecentTrafficStaysListed() throws {
        // Filter mode: the extension reports traffic, not closes.
        let store = makeStore(source: .filter)
        let websocket = flow(slack, host: "wss-primary.slack.com", secondsAgo: 3600)
        store.ingest([websocket])
        store.timeWindow = .oneMinute
        XCTAssertTrue(store.appSummaries(now: now).isEmpty)

        store.apply([TrafficStat(flowID: websocket.id, bytesInDelta: 120, bytesOutDelta: 40, timestamp: now.addingTimeInterval(-3))], now: now)
        let app = try XCTUnwrap(store.appSummaries(now: now).first, "an hour-old websocket with traffic 3 s ago is live")
        XCTAssertTrue(app.isActive)
        XCTAssertEqual(app.destinations.first?.isLive, true)
        XCTAssertEqual(app.destinations.first?.count, 1)
    }

    func testAllListsOldActivityAndIdleApps() {
        let store = makeStore()
        store.ingest([flow(curl, secondsAgo: 7200), flow(chrome, secondsAgo: 30)])
        store.timeWindow = .oneMinute
        XCTAssertEqual(store.appSummaries(now: now).map(\.name), ["Google Chrome"], "curl had no traffic in the last minute")
        store.timeWindow = .all
        let apps = store.appSummaries(now: now)
        XCTAssertEqual(apps.map(\.name), ["Google Chrome", "curl"], "most recent activity first")
        XCTAssertEqual(apps.map(\.isActive), [false, false], "nothing open or within 10 s: both Idle")
    }

    func testSortingOpenFirstThenRecencyThenName() throws {
        let store = makeStore(source: .monitor)
        let chromeOld = flow(chrome, host: "a.com", secondsAgo: 200)
        let chromeOpen = flow(chrome, host: "z.com", secondsAgo: 250)
        let curlRecent = flow(curl, secondsAgo: 20)
        let slackOpen = flow(slack, secondsAgo: 280)
        store.ingest([chromeOld, chromeOpen, curlRecent, slackOpen], source: .monitor)
        store.setOpenFlows([chromeOpen.id, slackOpen.id], closed: [], at: now)
        store.timeWindow = .fiveMinutes

        let apps = store.appSummaries(now: now)
        XCTAssertEqual(apps.map(\.name), ["Google Chrome", "Slack", "curl"],
                       "apps with open connections first (by name), then the rest by latest activity")
        let chromeRows = try XCTUnwrap(apps.first).destinations
        XCTAssertEqual(chromeRows.map(\.displayHost), ["z.com", "a.com"], "the open destination leads, although it started earlier")
        XCTAssertEqual(chromeRows.map(\.isLive), [true, false])
    }

    func testEmptyWindowMessageIsWindowAware() {
        let store = makeStore()
        store.ingest([flow(curl, secondsAgo: 7200)])
        store.timeWindow = .oneMinute
        XCTAssertTrue(store.appSummaries(now: now).isEmpty, "the list is empty, so the empty state (with Show All) appears")
        XCTAssertEqual(TimeWindow.oneMinute.emptyMessage, String(localized: "No connections in the last minute"))
        XCTAssertNotEqual(TimeWindow.fiveMinutes.emptyMessage, TimeWindow.oneHour.emptyMessage)
        store.timeWindow = .all
        XCTAssertFalse(store.appSummaries(now: now).isEmpty)
    }

    func testStoredWindowDecodesSafely() {
        XCTAssertEqual(TimeWindow.fromStored(300), .fiveMinutes, "values stored before All existed still work")
        XCTAssertEqual(TimeWindow.fromStored(86_400), .oneDay)
        XCTAssertEqual(TimeWindow.fromStored(0), .all)
        XCTAssertEqual(TimeWindow.fromStored(42), .fiveMinutes, "unknown values fall back")
        XCTAssertEqual(TimeWindow.fromStored(nil), .fiveMinutes)
        XCTAssertNil(TimeWindow.all.duration)
        XCTAssertEqual(TimeWindow.allCases.last, .all, "All is last in the menu")

        let saved = StoredDefaults(["timeWindow"])
        defer { saved.restore() }
        Preferences.timeWindow = .all
        XCTAssertEqual(UserDefaults.standard.object(forKey: "timeWindow") as? Int, 0)
        XCTAssertEqual(Preferences.timeWindow, .all)
        UserDefaults.standard.set("garbage", forKey: "timeWindow")
        XCTAssertEqual(Preferences.timeWindow, .fiveMinutes)
    }
}
