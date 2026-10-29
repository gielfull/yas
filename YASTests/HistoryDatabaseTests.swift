import YASShared
import XCTest
@testable import YAS

final class HistoryDatabaseTests: XCTestCase {
    private let chrome = AppIdentity(
        bundleID: "com.google.Chrome", signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        isAppleSigned: false, isValidlySigned: true)
    private let curl = AppIdentity(
        bundleID: nil, signingID: "com.apple.curl", teamID: nil,
        executablePath: "/usr/bin/curl", isAppleSigned: true, isValidlySigned: true)

    /// Fixed base time on a minute boundary, so bucket tests are deterministic.
    private let base = Date(timeIntervalSince1970: 1_790_000_040)

    private func record(
        _ app: AppIdentity, name: String, host: String?, ip: String, at date: Date,
        verdict: Verdict = .allowed, country: String? = "US", id: UUID = UUID()
    ) -> FlowRecord {
        let event = FlowEvent(
            id: id, timestamp: date, app: app, remoteHost: host, remoteIP: ip, remotePort: 443,
            proto: .tcp, direction: .outbound, verdict: verdict, matchedRuleID: nil)
        return FlowRecord(event: event, appName: name, country: country)
    }

    // MARK: - Schema

    func testMigrationsCreateTablesColumnsAndIndexes() throws {
        let database = try HistoryDatabase()
        let schema = try database.schema()
        XCTAssertEqual(Set(schema.columns["flows"] ?? []), [
            "id", "timestamp", "appKey", "appName", "bundleID", "execPath", "host", "ip", "port", "proto",
            "direction", "verdict", "matchedRuleID", "country", "bytesIn", "bytesOut", "source", "hostSource",
        ])
        XCTAssertEqual(Set(schema.columns["apps"] ?? []), [
            "matchKey", "identity", "displayName", "firstSeen", "lastSeen", "flowCount", "blockedCount", "bytesIn", "bytesOut",
        ])
        XCTAssertEqual(Set(schema.columns["traffic_buckets"] ?? []), ["appKey", "minute", "bytesIn", "bytesOut"])
        XCTAssertEqual(Set(schema.columns["rules"] ?? []), ["id", "position", "payload"])
        XCTAssertTrue(schema.indexes.isSuperset(of: ["flows_timestamp", "flows_app", "flows_host"]), "\(schema.indexes)")
        // Migrating an already-migrated database is a no-op.
        XCTAssertNoThrow(try HistoryDatabase.migrator.migrate(database.writer))
    }

    // MARK: - Rules

    func testLegacyJSONRulesAreImportedOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appendingPathComponent("rules.json")
        let legacy = [
            Rule(target: .domain("ads.example.com", includeSubdomains: true), action: .block),
            Rule(target: .app(curl), action: .allow, isEnabled: false),
        ]
        try PayloadCoder.encode(legacy).write(to: json)

        let database = try HistoryDatabase()
        XCTAssertEqual(try database.importLegacyRules(from: json), 2)
        let loaded = try database.loadRules()
        XCTAssertEqual(loaded.map(\.id), legacy.map(\.id))
        XCTAssertEqual(loaded.map(\.target), legacy.map(\.target))
        XCTAssertEqual(loaded.map(\.isEnabled), [true, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path), "JSON is moved aside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.appendingPathExtension("imported").path))

        // A new rules.json appearing later is not imported again.
        try PayloadCoder.encode([Rule(target: .domain("other.com", includeSubdomains: true), action: .block)]).write(to: json)
        XCTAssertEqual(try database.importLegacyRules(from: json), 0)
        XCTAssertEqual(try database.loadRules().count, 2)
    }

    func testImportSkipsWhenTableAlreadyHasRules() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appendingPathComponent("rules.json")
        try PayloadCoder.encode([Rule(target: .domain("a.com", includeSubdomains: true), action: .block)]).write(to: json)

        let database = try HistoryDatabase()
        let existing = Rule(target: .domain("b.com", includeSubdomains: false), action: .allow)
        try database.saveRules([existing])
        XCTAssertEqual(try database.importLegacyRules(from: json), 0)
        XCTAssertEqual(try database.loadRules().map(\.id), [existing.id])
    }

    // MARK: - Flows

    func testBatchedInsertAndKeysetPaging() async throws {
        let database = try HistoryDatabase()
        // 250 flows one second apart, inserted in batches like the Store does.
        let records = (0..<250).map { record(curl, name: "curl", host: "h\($0).example.com", ip: "93.184.215.14", at: base.addingTimeInterval(Double($0))) }
        for batch in stride(from: 0, to: records.count, by: 60) {
            try database.insert(Array(records[batch..<min(batch + 60, records.count)]))
        }
        try database.insert([records[0]]) // duplicate IDs are ignored

        var pages: [[FlowRecord]] = []
        var cursor: HistoryCursor?
        repeat {
            let page = try await database.flows(matching: HistoryQuery(), after: cursor, limit: 100)
            pages.append(page)
            cursor = page.last.map { HistoryCursor(timestamp: $0.timestamp, id: $0.id) }
        } while pages.last?.count == 100

        XCTAssertEqual(pages.map(\.count), [100, 100, 50])
        let all = pages.flatMap { $0 }
        XCTAssertEqual(Set(all.map(\.id)).count, 250, "no row appears on two pages")
        XCTAssertEqual(all.map(\.id), records.reversed().map(\.id), "newest first")
        XCTAssertEqual(all.first?.app, curl, "identity round-trips through apps")
        XCTAssertEqual(try database.appRow(matchKey: curl.matchKey)?.flows, 250)

        let recent = try await database.recentFlows(limit: 3, since: nil)
        XCTAssertEqual(recent.map(\.id), records.suffix(3).map(\.id), "rehydration is oldest first")
    }

    func testPagingKeepsRowsThatShareATimestamp() throws {
        let database = try HistoryDatabase()
        let same = (0..<5).map { _ in record(curl, name: "curl", host: nil, ip: "1.1.1.1", at: base) }
        try database.insert(same)
        let first = try database.flowsSync(matching: HistoryQuery(), limit: 2)
        let rest = try database.flowsSync(
            matching: HistoryQuery(), after: HistoryCursor(timestamp: first[1].timestamp, id: first[1].id), limit: 10)
        XCTAssertEqual(Set((first + rest).map(\.id)), Set(same.map(\.id)))
        XCTAssertEqual(first.count + rest.count, 5)
    }

    func testTrafficBucketUpsertMath() throws {
        let database = try HistoryDatabase()
        let a = record(chrome, name: "Google Chrome", host: "a.com", ip: "1.1.1.1", at: base)
        let b = record(chrome, name: "Google Chrome", host: "b.com", ip: "1.1.1.2", at: base)
        try database.insert([a, b])
        try database.apply([
            TrafficStat(flowID: a.id, bytesInDelta: 100, bytesOutDelta: 10, timestamp: base.addingTimeInterval(5)),
            TrafficStat(flowID: b.id, bytesInDelta: 200, bytesOutDelta: 20, timestamp: base.addingTimeInterval(59)),
            TrafficStat(flowID: a.id, bytesInDelta: 1000, bytesOutDelta: 1, timestamp: base.addingTimeInterval(60)),
            TrafficStat(flowID: UUID(), bytesInDelta: 9999, bytesOutDelta: 9999, timestamp: base), // unknown flow
        ])

        let buckets = try database.buckets(forAppKey: chrome.matchKey)
        XCTAssertEqual(buckets.map(\.minute), [base, base.addingTimeInterval(60)])
        XCTAssertEqual(buckets.map(\.bytesIn), [300, 1000], "same-minute deltas add up")
        XCTAssertEqual(buckets.map(\.bytesOut), [30, 1])

        let flows = try database.flowsSync(matching: HistoryQuery(), limit: 10)
        XCTAssertEqual(flows.first { $0.id == a.id }?.bytesIn, 1100)
        XCTAssertEqual(flows.first { $0.id == b.id }?.bytesOut, 20)
        let app = try XCTUnwrap(database.appRow(matchKey: chrome.matchKey))
        XCTAssertEqual(app.bytesIn, 1300)
        XCTAssertEqual(app.bytesOut, 31)
    }

    func testRetentionPruneBoundary() throws {
        let database = try HistoryDatabase()
        let cutoff = base.addingTimeInterval(3600)
        let old = record(curl, name: "curl", host: "old.com", ip: "1.1.1.1", at: cutoff.addingTimeInterval(-0.001))
        let atCutoff = record(curl, name: "curl", host: "edge.com", ip: "1.1.1.1", at: cutoff)
        let newer = record(curl, name: "curl", host: "new.com", ip: "1.1.1.1", at: cutoff.addingTimeInterval(1))
        let gone = record(chrome, name: "Google Chrome", host: "x.com", ip: "1.1.1.1", at: base)
        try database.insert([old, atCutoff, newer, gone])
        try database.apply([
            TrafficStat(flowID: old.id, bytesInDelta: 7, bytesOutDelta: 0, timestamp: cutoff.addingTimeInterval(-61)),
            TrafficStat(flowID: atCutoff.id, bytesInDelta: 5, bytesOutDelta: 0, timestamp: cutoff),
        ])

        XCTAssertEqual(try database.prune(before: cutoff), 2)
        let remaining = try database.flowsSync(matching: HistoryQuery(), limit: 10)
        XCTAssertEqual(Set(remaining.map(\.id)), [atCutoff.id, newer.id], "a flow exactly at the cutoff is kept")
        XCTAssertEqual(try database.buckets(forAppKey: curl.matchKey).map(\.minute), [cutoff])
        XCTAssertNil(try database.appRow(matchKey: chrome.matchKey), "apps not seen since the cutoff are removed")
        let curlRow = try XCTUnwrap(database.appRow(matchKey: curl.matchKey))
        XCTAssertEqual(curlRow.flows, 2, "totals are recomputed from the remaining flows")
        XCTAssertEqual(curlRow.bytesIn, 5)

        try database.clearHistory()
        XCTAssertTrue(try database.flowsSync(matching: HistoryQuery(), limit: 10).isEmpty)
    }

    func testSearchFilterQuery() throws {
        let database = try HistoryDatabase()
        let now = base
        try database.insert([
            record(chrome, name: "Google Chrome", host: "github.com", ip: "140.82.121.4", at: now, country: "DE"),
            record(chrome, name: "Google Chrome", host: "ads.doubleclick.net", ip: "142.250.186.66", at: now.addingTimeInterval(1), verdict: .blocked),
            record(curl, name: "curl", host: nil, ip: "93.184.215.14", at: now.addingTimeInterval(-7200)),
            record(curl, name: "curl", host: "100%_real.com", ip: "10.0.0.1", at: now.addingTimeInterval(2), country: nil),
        ])
        func hosts(_ query: HistoryQuery) throws -> Set<String> {
            Set(try database.flowsSync(matching: query, limit: 100).map(\.displayHost))
        }

        XCTAssertEqual(try hosts(HistoryQuery(text: "GITHUB")), ["github.com"], "case-insensitive host")
        XCTAssertEqual(try hosts(HistoryQuery(text: "chrome")), ["github.com", "ads.doubleclick.net"], "app name")
        XCTAssertEqual(try hosts(HistoryQuery(text: "93.184")), ["93.184.215.14"], "IP")
        XCTAssertEqual(try hosts(HistoryQuery(text: CountryCentroids.name(for: "DE"))), ["github.com"], "country name")
        XCTAssertEqual(try hosts(HistoryQuery(text: "%")), ["100%_real.com"], "LIKE wildcards are escaped")
        XCTAssertEqual(try hosts(HistoryQuery(text: "_")), ["100%_real.com"])
        XCTAssertEqual(try hosts(HistoryQuery(verdict: .blocked)), ["ads.doubleclick.net"])
        XCTAssertEqual(try hosts(HistoryQuery(since: now.addingTimeInterval(-60))).count, 3, "time range")
        XCTAssertEqual(try hosts(HistoryQuery(appKeys: [curl.matchKey])), ["93.184.215.14", "100%_real.com"])
        XCTAssertTrue(try hosts(HistoryQuery(appKeys: [])).isEmpty)
        XCTAssertEqual(try hosts(HistoryQuery(text: "chrome", verdict: .allowed)), ["github.com"], "filters combine")
    }

    func testAppTotals() async throws {
        let database = try HistoryDatabase()
        let a = record(chrome, name: "Google Chrome", host: "a.com", ip: "1.1.1.1", at: base)
        let b = record(chrome, name: "Google Chrome", host: "b.com", ip: "1.1.1.1", at: base.addingTimeInterval(90), verdict: .blocked)
        try database.insert([a, b, record(curl, name: "curl", host: "c.com", ip: "1.1.1.1", at: base)])
        try database.apply([TrafficStat(flowID: a.id, bytesInDelta: 42, bytesOutDelta: 4, timestamp: base)])
        let totals = try await database.totals(forAppKeys: [chrome.matchKey])
        XCTAssertEqual(totals.connections, 2)
        XCTAssertEqual(totals.blocked, 1)
        XCTAssertEqual(totals.bytesIn, 42)
        XCTAssertEqual(totals.firstSeen, base)
        XCTAssertEqual(totals.lastSeen, base.addingTimeInterval(90))
    }
}
