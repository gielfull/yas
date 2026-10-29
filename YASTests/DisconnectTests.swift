import YASShared
import XCTest
@testable import YAS

@MainActor
final class DisconnectTests: XCTestCase {
    private let helpers = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers"
    private lazy var chrome = identity("com.google.Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    private lazy var helper = identity("com.google.Chrome.helper", "\(helpers)/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
    private lazy var gpu = identity("com.google.Chrome.helper.GPU", "\(helpers)/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)")
    private let curl = AppIdentity(bundleID: nil, signingID: "com.apple.curl", teamID: nil,
                                   executablePath: "/usr/bin/curl", isAppleSigned: true, isValidlySigned: true)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func identity(_ signingID: String, _ path: String) -> AppIdentity {
        AppIdentity(bundleID: signingID, signingID: signingID, teamID: "EQHXZ8M8AV", executablePath: path,
                    isAppleSigned: false, isValidlySigned: true)
    }

    private func makeStore(source: FlowSource = .filter) -> Store {
        let store = Store(geo: GeoIPService(databaseURL: nil), persistsPreferences: false,
                          nameResolver: { AppIconService.appBundleURL(forExecutablePath: $0)?.deletingPathExtension().lastPathComponent
                              ?? ($0 as NSString).lastPathComponent },
                          processNameResolver: { AppIconService.processName(forExecutablePath: $0) })
        store.setSource(source)
        store.timeWindow = .all
        return store
    }

    private func flow(_ app: AppIdentity, host: String, secondsAgo: TimeInterval = 30, verdict: Verdict = .allowed) -> FlowEvent {
        FlowEvent(id: UUID(), timestamp: now.addingTimeInterval(-secondsAgo), app: app, remoteHost: host, remoteIP: "1.2.3.4",
                  remotePort: 443, proto: .tcp, direction: .outbound, verdict: verdict, matchedRuleID: nil)
    }

    // MARK: - Processes

    func testHelpersBecomeProcessesAndSingleProcessAppsDont() throws {
        let store = makeStore()
        store.ingest([
            flow(chrome, host: "www.google.com"), flow(helper, host: "www.google.com"), flow(helper, host: "github.com"),
            flow(gpu, host: "update.googleapis.com"), flow(curl, host: "example.com"),
        ])
        let apps = store.appSummaries(now: now)
        let chromeApp = try XCTUnwrap(apps.first { $0.name == "Google Chrome" })
        XCTAssertEqual(chromeApp.processes.map(\.name), ["Google Chrome", "Google Chrome Helper", "Google Chrome Helper (GPU)"])
        XCTAssertEqual(chromeApp.processes.map(\.id), [chrome.matchKey, helper.matchKey, gpu.matchKey])
        XCTAssertEqual(chromeApp.processes[1].destinations.map(\.displayHost).sorted(), ["github.com", "www.google.com"],
                       "each process has only its own destinations")
        XCTAssertEqual(chromeApp.processes[1].flowCount, 2)
        XCTAssertEqual(chromeApp.destinations.first { $0.displayHost == "www.google.com" }?.count, 2,
                       "the app row still aggregates across processes")
        let curlApp = try XCTUnwrap(apps.first { $0.name == "curl" })
        XCTAssertEqual(curlApp.processes.count, 1, "one process: the list skips the process level")
    }

    // MARK: - Disconnect / Reconnect

    func testDisconnectingAnAppBlocksEveryProcessAndLeavesOtherRulesAlone() throws {
        let store = makeStore()
        store.ingest([flow(chrome, host: "a.com"), flow(helper, host: "b.com")])
        let userDomainRule = Rule(target: .domain("ads.example", includeSubdomains: true), action: .block)
        let userAllow = Rule(target: .app(curl), action: .allow)
        store.addRule(userDomainRule)
        store.addRule(userAllow)

        let created = store.disconnect([chrome, helper], for: .untilUndone, now: now)
        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(created.allSatisfy { $0.action == .block && $0.note == Store.disconnectNote && $0.expiresAt == nil })
        XCTAssertEqual(store.disconnectRuleIDs, Set(created.map(\.id)))

        let app = try XCTUnwrap(store.appSummaries(now: now).first)
        XCTAssertNotNil(app.disconnect)
        XCTAssertEqual(app.ruleState, .blocked)
        XCTAssertTrue(app.processes.allSatisfy { $0.disconnect != nil })

        let removed = store.reconnect([chrome, helper])
        XCTAssertEqual(Set(removed.map(\.id)), Set(created.map(\.id)))
        XCTAssertEqual(store.rules.map(\.id), [userDomainRule.id, userAllow.id], "unrelated rules untouched")
        XCTAssertNil(store.appSummaries(now: now).first?.disconnect)
    }

    func testDisconnectingOneProcessBlocksOnlyIt() throws {
        let store = makeStore()
        store.ingest([flow(chrome, host: "a.com"), flow(gpu, host: "b.com")])
        store.disconnect([gpu], for: .untilUndone, now: now)
        XCTAssertEqual(store.rules.count, 1)
        let app = try XCTUnwrap(store.appSummaries(now: now).first)
        XCTAssertNil(app.disconnect, "the app isn't disconnected while its main process isn't")
        XCTAssertNil(app.processes.first { $0.id == chrome.matchKey }?.disconnect)
        XCTAssertNotNil(app.processes.first { $0.id == gpu.matchKey }?.disconnect)
        XCTAssertEqual(RuleEngine.evaluate(
            FlowDescriptor(app: chrome, host: "a.com", ip: "1.2.3.4", port: 443, proto: .tcp, direction: .outbound),
            mode: .blockList, rules: store.rules).decision, .allow)
    }

    func testReconnectKeepsAPreExistingBlockRuleAndSaysSo() throws {
        let store = makeStore()
        store.ingest([flow(curl, host: "example.com")])
        store.setAppRule(.block, for: [curl]) // the user's own rule, made earlier
        let userRuleID = try XCTUnwrap(store.rules.first?.id)
        store.disconnect([curl], for: .untilUndone, now: now)

        let status = try XCTUnwrap(store.disconnectStatus(for: [curl], now: now))
        XCTAssertEqual(status.otherBlockingRules, 1)
        XCTAssertTrue(RowStatus.controlToolTip(disconnect: status, enforcing: true).contains("1"),
                      "the Reconnect tooltip mentions the other rule")

        store.reconnect([curl])
        XCTAssertEqual(store.rules.map(\.id), [userRuleID], "Reconnect removes only its own rule")
        XCTAssertEqual(store.ruleState(for: [curl]), .blocked, "still blocked by the user's rule")
    }

    func testUndoAndRedo() {
        let store = makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false

        let before = store.disconnectRules(for: [curl])
        undo.beginUndoGrouping()
        store.disconnect([curl], for: .fifteenMinutes, now: now)
        store.registerDisconnectUndo(undo, for: [curl], restoring: before, actionName: "Disconnect curl")
        undo.endUndoGrouping()
        let created = store.rules
        XCTAssertEqual(created.count, 1)

        undo.undo()
        XCTAssertTrue(store.rules.isEmpty, "⌘Z removes exactly the Disconnect rule")
        XCTAssertTrue(store.disconnectRuleIDs.isEmpty)
        undo.redo()
        XCTAssertEqual(store.rules, created, "redo restores the same rule (same ID and expiry)")
        XCTAssertEqual(store.disconnectRuleIDs, Set(created.map(\.id)))
    }

    // MARK: - Timed

    func testTimedDurationsAndUntilTomorrowAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        XCTAssertNil(DisconnectDuration.untilUndone.expiry(from: now, calendar: calendar))
        XCTAssertEqual(DisconnectDuration.fiveMinutes.expiry(from: now, calendar: calendar), now.addingTimeInterval(300))
        XCTAssertEqual(DisconnectDuration.fifteenMinutes.expiry(from: now, calendar: calendar), now.addingTimeInterval(900))
        XCTAssertEqual(DisconnectDuration.oneHour.expiry(from: now, calendar: calendar), now.addingTimeInterval(3600))

        // Fall back (Nov 1 2026 has 25 hours): 00:30 -> next midnight is 24.5 h away.
        let fallBack = date(2026, 11, 1, 0, 30)
        XCTAssertEqual(DisconnectDuration.untilTomorrow.expiry(from: fallBack, calendar: calendar), date(2026, 11, 2, 0, 0))
        XCTAssertEqual(DisconnectDuration.untilTomorrow.expiry(from: fallBack, calendar: calendar)?.timeIntervalSince(fallBack), 24.5 * 3600)
        // Spring forward (Mar 8 2026 has 23 hours): 00:30 -> 22.5 h.
        let springForward = date(2026, 3, 8, 0, 30)
        XCTAssertEqual(DisconnectDuration.untilTomorrow.expiry(from: springForward, calendar: calendar)?.timeIntervalSince(springForward),
                       22.5 * 3600)
        // Just before midnight it's the coming midnight, not a day later.
        XCTAssertEqual(DisconnectDuration.untilTomorrow.expiry(from: date(2026, 9, 21, 23, 59), calendar: calendar),
                       date(2026, 9, 22, 0, 0))

        let store = makeStore()
        let rule = try XCTUnwrap(store.disconnect([curl], for: .untilTomorrow, now: fallBack, calendar: calendar).first)
        XCTAssertEqual(rule.expiresAt, date(2026, 11, 2, 0, 0))
    }

    func testCountdownFormatting() {
        XCTAssertEqual(DisconnectCountdown.remaining(until: now.addingTimeInterval(11 * 60 + 1), now: now), "12m")
        XCTAssertEqual(DisconnectCountdown.remaining(until: now.addingTimeInterval(15 * 60), now: now), "15m")
        XCTAssertEqual(DisconnectCountdown.remaining(until: now.addingTimeInterval(59), now: now), "<1m")
        XCTAssertEqual(DisconnectCountdown.remaining(until: now.addingTimeInterval(65 * 60), now: now), "1h 5m")
        XCTAssertEqual(DisconnectCountdown.remaining(until: now.addingTimeInterval(120 * 60), now: now), "2h")
        let status = RowStatus.make(isActive: true, ruleState: .blocked,
                                    disconnect: DisconnectStatus(expiresAt: now.addingTimeInterval(12 * 60), otherBlockingRules: 0),
                                    enforcing: true, now: now)
        XCTAssertEqual(status.text, String(localized: "Disconnected · \("12m") left"))
        XCTAssertEqual(status.tone, .blocked)
    }

    func testExpiredRulesArePurgedAndReconnectEndsEarly() throws {
        let store = makeStore()
        store.disconnect([curl], for: .fiveMinutes, now: now)
        store.purgeExpiredRules(now: now.addingTimeInterval(299))
        XCTAssertEqual(store.rules.count, 1, "not yet")
        XCTAssertNotNil(store.disconnectStatus(for: [curl], now: now.addingTimeInterval(299)))
        XCTAssertNil(store.disconnectStatus(for: [curl], now: now.addingTimeInterval(300)), "at expiry it no longer counts")
        store.purgeExpiredRules(now: now.addingTimeInterval(300))
        XCTAssertTrue(store.rules.isEmpty, "purged at expiry")
        XCTAssertTrue(store.disconnectRuleIDs.isEmpty)

        store.disconnect([curl], for: .oneHour, now: now)
        store.reconnect([curl])
        XCTAssertTrue(store.rules.isEmpty, "Reconnect ends a timed Disconnect early")
    }

    // MARK: - Status

    func testMonitorModeSaysWouldBlockNeverDisconnected() {
        let disconnected = DisconnectStatus(expiresAt: nil, otherBlockingRules: 0)
        let monitor = RowStatus.make(isActive: true, ruleState: .blocked, disconnect: disconnected, enforcing: false, now: now)
        XCTAssertEqual(monitor.text, String(localized: "Would block"))
        XCTAssertEqual(monitor.tone, .wouldBlock)
        XCTAssertTrue(monitor.dimsIcon)
        let timed = RowStatus.make(isActive: true, ruleState: .blocked,
                                   disconnect: DisconnectStatus(expiresAt: now.addingTimeInterval(600), otherBlockingRules: 0),
                                   enforcing: false, now: now)
        XCTAssertEqual(timed.text, String(localized: "Would block · \("10m") left"))
        XCTAssertTrue(RowStatus.controlToolTip(disconnect: nil, enforcing: false).contains("filter extension"))
        XCTAssertTrue(RowStatus.controlToolTip(disconnect: nil, enforcing: true).hasPrefix(String(localized: "Blocks new connections")))

        let filter = RowStatus.make(isActive: true, ruleState: .blocked, disconnect: disconnected, enforcing: true, now: now)
        XCTAssertEqual(filter.text, String(localized: "Disconnected"))
        XCTAssertEqual(filter.tone, .blocked)
    }

    func testDisconnectedAppWithBlockedAttemptsStaysListed() throws {
        let store = makeStore()
        store.timeWindow = .fiveMinutes
        store.disconnect([curl], for: .untilUndone, now: now)
        store.ingest([flow(curl, host: "example.com", secondsAgo: 20, verdict: .blocked)])
        let app = try XCTUnwrap(store.appSummaries(now: now).first, "blocked attempts count as activity")
        XCTAssertNotNil(app.disconnect)
        XCTAssertEqual(app.blockedCount, 1)
    }
}

@MainActor
final class PartialBlockTests: XCTestCase {
    func testAnAppIsBlockedOnlyWhenEveryProcessIs() {
        let main = AppIdentity(bundleID: "a", signingID: "a", teamID: "T", executablePath: "/Applications/A.app/Contents/MacOS/A",
                               isAppleSigned: false, isValidlySigned: true)
        let helper = AppIdentity(bundleID: "a.helper", signingID: "a.helper", teamID: "T",
                                 executablePath: "/Applications/A.app/Contents/Helpers/H.app/Contents/MacOS/H",
                                 isAppleSigned: false, isValidlySigned: true)
        let store = Store(geo: GeoIPService(databaseURL: nil), persistsPreferences: false) { $0 }
        store.disconnect([helper], for: .untilUndone)
        XCTAssertEqual(store.ruleState(for: [main, helper]), .none, "one disconnected helper doesn't block the app")
        XCTAssertEqual(store.ruleState(for: [helper]), .blocked)
        store.disconnect([main], for: .untilUndone)
        XCTAssertEqual(store.ruleState(for: [main, helper]), .blocked)
    }
}
