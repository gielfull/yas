import Foundation
import GRDB
import YASShared
import os

/// Where a flow came from.
enum FlowSource: String, Sendable, CaseIterable {
    /// The filter extension (verdicts are enforced, bytes are counted).
    case filter
    /// libproc socket polling without the extension: observed only, no bytes.
    case monitor
    /// Synthetic demo data (-demo).
    case demo
}

/// One persisted flow, with the app identity joined from `apps`.
struct FlowRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let app: AppIdentity
    let appName: String
    let host: String?
    let ip: String
    let port: Int
    let proto: TransportProtocol
    let direction: FlowDirection
    let verdict: Verdict
    let matchedRuleID: UUID?
    let country: String?
    var bytesIn: UInt64
    var bytesOut: UInt64
    var source: FlowSource
    /// `host` came from a reverse DNS (PTR) lookup, not from the connection.
    var hostIsReverseDNS: Bool

    init(
        event: FlowEvent, appName: String, country: String?, bytesIn: UInt64 = 0, bytesOut: UInt64 = 0,
        source: FlowSource = .filter, hostIsReverseDNS: Bool = false
    ) {
        id = event.id
        timestamp = event.timestamp
        app = event.app
        self.appName = appName
        host = event.remoteHost
        ip = event.remoteIP
        port = event.remotePort
        proto = event.proto
        direction = event.direction
        verdict = event.verdict
        matchedRuleID = event.matchedRuleID
        self.country = country
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.source = source
        self.hostIsReverseDNS = hostIsReverseDNS
    }

    var event: FlowEvent {
        FlowEvent(
            id: id, timestamp: timestamp, app: app, remoteHost: host, remoteIP: ip, remotePort: port,
            proto: proto, direction: direction, verdict: verdict, matchedRuleID: matchedRuleID)
    }

    /// The flow as the connection reported it: a PTR-derived name is not the flow's host.
    var observedEvent: FlowEvent {
        FlowEvent(
            id: id, timestamp: timestamp, app: app, remoteHost: hostIsReverseDNS ? nil : host, remoteIP: ip,
            remotePort: port, proto: proto, direction: direction, verdict: verdict, matchedRuleID: matchedRuleID)
    }

    var displayHost: String { host ?? ip }
}

/// Filter for history queries (Connections window).
struct HistoryQuery: Hashable, Sendable {
    /// Matches app name, bundle ID, path, host, IP, country code or country name.
    var text = ""
    var verdict: Verdict?
    var since: Date?
    /// `AppIdentity.matchKey`s; nil = every app.
    var appKeys: [String]?
}

/// Paging cursor: the last row of the previous page (ordered newest first).
struct HistoryCursor: Hashable, Sendable {
    let timestamp: Date
    let id: UUID
}

/// Aggregates for the app detail header.
struct AppHistoryTotals: Hashable, Sendable {
    var connections = 0
    var blocked = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var firstSeen: Date?
    var lastSeen: Date?
}

/// An app from the `apps` table (rehydrates apps with no recent flows).
struct KnownApp: Hashable, Sendable {
    let identity: AppIdentity
    let displayName: String
    let firstSeen: Date
    let lastSeen: Date
    let flowCount: Int
    let blockedCount: Int
    let bytesIn: UInt64
    let bytesOut: UInt64
}

/// Aggregated traffic for one time slot of a chart.
struct TrafficPoint: Hashable, Sendable {
    let start: Date
    var bytesIn: UInt64
    var bytesOut: UInt64
}

/// Traffic of one app identity over a range (Traffic window table).
struct AppTraffic: Hashable, Sendable {
    let identity: AppIdentity
    let displayName: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var connections: Int

    var total: UInt64 { bytesIn &+ bytesOut }
}

struct TrafficBucket: Hashable, Sendable {
    let appKey: String
    let minute: Date
    let bytesIn: UInt64
    let bytesOut: UInt64
}

/// SQLite storage: flows, apps, per-minute traffic buckets, rules.
///
/// Writes from the Store go through `enqueue…` methods, which run on GRDB's
/// serial writer queue in submission order, off the main thread. The synchronous
/// methods are for tests, rules (small, must be durable) and maintenance.
final class HistoryDatabase: Sendable {
    let writer: any DatabaseWriter
    let url: URL?
    private let logger = Logger(subsystem: "com.gful.yas", category: "History")

    /// File-backed database (WAL).
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabasePool(path: url.path)
        self.url = url
        try Self.migrator.migrate(writer)
    }

    /// In-memory database for tests.
    init() throws {
        writer = try DatabaseQueue()
        url = nil
        try Self.migrator.migrate(writer)
    }

    static func defaultURL(fileName: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YAS", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "apps") { t in
                t.primaryKey("matchKey", .text)
                t.column("identity", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("firstSeen", .double).notNull()
                t.column("lastSeen", .double).notNull()
                t.column("flowCount", .integer).notNull().defaults(to: 0)
                t.column("blockedCount", .integer).notNull().defaults(to: 0)
                t.column("bytesIn", .integer).notNull().defaults(to: 0)
                t.column("bytesOut", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "flows") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .double).notNull()
                t.column("appKey", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("bundleID", .text)
                t.column("execPath", .text).notNull()
                t.column("host", .text)
                t.column("ip", .text).notNull()
                t.column("port", .integer).notNull()
                t.column("proto", .text).notNull()
                t.column("direction", .text).notNull()
                t.column("verdict", .text).notNull()
                t.column("matchedRuleID", .text)
                t.column("country", .text)
                t.column("bytesIn", .integer).notNull().defaults(to: 0)
                t.column("bytesOut", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "flows_timestamp", on: "flows", columns: ["timestamp"])
            try db.create(index: "flows_app", on: "flows", columns: ["appKey", "timestamp"])
            try db.create(index: "flows_host", on: "flows", columns: ["host"])
            try db.create(table: "traffic_buckets") { t in
                t.column("appKey", .text).notNull()
                t.column("minute", .integer).notNull()
                t.column("bytesIn", .integer).notNull().defaults(to: 0)
                t.column("bytesOut", .integer).notNull().defaults(to: 0)
                t.primaryKey(["appKey", "minute"])
            }
            try db.create(index: "traffic_buckets_minute", on: "traffic_buckets", columns: ["minute"])
            try db.create(table: "rules") { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                t.column("payload", .text).notNull()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2-source") { db in
            // Monitor-only flows are real but unenforced and carry no byte counts.
            try db.alter(table: "flows") { t in
                t.add(column: "source", .text).notNull().defaults(to: FlowSource.filter.rawValue)
                t.add(column: "hostSource", .text)
            }
        }
        return migrator
    }

    /// Table -> column names, plus index names, for schema tests.
    func schema() throws -> (columns: [String: [String]], indexes: Set<String>) {
        try writer.read { db in
            var columns: [String: [String]] = [:]
            var indexes: Set<String> = []
            for table in ["flows", "apps", "traffic_buckets", "rules", "meta"] {
                columns[table] = try db.columns(in: table).map(\.name)
                indexes.formUnion(try db.indexes(on: table).map(\.name))
            }
            return (columns, indexes)
        }
    }

    // MARK: - Writes

    func insert(_ flows: [FlowRecord]) throws {
        try writer.write { db in try Self.insert(flows, in: db) }
    }

    /// Returns the stats whose flow is not stored (yet); nothing is recorded for them.
    @discardableResult
    func apply(_ stats: [TrafficStat]) throws -> [TrafficStat] {
        try writer.write { db in try Self.apply(stats, in: db) }
    }

    /// Queued write, in submission order, off the calling thread.
    /// Flows are inserted before stats in the same transaction. `completion` runs
    /// on GRDB's writer queue after commit, with the stats whose flow was not
    /// stored yet (so the caller can retry them with a later batch).
    func enqueue(flows: [FlowRecord], stats: [TrafficStat], completion: (@Sendable ([TrafficStat]) -> Void)? = nil) {
        guard !flows.isEmpty || !stats.isEmpty else { return }
        let logger = logger
        writer.asyncWrite({ db in
            try Self.insert(flows, in: db)
            return try Self.apply(stats, in: db)
        }, completion: { _, result in
            switch result {
            case .success(let orphans):
                completion?(orphans)
            case .failure(let error):
                logger.error("History write failed: \(String(describing: error), privacy: .public)")
                completion?([])
            }
        })
    }

    private static func insert(_ flows: [FlowRecord], in db: Database) throws {
        for flow in flows {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO flows
                (id, timestamp, appKey, appName, bundleID, execPath, host, ip, port, proto, direction,
                 verdict, matchedRuleID, country, bytesIn, bytesOut, source, hostSource)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    flow.id.uuidString, flow.timestamp.timeIntervalSince1970, flow.app.matchKey, flow.appName,
                    flow.app.bundleID, flow.app.executablePath, flow.host, flow.ip, flow.port,
                    flow.proto.rawValue, flow.direction.rawValue, flow.verdict.rawValue,
                    flow.matchedRuleID?.uuidString, flow.country,
                    Int64(clamping: flow.bytesIn), Int64(clamping: flow.bytesOut),
                    flow.source.rawValue, flow.hostIsReverseDNS ? "ptr" : nil,
                ])
            guard db.changesCount > 0 else { continue } // duplicate
            let identity = String(decoding: try PayloadCoder.encode(flow.app), as: UTF8.self)
            try db.execute(
                sql: """
                INSERT INTO apps (matchKey, identity, displayName, firstSeen, lastSeen, flowCount, blockedCount, bytesIn, bytesOut)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(matchKey) DO UPDATE SET
                    identity = excluded.identity,
                    displayName = excluded.displayName,
                    firstSeen = min(firstSeen, excluded.firstSeen),
                    lastSeen = max(lastSeen, excluded.lastSeen),
                    flowCount = flowCount + 1,
                    blockedCount = blockedCount + excluded.blockedCount,
                    bytesIn = bytesIn + excluded.bytesIn,
                    bytesOut = bytesOut + excluded.bytesOut
                """,
                arguments: [
                    flow.app.matchKey, identity, flow.appName,
                    flow.timestamp.timeIntervalSince1970, flow.timestamp.timeIntervalSince1970,
                    flow.verdict == .blocked ? 1 : 0,
                    Int64(clamping: flow.bytesIn), Int64(clamping: flow.bytesOut),
                ])
        }
    }

    /// Adds byte deltas to the flow, its app, and the app's per-minute bucket.
    /// Returns stats for flows not (yet) stored: without the flow there is no app.
    private static func apply(_ stats: [TrafficStat], in db: Database) throws -> [TrafficStat] {
        var orphans: [TrafficStat] = []
        for stat in stats {
            let bytesIn = Int64(clamping: stat.bytesInDelta)
            let bytesOut = Int64(clamping: stat.bytesOutDelta)
            guard let appKey = try String.fetchOne(
                db, sql: "SELECT appKey FROM flows WHERE id = ?", arguments: [stat.flowID.uuidString])
            else {
                orphans.append(stat)
                continue
            }
            try db.execute(
                sql: "UPDATE flows SET bytesIn = bytesIn + ?, bytesOut = bytesOut + ? WHERE id = ?",
                arguments: [bytesIn, bytesOut, stat.flowID.uuidString])
            try db.execute(
                sql: "UPDATE apps SET bytesIn = bytesIn + ?, bytesOut = bytesOut + ? WHERE matchKey = ?",
                arguments: [bytesIn, bytesOut, appKey])
            try db.execute(
                sql: """
                INSERT INTO traffic_buckets (appKey, minute, bytesIn, bytesOut) VALUES (?, ?, ?, ?)
                ON CONFLICT(appKey, minute) DO UPDATE SET
                    bytesIn = bytesIn + excluded.bytesIn,
                    bytesOut = bytesOut + excluded.bytesOut
                """,
                arguments: [appKey, minuteStart(stat.timestamp), bytesIn, bytesOut])
        }
        return orphans
    }

    static func minuteStart(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down)) * 60
    }

    // MARK: - Retention

    /// Deletes flows before `cutoff` (a flow exactly at `cutoff` is kept), buckets
    /// for minutes that ended before it, apps not seen since, and recomputes app
    /// totals from what remains. Returns the number of flows deleted.
    @discardableResult
    func prune(before cutoff: Date) throws -> Int {
        try writer.write { db in try Self.prune(before: cutoff, in: db) }
    }

    func enqueuePrune(before cutoff: Date) {
        let logger = logger
        writer.asyncWrite({ db in try Self.prune(before: cutoff, in: db) }, completion: { _, result in
            switch result {
            case .success(let deleted): logger.info("Pruned \(deleted) flows")
            case .failure(let error): logger.error("Prune failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    private static func prune(before cutoff: Date, in db: Database) throws -> Int {
        let seconds = cutoff.timeIntervalSince1970
        try db.execute(sql: "DELETE FROM flows WHERE timestamp < ?", arguments: [seconds])
        let deleted = db.changesCount
        try db.execute(sql: "DELETE FROM traffic_buckets WHERE minute < ?", arguments: [minuteStart(cutoff)])
        try db.execute(sql: "DELETE FROM apps WHERE lastSeen < ?", arguments: [seconds])
        if deleted > 0 {
            try db.execute(sql: """
                UPDATE apps SET
                    flowCount = (SELECT count(*) FROM flows WHERE flows.appKey = apps.matchKey),
                    blockedCount = (SELECT count(*) FROM flows WHERE flows.appKey = apps.matchKey AND verdict = 'blocked'),
                    bytesIn = (SELECT coalesce(sum(bytesIn), 0) FROM flows WHERE flows.appKey = apps.matchKey),
                    bytesOut = (SELECT coalesce(sum(bytesOut), 0) FROM flows WHERE flows.appKey = apps.matchKey),
                    firstSeen = coalesce((SELECT min(timestamp) FROM flows WHERE flows.appKey = apps.matchKey), firstSeen)
                """)
        }
        return deleted
    }

    /// Fills in a reverse-DNS name for flows to `ip` that have no host yet.
    func enqueueReverseDNS(ip: String, host: String) {
        let logger = logger
        writer.asyncWrite({ db in
            try db.execute(
                sql: "UPDATE flows SET host = ?, hostSource = 'ptr' WHERE ip = ? AND host IS NULL",
                arguments: [host, ip])
        }, completion: { _, result in
            if case .failure(let error) = result {
                logger.error("Reverse DNS update failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    func applyReverseDNS(ip: String, host: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE flows SET host = ?, hostSource = 'ptr' WHERE ip = ? AND host IS NULL",
                arguments: [host, ip])
        }
    }

    /// Deletes all history (flows, apps, buckets). Rules are kept.
    func clearHistory() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM flows; DELETE FROM apps; DELETE FROM traffic_buckets;")
        }
    }

    // MARK: - Reads

    /// Newest-first page of flows matching `query`, strictly older than `cursor`.
    func flows(matching query: HistoryQuery, after cursor: HistoryCursor? = nil, limit: Int) async throws -> [FlowRecord] {
        try await writer.read { db in try Self.fetchFlows(query, cursor: cursor, limit: limit, in: db) }
    }

    func flowsSync(matching query: HistoryQuery, after cursor: HistoryCursor? = nil, limit: Int) throws -> [FlowRecord] {
        try writer.read { db in try Self.fetchFlows(query, cursor: cursor, limit: limit, in: db) }
    }

    /// The most recent `limit` flows since `since`, oldest first (Store rehydration).
    func recentFlows(limit: Int, since: Date?) async throws -> [FlowRecord] {
        let query = HistoryQuery(since: since)
        return try await flows(matching: query, limit: limit).reversed()
    }

    func totals(forAppKeys keys: [String], since: Date? = nil) async throws -> AppHistoryTotals {
        try await writer.read { db in
            var query = HistoryQuery(since: since, appKeys: keys)
            query.text = ""
            let (clause, arguments) = Self.whereClause(query)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS connections,
                       coalesce(sum(verdict = 'blocked'), 0) AS blocked,
                       coalesce(sum(bytesIn), 0) AS bytesIn,
                       coalesce(sum(bytesOut), 0) AS bytesOut,
                       min(timestamp) AS firstSeen, max(timestamp) AS lastSeen
                FROM flows \(clause)
                """, arguments: arguments)
            else { return AppHistoryTotals() }
            let firstSeen: Double? = row["firstSeen"]
            let lastSeen: Double? = row["lastSeen"]
            return AppHistoryTotals(
                connections: row["connections"],
                blocked: row["blocked"],
                bytesIn: UInt64(clamping: row["bytesIn"] as Int64),
                bytesOut: UInt64(clamping: row["bytesOut"] as Int64),
                firstSeen: firstSeen.map(Date.init(timeIntervalSince1970:)),
                lastSeen: lastSeen.map(Date.init(timeIntervalSince1970:)))
        }
    }

    func buckets(forAppKey key: String) throws -> [TrafficBucket] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM traffic_buckets WHERE appKey = ? ORDER BY minute", arguments: [key]).map {
                TrafficBucket(
                    appKey: $0["appKey"],
                    minute: Date(timeIntervalSince1970: TimeInterval($0["minute"] as Int64)),
                    bytesIn: UInt64(clamping: $0["bytesIn"] as Int64),
                    bytesOut: UInt64(clamping: $0["bytesOut"] as Int64))
            }
        }
    }

    /// (flowCount, blockedCount, bytesIn, bytesOut) from the `apps` table.
    func appRow(matchKey: String) throws -> (flows: Int, blocked: Int, bytesIn: UInt64, bytesOut: UInt64)? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM apps WHERE matchKey = ?", arguments: [matchKey]) else {
                return nil
            }
            return (row["flowCount"], row["blockedCount"],
                    UInt64(clamping: row["bytesIn"] as Int64), UInt64(clamping: row["bytesOut"] as Int64))
        }
    }

    private static func fetchFlows(_ query: HistoryQuery, cursor: HistoryCursor?, limit: Int, in db: Database) throws -> [FlowRecord] {
        var (clause, arguments) = whereClause(query)
        if let cursor {
            clause += clause.isEmpty ? "WHERE " : " AND "
            clause += "(flows.timestamp < ? OR (flows.timestamp = ? AND flows.id < ?))"
            let seconds = cursor.timestamp.timeIntervalSince1970
            arguments += [seconds, seconds, cursor.id.uuidString]
        }
        arguments += [limit]
        let rows = try Row.fetchAll(db, sql: """
            SELECT flows.*, apps.identity AS identity FROM flows
            LEFT JOIN apps ON apps.matchKey = flows.appKey
            \(clause)
            ORDER BY flows.timestamp DESC, flows.id DESC
            LIMIT ?
            """, arguments: arguments)
        return rows.compactMap(record(from:))
    }

    private static func whereClause(_ query: HistoryQuery) -> (String, StatementArguments) {
        var conditions: [String] = []
        var arguments = StatementArguments()
        if let since = query.since {
            conditions.append("flows.timestamp >= ?")
            arguments += [since.timeIntervalSince1970]
        }
        if let verdict = query.verdict {
            conditions.append("flows.verdict = ?")
            arguments += [verdict.rawValue]
        }
        if let keys = query.appKeys {
            if keys.isEmpty {
                conditions.append("0")
            } else {
                conditions.append("flows.appKey IN (\(keys.map { _ in "?" }.joined(separator: ", ")))")
                arguments += StatementArguments(keys)
            }
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let pattern = "%" + text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            var parts = ["appName", "bundleID", "execPath", "host", "ip"].map { "flows.\($0) LIKE ? ESCAPE '\\'" }
            arguments += StatementArguments(Array(repeating: pattern, count: parts.count))
            let codes = countryCodes(matching: text)
            if !codes.isEmpty {
                parts.append("flows.country IN (\(codes.map { _ in "?" }.joined(separator: ", ")))")
                arguments += StatementArguments(codes)
            }
            conditions.append("(" + parts.joined(separator: " OR ") + ")")
        }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), arguments)
    }

    /// Country codes whose code equals `text` or whose localized name contains it.
    private static func countryCodes(matching text: String) -> [String] {
        let lowered = text.lowercased()
        return CountryCentroids.all.keys.filter { code in
            code.lowercased() == lowered || CountryCentroids.name(for: code).lowercased().contains(lowered)
        }.sorted()
    }

    private static func record(from row: Row) -> FlowRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let proto = TransportProtocol(rawValue: row["proto"]),
              let direction = FlowDirection(rawValue: row["direction"]),
              let verdict = Verdict(rawValue: row["verdict"])
        else { return nil }
        let execPath: String = row["execPath"]
        let identityJSON: String? = row["identity"]
        let app = identityJSON.flatMap { try? PayloadCoder.decode(AppIdentity.self, from: Data($0.utf8)) }
            ?? AppIdentity(bundleID: row["bundleID"], signingID: nil, teamID: nil, executablePath: execPath,
                           isAppleSigned: false, isValidlySigned: false)
        let matched: String? = row["matchedRuleID"]
        let event = FlowEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: row["timestamp"]),
            app: app,
            remoteHost: row["host"],
            remoteIP: row["ip"],
            remotePort: row["port"],
            proto: proto,
            direction: direction,
            verdict: verdict,
            matchedRuleID: matched.flatMap(UUID.init(uuidString:)))
        let source: String? = row["source"]
        let hostSource: String? = row["hostSource"]
        return FlowRecord(
            event: event, appName: row["appName"], country: row["country"],
            bytesIn: UInt64(clamping: row["bytesIn"] as Int64), bytesOut: UInt64(clamping: row["bytesOut"] as Int64),
            source: source.flatMap(FlowSource.init(rawValue:)) ?? .filter,
            hostIsReverseDNS: hostSource == "ptr")
    }

    // MARK: - Counters

    /// Connections started since `connectionsSince`, and blocked ones since `blockedSince`
    /// (status menu). Two indexed counts; cheap enough to run when the menu opens.
    func counters(connectionsSince: Date, blockedSince: Date) throws -> (connections: Int, blocked: Int) {
        try writer.read { db in
            let connections = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM flows WHERE timestamp >= ?",
                arguments: [connectionsSince.timeIntervalSince1970]) ?? 0
            let blocked = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM flows WHERE timestamp >= ? AND verdict = 'blocked'",
                arguments: [blockedSince.timeIntervalSince1970]) ?? 0
            return (connections, blocked)
        }
    }

    // MARK: - Apps & traffic

    /// Apps seen since `since` (all when nil), most recent first.
    func knownApps(since: Date?) async throws -> [KnownApp] {
        try await writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM apps WHERE lastSeen >= ? ORDER BY lastSeen DESC",
                arguments: [since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude]
            ).compactMap { row in
                guard let identity = try? PayloadCoder.decode(AppIdentity.self, from: Data((row["identity"] as String).utf8)) else {
                    return nil
                }
                return KnownApp(
                    identity: identity,
                    displayName: row["displayName"],
                    firstSeen: Date(timeIntervalSince1970: row["firstSeen"]),
                    lastSeen: Date(timeIntervalSince1970: row["lastSeen"]),
                    flowCount: row["flowCount"],
                    blockedCount: row["blockedCount"],
                    bytesIn: UInt64(clamping: row["bytesIn"] as Int64),
                    bytesOut: UInt64(clamping: row["bytesOut"] as Int64))
            }
        }
    }

    /// Traffic summed into `step`-second slots aligned to multiples of `step`
    /// (epoch-based), for buckets whose minute starts in [start's minute, end).
    /// Only non-empty slots are returned; `TrafficSeries.filled` adds the gaps.
    func trafficSeries(from start: Date, to end: Date, step: Int, appKeys: [String]? = nil) async throws -> [TrafficPoint] {
        try await writer.read { db in try Self.fetchSeries(from: start, to: end, step: step, appKeys: appKeys, in: db) }
    }

    func trafficSeriesSync(from start: Date, to end: Date, step: Int, appKeys: [String]? = nil) throws -> [TrafficPoint] {
        try writer.read { db in try Self.fetchSeries(from: start, to: end, step: step, appKeys: appKeys, in: db) }
    }

    private static func fetchSeries(from start: Date, to end: Date, step: Int, appKeys: [String]?, in db: Database) throws -> [TrafficPoint] {
        precondition(step >= 60 && step % 60 == 0, "slots are whole minutes")
        var sql = "SELECT (minute / ?) * ? AS slot, sum(bytesIn) AS bytesIn, sum(bytesOut) AS bytesOut "
            + "FROM traffic_buckets WHERE minute >= ? AND minute < ?"
        var arguments: StatementArguments = [step, step, minuteStart(start), end.timeIntervalSince1970]
        if let appKeys {
            if appKeys.isEmpty {
                sql += " AND 0"
            } else {
                sql += " AND appKey IN (" + appKeys.map { _ in "?" }.joined(separator: ", ") + ")"
                arguments += StatementArguments(appKeys)
            }
        }
        sql += " GROUP BY slot ORDER BY slot"
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
            TrafficPoint(
                start: Date(timeIntervalSince1970: TimeInterval($0["slot"] as Int64)),
                bytesIn: UInt64(clamping: $0["bytesIn"] as Int64),
                bytesOut: UInt64(clamping: $0["bytesOut"] as Int64))
        }
    }

    /// Bytes per app identity for buckets in [start's minute, end), plus the
    /// connections that started in [start, end). Apps with neither are omitted.
    func appTraffic(from start: Date, to end: Date) async throws -> [AppTraffic] {
        try await writer.read { db in try Self.fetchAppTraffic(from: start, to: end, in: db) }
    }

    func appTrafficSync(from start: Date, to end: Date) throws -> [AppTraffic] {
        try writer.read { db in try Self.fetchAppTraffic(from: start, to: end, in: db) }
    }

    private static func fetchAppTraffic(from start: Date, to end: Date, in db: Database) throws -> [AppTraffic] {
        let sql = """
            SELECT apps.identity AS identity, apps.displayName AS displayName,
                   coalesce(t.bytesIn, 0) AS bytesIn, coalesce(t.bytesOut, 0) AS bytesOut,
                   coalesce(f.connections, 0) AS connections
            FROM apps
            LEFT JOIN (SELECT appKey, sum(bytesIn) AS bytesIn, sum(bytesOut) AS bytesOut FROM traffic_buckets
                       WHERE minute >= ? AND minute < ? GROUP BY appKey) t ON t.appKey = apps.matchKey
            LEFT JOIN (SELECT appKey, count(*) AS connections FROM flows
                       WHERE timestamp >= ? AND timestamp < ? GROUP BY appKey) f ON f.appKey = apps.matchKey
            WHERE t.appKey IS NOT NULL OR f.appKey IS NOT NULL
            """
        let arguments: StatementArguments = [
            minuteStart(start), end.timeIntervalSince1970, start.timeIntervalSince1970, end.timeIntervalSince1970,
        ]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            guard let identity = try? PayloadCoder.decode(AppIdentity.self, from: Data((row["identity"] as String).utf8)) else {
                return nil
            }
            return AppTraffic(
                identity: identity, displayName: row["displayName"],
                bytesIn: UInt64(clamping: row["bytesIn"] as Int64), bytesOut: UInt64(clamping: row["bytesOut"] as Int64),
                connections: row["connections"])
        }
    }

    // MARK: - Rules

    func loadRules() throws -> [Rule] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM rules ORDER BY position").compactMap {
                try? PayloadCoder.decode(Rule.self, from: Data($0.utf8))
            }
        }
    }

    func saveRules(_ rules: [Rule]) throws {
        let payloads = try rules.map { (id: $0.id.uuidString, json: String(decoding: try PayloadCoder.encode($0), as: UTF8.self)) }
        try writer.write { db in
            try db.execute(sql: "DELETE FROM rules")
            for (position, payload) in payloads.enumerated() {
                try db.execute(
                    sql: "INSERT INTO rules (id, position, payload) VALUES (?, ?, ?)",
                    arguments: [payload.id, position, payload.json])
            }
        }
    }

    /// One-time import of the pre-database `rules.json`. Imports only if it has not
    /// run before and the table is empty; the JSON file is renamed afterwards.
    /// Returns the number of rules imported.
    @discardableResult
    func importLegacyRules(from url: URL) throws -> Int {
        let alreadyImported = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'legacyRulesImported'") != nil
        }
        guard !alreadyImported else { return 0 }
        var imported = 0
        if FileManager.default.fileExists(atPath: url.path), try loadRules().isEmpty {
            let rules = try PayloadCoder.decode([Rule].self, from: Data(contentsOf: url))
            try saveRules(rules)
            imported = rules.count
            let backup = url.appendingPathExtension("imported")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: url, to: backup)
        }
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('legacyRulesImported', ?)",
                           arguments: [ISO8601DateFormatter().string(from: Date())])
        }
        return imported
    }
}
