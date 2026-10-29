import YASShared
import XCTest
@testable import YAS

final class TrafficTests: XCTestCase {
    private let chrome = AppIdentity(
        bundleID: "com.google.Chrome", signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        isAppleSigned: false, isValidlySigned: true)
    private let chromeHelper = AppIdentity(
        bundleID: "com.google.Chrome.helper", signingID: "com.google.Chrome.helper", teamID: "EQHXZ8M8AV",
        executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        isAppleSigned: false, isValidlySigned: true)
    private let curl = AppIdentity(
        bundleID: nil, signingID: "com.apple.curl", teamID: nil,
        executablePath: "/usr/bin/curl", isAppleSigned: true, isValidlySigned: true)

    /// Aligned to a 15-minute (and hour) boundary: 1_789_999_200 = 497_222 h.
    private let slot = Date(timeIntervalSince1970: 1_789_999_200)

    private func flow(_ app: AppIdentity, at date: Date, id: UUID = UUID()) -> FlowRecord {
        FlowRecord(
            event: FlowEvent(id: id, timestamp: date, app: app, remoteHost: "x.com", remoteIP: "1.1.1.1", remotePort: 443,
                             proto: .tcp, direction: .outbound, verdict: .allowed, matchedRuleID: nil),
            appName: app.executablePath, country: "US")
    }

    private func stat(_ flow: FlowRecord, minute: Double, bytesIn: UInt64, bytesOut: UInt64 = 0) -> TrafficStat {
        TrafficStat(flowID: flow.id, bytesInDelta: bytesIn, bytesOutDelta: bytesOut, timestamp: slot.addingTimeInterval(minute * 60))
    }

    // MARK: - Range aggregation

    func testSeriesSumsBucketsIntoAlignedSlotsWithBoundaries() throws {
        let database = try HistoryDatabase()
        let a = flow(chrome, at: slot)
        let b = flow(curl, at: slot)
        try database.insert([a, b])
        try database.apply([
            stat(a, minute: -1, bytesIn: 9_000),   // before the range
            stat(a, minute: 0, bytesIn: 100, bytesOut: 1), // first minute of slot 0
            stat(b, minute: 14.9, bytesIn: 20),    // last minute of slot 0
            stat(a, minute: 15, bytesIn: 300),     // first minute of slot 1
            stat(b, minute: 44, bytesIn: 4),       // slot 2
            stat(a, minute: 45, bytesIn: 7_000),   // == end: excluded
        ])
        let end = slot.addingTimeInterval(45 * 60)
        let series = try database.trafficSeriesSync(from: slot, to: end, step: 900)
        XCTAssertEqual(series.map(\.start), [slot, slot.addingTimeInterval(900), slot.addingTimeInterval(1800)])
        XCTAssertEqual(series.map(\.bytesIn), [120, 300, 4])
        XCTAssertEqual(series.map(\.bytesOut), [1, 0, 0])

        let hourly = try database.trafficSeriesSync(from: slot, to: end, step: 3600)
        XCTAssertEqual(hourly.map(\.bytesIn), [424])

        let perMinute = try database.trafficSeriesSync(from: slot, to: slot.addingTimeInterval(120), step: 60)
        XCTAssertEqual(perMinute.map(\.bytesIn), [100])
    }

    func testSeriesPerAppFilter() throws {
        let database = try HistoryDatabase()
        let a = flow(chrome, at: slot)
        let helper = flow(chromeHelper, at: slot)
        let b = flow(curl, at: slot)
        try database.insert([a, helper, b])
        try database.apply([
            stat(a, minute: 1, bytesIn: 10), stat(helper, minute: 2, bytesIn: 5), stat(b, minute: 3, bytesIn: 1_000),
        ])
        let end = slot.addingTimeInterval(3600)
        XCTAssertEqual(try database.trafficSeriesSync(from: slot, to: end, step: 3600, appKeys: [curl.matchKey]).map(\.bytesIn), [1_000])
        XCTAssertEqual(
            try database.trafficSeriesSync(from: slot, to: end, step: 3600, appKeys: [chrome.matchKey, chromeHelper.matchKey]).map(\.bytesIn),
            [15])
        XCTAssertTrue(try database.trafficSeriesSync(from: slot, to: end, step: 3600, appKeys: []).isEmpty)
    }

    func testAppTrafficForRange() throws {
        let database = try HistoryDatabase()
        let inRange = flow(chrome, at: slot.addingTimeInterval(60))
        let old = flow(curl, at: slot.addingTimeInterval(-7200))
        try database.insert([inRange, old])
        try database.apply([
            stat(inRange, minute: 2, bytesIn: 500, bytesOut: 50),
            TrafficStat(flowID: old.id, bytesInDelta: 77, bytesOutDelta: 0, timestamp: slot.addingTimeInterval(-7000)),
        ])
        let rows = try database.appTrafficSync(from: slot, to: slot.addingTimeInterval(3600))
        XCTAssertEqual(rows.map(\.identity), [chrome], "curl had no bytes and no connections in range")
        XCTAssertEqual(rows.first?.bytesIn, 500)
        XCTAssertEqual(rows.first?.bytesOut, 50)
        XCTAssertEqual(rows.first?.connections, 1)
    }

    func testFilledSeriesAddsZeroSlotsAndAlignsStart() {
        let points = [TrafficPoint(start: slot.addingTimeInterval(1800), bytesIn: 5, bytesOut: 1)]
        // Start 7 minutes into a slot: the first point is that slot's start.
        let filled = TrafficSeries.filled(points, from: slot.addingTimeInterval(420), to: slot.addingTimeInterval(3600), step: 900)
        XCTAssertEqual(filled.map(\.start), (0..<4).map { slot.addingTimeInterval(Double($0) * 900) })
        XCTAssertEqual(filled.map(\.bytesIn), [0, 0, 5, 0])
    }

    func testRangeWindowEndsAfterTheCurrentSlot() {
        let now = slot.addingTimeInterval(20 * 60 + 5)
        let (start, end) = TrafficRange.day.window(now: now)
        XCTAssertEqual(end, slot.addingTimeInterval(30 * 60))
        XCTAssertEqual(end.timeIntervalSince(start), 86_400)
        XCTAssertEqual(TrafficRange.hour.step, 60)
        XCTAssertEqual(TrafficRange.day.step, 900)
        XCTAssertEqual(TrafficRange.week.step, 3600)
    }

    // MARK: - Chart scale

    func testChartScaleUsesNiceSteps() {
        XCTAssertEqual(ChartScale.axis(forMaximum: 0), .init(upper: 1000, step: 250))
        XCTAssertEqual(ChartScale.axis(forMaximum: 950), .init(upper: 1000, step: 250))
        XCTAssertEqual(ChartScale.axis(forMaximum: 4000), .init(upper: 4000, step: 1000))
        XCTAssertEqual(ChartScale.axis(forMaximum: 1_234_567), .init(upper: 1_500_000, step: 500_000))
        XCTAssertEqual(ChartScale.axis(forMaximum: 70), .init(upper: 80, step: 20))
        let axis = ChartScale.axis(forMaximum: 1_234_567)
        XCTAssertEqual(axis.ticks, [0, 500_000, 1_000_000, 1_500_000])
        for maximum in [1.0, 37, 999, 12_345, 9_876_543, 3.3e9] {
            let axis = ChartScale.axis(forMaximum: maximum)
            XCTAssertGreaterThanOrEqual(axis.upper, maximum, "upper covers the data (\(maximum))")
            XCTAssertLessThanOrEqual(axis.ticks.count, 6, "few ticks (\(maximum))")
            XCTAssertGreaterThanOrEqual(axis.ticks.count, 2)
        }
    }

    // MARK: - Shares

    func testSharesGroupHelpersAndSumToOne() {
        let rows = [
            AppTraffic(identity: chrome, displayName: "Chrome", bytesIn: 600, bytesOut: 0, connections: 3),
            AppTraffic(identity: chromeHelper, displayName: "Helper", bytesIn: 150, bytesOut: 50, connections: 2),
            AppTraffic(identity: curl, displayName: "curl", bytesIn: 150, bytesOut: 50, connections: 1),
        ]
        let shares = TrafficShares.compute(rows, groupKey: Store.groupKey(for:)) { $0.displayName }
        XCTAssertEqual(shares.map(\.name), ["Chrome", "curl"], "helper folded into Chrome, sorted by total")
        XCTAssertEqual(shares[0].total, 800)
        XCTAssertEqual(shares[0].connections, 5)
        XCTAssertEqual(shares[0].identities.count, 2)
        XCTAssertEqual(shares[0].share, 0.8, accuracy: 1e-9)
        XCTAssertEqual(shares[1].share, 0.2, accuracy: 1e-9)
        XCTAssertEqual(shares.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
    }

    func testSharesWithNoBytesAreZeroNotNaN() {
        let rows = [AppTraffic(identity: curl, displayName: "curl", bytesIn: 0, bytesOut: 0, connections: 4)]
        let shares = TrafficShares.compute(rows, groupKey: Store.groupKey(for:)) { $0.displayName }
        XCTAssertEqual(shares.first?.share, 0)
    }

    // MARK: - Orphan stats

    func testDatabaseReportsOrphanStats() throws {
        let database = try HistoryDatabase()
        let later = flow(curl, at: slot)
        let orphans = try database.apply([stat(later, minute: 0, bytesIn: 42)])
        XCTAssertEqual(orphans.map(\.flowID), [later.id])
        XCTAssertTrue(try database.buckets(forAppKey: curl.matchKey).isEmpty)
    }

    @MainActor
    func testStatsArrivingBeforeTheirFlowAreCountedOnceTheFlowIsStored() async throws {
        let database = try HistoryDatabase()
        let store = Store(geo: GeoIPService(databaseURL: nil), history: database, persistsPreferences: false) { $0 }
        let event = FlowEvent(id: UUID(), timestamp: Date(), app: curl, remoteHost: "x.com", remoteIP: "1.1.1.1",
                              remotePort: 443, proto: .tcp, direction: .outbound, verdict: .allowed, matchedRuleID: nil)
        store.apply([TrafficStat(flowID: event.id, bytesInDelta: 4_096, bytesOutDelta: 64, timestamp: Date())])
        store.flushHistory() // stat only: it comes back as an orphan and is re-queued
        try await Task.sleep(for: .milliseconds(100))
        store.ingest([event])
        store.flushHistory()

        var stored: FlowRecord?
        for _ in 0..<100 {
            stored = try database.flowsSync(matching: HistoryQuery(), limit: 1).first
            if stored?.bytesIn == 4_096 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(stored?.bytesIn, 4_096)
        XCTAssertEqual(stored?.bytesOut, 64)
        XCTAssertEqual(try database.buckets(forAppKey: curl.matchKey).map(\.bytesIn), [4_096])
    }

    // MARK: - Store: known apps, groups, throughput

    @MainActor
    func testKnownAppsListAsIdleWithoutInMemoryFlows() async throws {
        let database = try HistoryDatabase()
        let old = flow(curl, at: Date().addingTimeInterval(-3 * 86_400))
        try database.insert([old])
        try database.apply([TrafficStat(flowID: old.id, bytesInDelta: 900, bytesOutDelta: 9, timestamp: old.timestamp)])

        let store = Store(geo: GeoIPService(databaseURL: nil), history: database, persistsPreferences: false) {
            ($0 as NSString).lastPathComponent
        }
        await store.rehydrate()
        store.clearFlows() // in-memory only; the apps table still knows curl
        XCTAssertTrue(store.appSummaries().isEmpty, "apps known only from history are listed under All only")
        store.timeWindow = .all
        let apps = store.appSummaries()
        XCTAssertEqual(apps.map(\.name), ["curl"])
        XCTAssertEqual(apps.first?.isActive, false)
        XCTAssertEqual(apps.first?.destinations.count, 0)
        XCTAssertEqual(apps.first?.bytesIn, 900)

        store.filterText = "nomatch"
        XCTAssertTrue(store.appSummaries().isEmpty, "known apps obey the filter")
    }

    @MainActor
    func testGroupIdentitiesIncludeHelpers() {
        let store = Store(geo: GeoIPService(databaseURL: nil), persistsPreferences: false) { $0 }
        store.ingest([chrome, chromeHelper, curl].map {
            FlowEvent(id: UUID(), timestamp: Date(), app: $0, remoteHost: nil, remoteIP: "1.1.1.1", remotePort: 443,
                      proto: .tcp, direction: .outbound, verdict: .allowed, matchedRuleID: nil)
        })
        XCTAssertEqual(Set(store.groupIdentities(for: chromeHelper).map(\.matchKey)), [chrome.matchKey, chromeHelper.matchKey])
        XCTAssertEqual(store.groupIdentities(for: curl).map(\.matchKey), [curl.matchKey])
        store.setAppRule(.block, for: store.groupIdentities(for: chromeHelper))
        XCTAssertEqual(store.ruleState(for: [chrome]), .blocked, "blocking from a helper row blocks the whole app")
    }

    @MainActor
    func testThroughputAveragesRecentStatsOnly() {
        let store = Store(geo: GeoIPService(databaseURL: nil), persistsPreferences: false) { $0 }
        let now = Date()
        store.apply([
            TrafficStat(flowID: UUID(), bytesInDelta: 10_000, bytesOutDelta: 500, timestamp: now),
            TrafficStat(flowID: UUID(), bytesInDelta: 999_999, bytesOutDelta: 0, timestamp: now.addingTimeInterval(-3600)),
        ], now: now)
        let rate = store.throughput(now: now)
        XCTAssertEqual(rate.bytesIn, 10_000 / Store.throughputWindow, accuracy: 0.001, "old (replayed) stats are ignored")
        XCTAssertEqual(rate.bytesOut, 500 / Store.throughputWindow, accuracy: 0.001)
        XCTAssertEqual(store.throughput(now: now.addingTimeInterval(Store.throughputWindow + 1)).bytesIn, 0)
    }
}
