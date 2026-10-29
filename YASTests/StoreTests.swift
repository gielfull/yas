import YASShared
import XCTest
@testable import YAS

@MainActor
final class StoreTests: XCTestCase {
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

    private func makeStore() -> Store {
        let geo = GeoIPService(databaseURL: nil)
        geo.registerKnownAddress("142.250.184.228", countryCode: "US")
        geo.registerKnownAddress("140.82.121.4", countryCode: "DE")
        geo.registerKnownAddress("93.184.215.14", countryCode: "US")
        return Store(geo: geo, persistsPreferences: false) { path in
            AppIconService.appBundleURL(forExecutablePath: path)?.deletingPathExtension().lastPathComponent
                ?? (path as NSString).lastPathComponent
        }
    }

    private func flow(
        _ app: AppIdentity, host: String?, ip: String, port: Int = 443,
        at date: Date, verdict: Verdict = .allowed
    ) -> FlowEvent {
        FlowEvent(id: UUID(), timestamp: date, app: app, remoteHost: host, remoteIP: ip, remotePort: port,
                  proto: .tcp, direction: .outbound, verdict: verdict, matchedRuleID: nil)
    }

    func testHelpersAreGroupedUnderTheirAppAndDestinationsAggregate() {
        let store = makeStore()
        let now = Date()
        // All within 5 minutes, none within the 10 s "live" interval.
        store.ingest([
            flow(chrome, host: "www.google.com", ip: "142.250.184.228", at: now.addingTimeInterval(-120)),
            flow(chromeHelper, host: "www.google.com", ip: "142.250.184.228", at: now.addingTimeInterval(-100)),
            flow(chromeHelper, host: "github.com", ip: "140.82.121.4", at: now.addingTimeInterval(-90), verdict: .blocked),
            flow(chrome, host: "www.google.com", ip: "142.250.184.228", port: 80, at: now.addingTimeInterval(-60)),
        ])
        store.apply([TrafficStat(flowID: store.flows[0].id, bytesInDelta: 1000, bytesOutDelta: 200, timestamp: now.addingTimeInterval(-50))])

        let apps = store.appSummaries(now: now)
        XCTAssertEqual(apps.count, 1)
        let app = apps[0]
        XCTAssertEqual(app.name, "Google Chrome")
        XCTAssertEqual(app.identities.count, 2)
        XCTAssertEqual(app.flowCount, 4)
        XCTAssertEqual(app.blockedCount, 1)
        XCTAssertEqual(app.bytesIn, 1000)
        XCTAssertFalse(app.isActive, "nothing open and nothing in the last 10 s: Idle")

        XCTAssertEqual(app.destinations.map(\.displayHost), ["www.google.com", "www.google.com", "github.com"],
                       "most recent activity first (the stat at −50 s keeps :443 on top)")
        let google443 = app.destinations[0]
        XCTAssertEqual(google443.port, 443)
        XCTAssertEqual(google443.count, 2)
        XCTAssertEqual(google443.countryCode, "US")
        XCTAssertEqual(google443.bytesOut, 200)
        XCTAssertEqual(app.destinations[1].port, 80)
        XCTAssertEqual(app.destinations[2].countryCode, "DE")
        XCTAssertEqual(app.destinations[2].lastVerdict, .blocked)
        XCTAssertEqual(app.countryCodes, ["US", "DE"])
    }

    func testTextFilterMatchesProcessDomainIPAndCountry() {
        let store = makeStore()
        let now = Date()
        store.ingest([
            flow(chrome, host: "www.google.com", ip: "142.250.184.228", at: now),
            flow(chrome, host: "github.com", ip: "140.82.121.4", at: now),
            flow(curl, host: "example.com", ip: "93.184.215.14", at: now),
        ])

        store.filterText = "chrome"
        XCTAssertEqual(store.appSummaries(now: now).map(\.name), ["Google Chrome"])
        XCTAssertEqual(store.appSummaries(now: now)[0].destinations.count, 2, "app match keeps every destination")

        store.filterText = "GITHUB"
        var apps = store.appSummaries(now: now)
        XCTAssertEqual(apps.map(\.name), ["Google Chrome"])
        XCTAssertEqual(apps[0].destinations.map(\.displayHost), ["github.com"])

        store.filterText = "93.184"
        XCTAssertEqual(store.appSummaries(now: now).map(\.name), ["curl"])

        store.filterText = CountryCentroids.name(for: "DE")
        apps = store.appSummaries(now: now)
        XCTAssertEqual(apps.flatMap(\.destinations).map(\.displayHost), ["github.com"])

        store.filterText = "us"
        XCTAssertEqual(Set(store.appSummaries(now: now).map(\.name)), ["Google Chrome", "curl"], "country code")

        store.filterText = "nothing-matches-this"
        XCTAssertTrue(store.appSummaries(now: now).isEmpty)
    }

    func testFlowsAreCappedAtFiveThousand() {
        let store = makeStore()
        let start = Date()
        let events = (0..<(Store.maxFlows + 250)).map {
            flow(curl, host: "example.com", ip: "93.184.215.14", at: start.addingTimeInterval(Double($0)))
        }
        store.ingest(events)
        XCTAssertEqual(store.flows.count, Store.maxFlows)
        XCTAssertEqual(store.flows.first?.id, events[250].id, "oldest flows are evicted first")
    }

    func testPausedLiveUpdatesHoldFlowsUntilResumed() {
        let store = makeStore()
        store.setLiveUpdatesPaused(true)
        store.ingest([flow(curl, host: "example.com", ip: "93.184.215.14", at: Date())])
        XCTAssertTrue(store.flows.isEmpty)
        store.setLiveUpdatesPaused(false)
        XCTAssertEqual(store.flows.count, 1)
    }

    func testRuleStateAndAppRulesCoverEveryIdentity() {
        let store = makeStore()
        store.setAppRule(.block, for: [chrome, chromeHelper])
        XCTAssertEqual(store.rules.count, 2)
        XCTAssertEqual(store.ruleState(for: [chromeHelper]), .blocked)
        store.setAppRule(.allow, for: [chrome, chromeHelper])
        XCTAssertEqual(store.rules.count, 2, "replaces instead of stacking")
        XCTAssertEqual(store.ruleState(for: [chrome]), .allowed)
        store.setDomainRule(.block, domain: "Example.COM.")
        store.setDomainRule(.allow, domain: "example.com")
        XCTAssertEqual(store.rules.filter { if case .domain = $0.target { true } else { false } }.count, 1)
    }

    func testAlwaysApprovalRuleIsUpsertedByRequestID() throws {
        let store = makeStore()
        store.setMode(.requireApproval)
        let request = ApprovalRequest(
            requestID: UUID(), app: curl,
            destinations: [ApprovalDestination(host: "example.com", ip: "93.184.215.14", port: 443, proto: .tcp, count: 1)],
            firstSeen: Date())
        store.enqueueApproval(request)

        // Re-sent with the same ID and a new destination: updated in place.
        var updated = request
        updated.destinations.append(ApprovalDestination(host: "ifconfig.me", ip: "34.160.111.145", port: 443, proto: .tcp, count: 2))
        store.enqueueApproval(updated)
        XCTAssertEqual(store.pendingApprovals.count, 1)
        XCTAssertEqual(store.pendingApprovals[0].requestCount, 3)

        let rule = try XCTUnwrap(ApprovalDecision(action: .allow, scope: .always).makeRule(for: curl, id: request.requestID))
        store.upsertRule(rule)
        store.upsertRule(rule)
        XCTAssertEqual(store.rules.map(\.id), [request.requestID])
        XCTAssertTrue(store.pendingApprovals.isEmpty, "a rule that now decides the app drops its prompt")
    }

    func testLeavingRequireApprovalDropsPendingRequests() {
        let store = makeStore()
        store.setMode(.requireApproval)
        store.enqueueApproval(ApprovalRequest(requestID: UUID(), app: curl, destinations: [
            ApprovalDestination(host: "example.com", ip: "93.184.215.14", port: 443, proto: .tcp, count: 1),
        ], firstSeen: Date()))
        XCTAssertEqual(store.pendingApprovals.count, 1)
        store.setMode(.blockList)
        XCTAssertTrue(store.pendingApprovals.isEmpty)
    }

    func testRulesPersistInTheDatabase() throws {
        let database = try HistoryDatabase()
        let geo = GeoIPService(databaseURL: nil)
        let first = Store(geo: geo, rulesDatabase: database, persistsPreferences: false)
        first.setDomainRule(.block, domain: "ads.example.com")
        first.setAppRule(.allow, for: [curl])
        let second = Store(geo: geo, rulesDatabase: database, persistsPreferences: false)
        XCTAssertEqual(second.rules.map(\.id), first.rules.map(\.id), "same rules, same order")
        XCTAssertEqual(second.rules.map(\.target), first.rules.map(\.target))
    }

    func testIngestedFlowsAreRecordedAndRehydrated() async throws {
        let database = try HistoryDatabase()
        let geo = GeoIPService(databaseURL: nil)
        geo.registerKnownAddress("93.184.215.14", countryCode: "US")
        let writer = Store(geo: geo, history: database, persistsPreferences: false)
        let event = flow(curl, host: "example.com", ip: "93.184.215.14", at: Date())
        writer.ingest([event])
        writer.apply([TrafficStat(flowID: event.id, bytesInDelta: 500, bytesOutDelta: 50, timestamp: Date())])
        writer.flushHistory()

        // The write is queued off-main; wait for it.
        var stored: [FlowRecord] = []
        for _ in 0..<50 where stored.isEmpty || stored[0].bytesIn == 0 {
            stored = try database.flowsSync(matching: HistoryQuery(), limit: 10)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(stored.map(\.id), [event.id])
        XCTAssertEqual(stored.first?.country, "US")
        XCTAssertEqual(stored.first?.bytesIn, 500)

        let relaunched = Store(geo: geo, history: database, persistsPreferences: false)
        await relaunched.rehydrate()
        XCTAssertEqual(relaunched.flows.map(\.id), [event.id], "list is not empty after relaunch")
        XCTAssertEqual(relaunched.appSummaries().first?.bytesIn, 500)
    }

}
