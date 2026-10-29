import Foundation
import YASShared
import os

/// One destination (host or IP + port) of an app, aggregated over in-memory flows.
struct DestinationSummary: Identifiable, Hashable, Sendable {
    let id: String
    var host: String?
    var ip: String
    var port: Int
    var proto: TransportProtocol
    var countryCode: String?
    var count: Int
    var bytesIn: UInt64
    var bytesOut: UInt64
    var firstSeen: Date
    var lastSeen: Date
    var lastVerdict: Verdict
    /// A connection to this destination is open right now (see `Store` activity model).
    var isLive: Bool
    /// `host` is a reverse DNS (PTR) name, not what the app connected to.
    var hostIsReverseDNS = false
    /// Monitor-only: a rule would block this if the filter were active.
    var wouldBlock = false
    /// Identity and direction of the latest flow (for rule evaluation).
    var lastApp: AppIdentity?
    var lastDirection: FlowDirection = .outbound

    /// What the user sees and what domain rules target.
    var displayHost: String { host ?? ip }
}

/// One process of an app (a distinct identity: signing ID when trusted, else exec path).
struct ProcessSummary: Identifiable, Hashable, Sendable {
    /// `AppIdentity.matchKey`.
    let id: String
    var identity: AppIdentity
    var name: String
    var destinations: [DestinationSummary]
    var lastSeen: Date
    var flowCount: Int
    var hasOpenConnection: Bool
    var isActive: Bool
    var ruleState: AppSummary.RuleState
    /// Set while a Disconnect rule covers this process.
    var disconnect: DisconnectStatus?
}

/// One app (helpers folded into their outermost .app bundle) and its destinations.
struct AppSummary: Identifiable, Hashable, Sendable {
    enum RuleState: Hashable, Sendable {
        case none
        case allowed
        case blocked
    }

    let id: String
    var name: String
    var executablePath: String
    var identities: [AppIdentity]
    var destinations: [DestinationSummary]
    var firstSeen: Date
    var lastSeen: Date
    var flowCount: Int
    var blockedCount: Int
    var bytesIn: UInt64
    var bytesOut: UInt64
    /// Open connection now, or activity within `Store.liveInterval` ("Active" vs "Idle").
    var isActive: Bool
    /// At least one destination has a connection open right now.
    var hasOpenConnection = false
    var ruleState: RuleState
    /// Per-process breakdown; the list shows it only when there's more than one.
    var processes: [ProcessSummary] = []
    /// Set while Disconnect rules cover every process of the app.
    var disconnect: DisconnectStatus?

    /// Countries of the listed (in-window) destinations; the map draws these.
    var countryCodes: Set<String> {
        Set(destinations.compactMap(\.countryCode))
    }
}

/// App-side state: flows, rules (source of truth), mode, approvals, view options.
/// Observers listen for the `Store.*DidChange` notifications, always posted on main.
@MainActor
final class Store {
    static let flowsDidChange = Notification.Name("YAS.Store.flowsDidChange")
    /// Source (filter / monitor / demo) or monitor status changed.
    static let sourceDidChange = Notification.Name("YAS.Store.sourceDidChange")
    static let rulesDidChange = Notification.Name("YAS.Store.rulesDidChange")
    static let modeDidChange = Notification.Name("YAS.Store.modeDidChange")
    static let approvalsDidChange = Notification.Name("YAS.Store.approvalsDidChange")
    static let viewOptionsDidChange = Notification.Name("YAS.Store.viewOptionsDidChange")

    static let maxFlows = 5000

    let geo: GeoIPService
    /// Rules always live in the main database, even while demo history is attached.
    private let rulesDatabase: HistoryDatabase?
    /// Where flows are recorded; swapped for a separate file in demo mode.
    private(set) var history: HistoryDatabase?
    private var pendingFlowWrites: [FlowRecord] = []
    private var pendingStatWrites: [TrafficStat] = []
    private var historyFlushScheduled = false
    /// Bumped when history is swapped so a late rehydration can't mix databases.
    private var historyGeneration = 0
    /// Apps from the `apps` table, so apps with no in-memory flows still list (as Idle).
    private(set) var knownApps: [KnownApp] = []
    // Activity model (main list + map), used by `appSummaries`:
    // - A flow's last activity is the latest of: its start, the last time it was seen
    //   (monitor scan, or a traffic stat from the filter), and "now" while it's open.
    // - Open now: monitor mode = its socket was in the latest scan (`openFlowIDs`);
    //   filter/demo = activity within `liveInterval`, because the extension doesn't
    //   report closes.
    // - In the window: last activity >= now − window (`TimeWindow.all`: always), so a
    //   long-lived connection stays listed while it's open.
    // - A destination row is shown if any of its flows is in the window; ×N and bytes
    //   count only those flows; a green dot means a connection is open now.
    // - An app row is shown if any destination is (under All also apps known only from
    //   history). "Active" = an open connection or activity within `liveInterval`.
    // - Order: apps with an open connection first, then latest activity, then name;
    //   destinations open first, then latest activity, then host.
    static let liveInterval: TimeInterval = 10

    /// Last time each flow was seen alive (monitor scan or traffic stat).
    private var flowLastActive: [UUID: Date] = [:]
    /// Monitor mode: flows whose socket was present in the latest scan.
    private(set) var openFlowIDs: Set<UUID> = []
    /// PTR names for IPs, filled in asynchronously (monitor mode).
    private(set) var reverseDNSHosts: [String: String] = [:]

    /// Where flows come from right now.
    private(set) var source: FlowSource = .filter
    /// Monitor mode: processes whose sockets can't be read without the extension.
    private(set) var hiddenSystemProcesses = 0

    /// Verdicts are enforced (filter, or the demo's simulated filter).
    var isEnforcing: Bool { source != .monitor }
    /// Byte counts exist only with the filter (or the demo).
    var hasByteCounts: Bool { source != .monitor }

    func setSource(_ newSource: FlowSource) {
        guard newSource != source else { return }
        source = newSource
        if newSource != .monitor { hiddenSystemProcesses = 0 }
        post(Self.sourceDidChange)
        post(Self.flowsDidChange)
    }

    func setHiddenSystemProcesses(_ count: Int) {
        guard count != hiddenSystemProcesses else { return }
        hiddenSystemProcesses = count
        post(Self.sourceDidChange)
    }

    /// Monitor mode: after each scan, which flows are open and which just closed.
    func setOpenFlows(_ open: [UUID], closed: [UUID], at date: Date) {
        openFlowIDs = Set(open)
        for id in open + closed { flowLastActive[id] = date }
        if !open.isEmpty || !closed.isEmpty { scheduleFlowsNotification() }
    }

    private func isOpen(_ flow: FlowEvent, lastSeen: Date, now: Date) -> Bool {
        if source == .monitor { return openFlowIDs.contains(flow.id) }
        return lastSeen >= now.addingTimeInterval(-Self.liveInterval)
    }

    /// A reverse DNS answer for `ip`; shown for flows that have no host of their own.
    func setReverseDNSHost(_ host: String, for ip: String) {
        guard reverseDNSHosts[ip] != host else { return }
        reverseDNSHosts[ip] = host
        if reverseDNSHosts.count > 20_000 { reverseDNSHosts.removeAll() }
        history?.enqueueReverseDNS(ip: ip, host: host)
        scheduleFlowsNotification()
    }
    /// Arrival time and size of recent stats, for the live throughput readout.
    private var recentTraffic: [(date: Date, bytesIn: UInt64, bytesOut: UInt64)] = []
    static let throughputWindow: TimeInterval = 5
    private let persistsPreferences: Bool
    private let nameResolver: @MainActor (String) -> String
    private let processNameResolver: @MainActor (String) -> String
    private let logger = Logger(subsystem: "com.gful.yas", category: "Store")

    private(set) var flows: [FlowEvent] = []
    private var heldFlows: [FlowEvent] = []
    private var bytes: [UUID: (inbound: UInt64, outbound: UInt64)] = [:]
    private(set) var rules: [Rule] = []
    /// Rules created by Disconnect (Reconnect removes exactly these). Persisted.
    var disconnectRuleIDs: Set<UUID> = [] {
        didSet {
            guard disconnectRuleIDs != oldValue, persistsPreferences else { return }
            Preferences.disconnectRuleIDs = disconnectRuleIDs.map(\.uuidString).sorted()
        }
    }
    private var expiryTimer: Timer?
    private(set) var mode: FilterMode
    private(set) var pendingApprovals: [ApprovalRequest] = []
    private(set) var pausedUntil: Date?
    private var modeBeforePause: FilterMode?
    private(set) var isLiveUpdatesPaused = false
    private var flowsNotificationScheduled = false
    private var pauseTimer: Timer?

    var timeWindow: TimeWindow {
        didSet {
            guard timeWindow != oldValue else { return }
            if persistsPreferences { Preferences.timeWindow = timeWindow }
            post(Self.viewOptionsDidChange)
        }
    }

    /// Free-text filter over process, domain, IP and country.
    var filterText: String = "" {
        didSet {
            guard filterText != oldValue else { return }
            post(Self.viewOptionsDidChange)
        }
    }

    init(
        geo: GeoIPService,
        rulesDatabase: HistoryDatabase? = nil,
        history: HistoryDatabase? = nil,
        persistsPreferences: Bool = true,
        nameResolver: @escaping @MainActor (String) -> String = { AppIconService.shared.displayName(forExecutablePath: $0) },
        processNameResolver: @escaping @MainActor (String) -> String = { AppIconService.processName(forExecutablePath: $0) }
    ) {
        self.geo = geo
        self.rulesDatabase = rulesDatabase
        self.history = history
        self.persistsPreferences = persistsPreferences
        self.nameResolver = nameResolver
        self.processNameResolver = processNameResolver
        disconnectRuleIDs = persistsPreferences ? Set(Preferences.disconnectRuleIDs.compactMap(UUID.init(uuidString:))) : []
        mode = persistsPreferences ? Preferences.filterMode : .blockList
        timeWindow = persistsPreferences ? Preferences.timeWindow : .fiveMinutes
        rules = loadRules()
        if persistsPreferences { restorePause() }
        purgeExpiredRules()
        if history != nil { Task { await rehydrate() } }
    }

    /// Pre-database rules file, imported once into the `rules` table.
    static func legacyRulesURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("YAS", isDirectory: true).appendingPathComponent("rules.json")
    }

    // MARK: - Flows

    func ingest(_ events: [FlowEvent], source: FlowSource = .filter) {
        guard !events.isEmpty else { return }
        if history != nil {
            // Recorded even while the UI is paused.
            pendingFlowWrites += events.map {
                FlowRecord(
                    event: $0, appName: nameResolver($0.app.executablePath),
                    country: geo.countryCode(forIP: $0.remoteIP), source: source)
            }
            scheduleHistoryFlush()
        }
        if isLiveUpdatesPaused {
            heldFlows.append(contentsOf: events)
            if heldFlows.count > Self.maxFlows { heldFlows.removeFirst(heldFlows.count - Self.maxFlows) }
            return
        }
        flows.append(contentsOf: events)
        trimFlows()
        scheduleFlowsNotification()
    }

    func apply(_ stats: [TrafficStat], now: Date = Date()) {
        guard !stats.isEmpty else { return }
        // Live throughput counts what arrives now; replayed/seeded stats are older.
        for stat in stats where now.timeIntervalSince(stat.timestamp) < 10 {
            recentTraffic.append((now, stat.bytesInDelta, stat.bytesOutDelta))
        }
        recentTraffic.removeAll { now.timeIntervalSince($0.date) > Self.throughputWindow }
        if history != nil {
            pendingStatWrites += stats
            scheduleHistoryFlush()
        }
        for stat in stats {
            if stat.timestamp > (flowLastActive[stat.flowID] ?? .distantPast) { flowLastActive[stat.flowID] = stat.timestamp }
            var entry = bytes[stat.flowID] ?? (0, 0)
            entry.inbound &+= stat.bytesInDelta
            entry.outbound &+= stat.bytesOutDelta
            bytes[stat.flowID] = entry
        }
        if bytes.count > Self.maxFlows * 2 {
            let live = Set(flows.map(\.id)).union(heldFlows.map(\.id))
            bytes = bytes.filter { live.contains($0.key) }
        }
        if !isLiveUpdatesPaused { scheduleFlowsNotification() }
    }

    /// Average bytes per second over the last `throughputWindow` seconds.
    func throughput(now: Date = Date()) -> (bytesIn: Double, bytesOut: Double) {
        let recent = recentTraffic.filter { now.timeIntervalSince($0.date) <= Self.throughputWindow }
        let bytesIn = recent.reduce(0.0) { $0 + Double($1.bytesIn) }
        let bytesOut = recent.reduce(0.0) { $0 + Double($1.bytesOut) }
        return (bytesIn / Self.throughputWindow, bytesOut / Self.throughputWindow)
    }

    func clearFlows() {
        flowLastActive.removeAll()
        openFlowIDs.removeAll()
        flows.removeAll()
        heldFlows.removeAll()
        bytes.removeAll()
        post(Self.flowsDidChange)
    }

    // MARK: - History

    static let historyDidChange = Notification.Name("YAS.Store.historyDidChange")

    /// Records flows in `database` from now on and rehydrates the in-memory flows
    /// from it (most recent `maxFlows` within the retention period).
    func attachHistory(_ database: HistoryDatabase?) {
        flushHistory()
        history = database
        historyGeneration += 1
        knownApps.removeAll()
        flowLastActive.removeAll()
        openFlowIDs.removeAll()
        flows.removeAll()
        heldFlows.removeAll()
        bytes.removeAll()
        post(Self.flowsDidChange)
        post(Self.historyDidChange)
        Task { await rehydrate() }
    }

    /// Loads recent flows from history, merging with anything that arrived meanwhile.
    func rehydrate() async {
        guard let history else { return }
        let generation = historyGeneration
        let since = persistsPreferences ? Date().addingTimeInterval(-Preferences.historyRetention.duration) : nil
        let records: [FlowRecord]
        let apps: [KnownApp]
        do {
            records = try await history.recentFlows(limit: Self.maxFlows, since: since)
            apps = try await history.knownApps(since: since)
        } catch {
            logger.error("Rehydration failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard generation == historyGeneration else { return }
        knownApps = apps
        guard !records.isEmpty else {
            post(Self.flowsDidChange)
            return
        }
        let live = Set(flows.map(\.id))
        let loaded = records.filter { !live.contains($0.id) }
        for record in loaded where bytes[record.id] == nil && (record.bytesIn > 0 || record.bytesOut > 0) {
            bytes[record.id] = (record.bytesIn, record.bytesOut)
        }
        for record in loaded where record.hostIsReverseDNS {
            if let host = record.host, reverseDNSHosts[record.ip] == nil { reverseDNSHosts[record.ip] = host }
        }
        flows = (loaded.map(\.observedEvent) + flows).sorted { $0.timestamp < $1.timestamp }
        trimFlows()
        post(Self.flowsDidChange)
    }

    /// Writes buffered flows and stats now (normally every 250 ms).
    func flushHistory() {
        guard let history else { return }
        let flowWrites = pendingFlowWrites
        let statWrites = pendingStatWrites
        pendingFlowWrites.removeAll()
        pendingStatWrites.removeAll()
        history.enqueue(flows: flowWrites, stats: statWrites) { [weak self] orphans in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.historyWriteFinished(in: history, orphans: orphans) }
            }
        }
    }

    /// Stats can arrive before their flow; keep retrying them with later batches
    /// (flows are inserted first in each transaction) for up to a minute.
    static let orphanStatLifetime: TimeInterval = 60

    private func historyWriteFinished(in database: HistoryDatabase, orphans: [TrafficStat]) {
        post(Self.historyDidChange)
        guard database === history, !orphans.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Self.orphanStatLifetime)
        let retry = orphans.filter { $0.timestamp >= cutoff }
        guard !retry.isEmpty else { return }
        pendingStatWrites.insert(contentsOf: retry, at: 0)
        scheduleHistoryFlush()
    }

    private func scheduleHistoryFlush() {
        guard !historyFlushScheduled else { return }
        historyFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.historyFlushScheduled = false
            self.flushHistory()
        }
    }

    /// Deletes history older than the retention setting.
    func pruneHistory(now: Date = Date()) {
        history?.enqueuePrune(before: now.addingTimeInterval(-Preferences.historyRetention.duration))
    }

    /// Deletes all recorded history and the in-memory flows. Rules are kept.
    func clearHistory() throws {
        pendingFlowWrites.removeAll()
        pendingStatWrites.removeAll()
        try history?.clearHistory()
        knownApps.removeAll()
        clearFlows()
        post(Self.historyDidChange)
    }

    /// Freezes what the UI shows; flows keep arriving and are merged on resume.
    func setLiveUpdatesPaused(_ paused: Bool) {
        guard paused != isLiveUpdatesPaused else { return }
        isLiveUpdatesPaused = paused
        if !paused, !heldFlows.isEmpty {
            flows.append(contentsOf: heldFlows)
            heldFlows.removeAll()
            trimFlows()
        }
        post(Self.flowsDidChange)
    }

    private func trimFlows() {
        guard flows.count > Self.maxFlows else { return }
        let evicted = flows.prefix(flows.count - Self.maxFlows)
        for flow in evicted {
            bytes[flow.id] = nil
            flowLastActive[flow.id] = nil
            openFlowIDs.remove(flow.id)
        }
        flows.removeFirst(evicted.count)
    }

    private func scheduleFlowsNotification() {
        guard !flowsNotificationScheduled else { return }
        flowsNotificationScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.flowsNotificationScheduled = false
            self.post(Self.flowsDidChange)
        }
    }

    // MARK: - Aggregation

    /// Apps and destinations with activity in the time window, matching `filterText`
    /// (see the activity model above).
    func appSummaries(now: Date = Date()) -> [AppSummary] {
        let cutoff = timeWindow.duration.map { now.addingTimeInterval(-$0) }
        let liveCutoff = now.addingTimeInterval(-Self.liveInterval)
        var groups: [String: AppSummary] = [:]
        var destinationIndex: [String: [String: Int]] = [:]
        // groupKey -> matchKey -> process, and its destination index.
        var processes: [String: [String: ProcessSummary]] = [:]
        var processDestinationIndex: [String: [String: Int]] = [:]

        for flow in flows {
            let seen = max(flow.timestamp, flowLastActive[flow.id] ?? flow.timestamp)
            let open = isOpen(flow, lastSeen: seen, now: now)
            let lastActivity = open ? max(seen, now) : seen
            if let cutoff, lastActivity < cutoff { continue }

            let key = Self.groupKey(for: flow.app)
            let flowBytes = bytes[flow.id] ?? (0, 0)
            let reverseHost = flow.remoteHost == nil ? reverseDNSHosts[flow.remoteIP] : nil
            let host = flow.remoteHost ?? reverseHost

            var app = groups[key] ?? AppSummary(
                id: key,
                name: nameResolver(flow.app.executablePath),
                executablePath: flow.app.executablePath,
                identities: [],
                destinations: [],
                firstSeen: flow.timestamp,
                lastSeen: lastActivity,
                flowCount: 0,
                blockedCount: 0,
                bytesIn: 0,
                bytesOut: 0,
                isActive: false,
                ruleState: .none
            )
            if !app.identities.contains(where: { $0.matchKey == flow.app.matchKey }) {
                app.identities.append(flow.app)
            }
            app.firstSeen = min(app.firstSeen, flow.timestamp)
            app.lastSeen = max(app.lastSeen, lastActivity)
            app.flowCount += 1
            app.blockedCount += flow.verdict == .blocked ? 1 : 0
            app.bytesIn &+= flowBytes.inbound
            app.bytesOut &+= flowBytes.outbound
            app.hasOpenConnection = app.hasOpenConnection || open

            let destinationKey = "\(host ?? flow.remoteIP)|\(flow.remotePort)"
            if let index = destinationIndex[key]?[destinationKey] {
                var destination = app.destinations[index]
                destination.count += 1
                destination.bytesIn &+= flowBytes.inbound
                destination.bytesOut &+= flowBytes.outbound
                destination.isLive = destination.isLive || open
                if lastActivity >= destination.lastSeen {
                    destination.lastSeen = lastActivity
                    destination.lastVerdict = flow.verdict
                    destination.ip = flow.remoteIP
                    destination.lastApp = flow.app
                    destination.lastDirection = flow.direction
                }
                destination.firstSeen = min(destination.firstSeen, flow.timestamp)
                app.destinations[index] = destination
            } else {
                destinationIndex[key, default: [:]][destinationKey] = app.destinations.count
                app.destinations.append(DestinationSummary(
                    id: destinationKey,
                    host: host,
                    ip: flow.remoteIP,
                    port: flow.remotePort,
                    proto: flow.proto,
                    countryCode: geo.countryCode(forIP: flow.remoteIP),
                    count: 1,
                    bytesIn: flowBytes.inbound,
                    bytesOut: flowBytes.outbound,
                    firstSeen: flow.timestamp,
                    lastSeen: lastActivity,
                    lastVerdict: flow.verdict,
                    isLive: open,
                    hostIsReverseDNS: reverseHost != nil,
                    lastApp: flow.app,
                    lastDirection: flow.direction
                ))
            }
            groups[key] = app

            // Same flow, per process.
            let processKey = flow.app.matchKey
            var process = processes[key]?[processKey] ?? ProcessSummary(
                id: processKey, identity: flow.app, name: processNameResolver(flow.app.executablePath),
                destinations: [], lastSeen: lastActivity, flowCount: 0, hasOpenConnection: false,
                isActive: false, ruleState: .none)
            process.lastSeen = max(process.lastSeen, lastActivity)
            process.flowCount += 1
            process.hasOpenConnection = process.hasOpenConnection || open
            let processDestinationKey = "\(key)|\(processKey)"
            if let index = processDestinationIndex[processDestinationKey]?[destinationKey] {
                var destination = process.destinations[index]
                destination.count += 1
                destination.bytesIn &+= flowBytes.inbound
                destination.bytesOut &+= flowBytes.outbound
                destination.isLive = destination.isLive || open
                if lastActivity >= destination.lastSeen {
                    destination.lastSeen = lastActivity
                    destination.lastVerdict = flow.verdict
                    destination.ip = flow.remoteIP
                    destination.lastApp = flow.app
                    destination.lastDirection = flow.direction
                }
                destination.firstSeen = min(destination.firstSeen, flow.timestamp)
                process.destinations[index] = destination
            } else if let appIndex = destinationIndex[key]?[destinationKey] {
                // Start from this flow's own contribution (the app row already merged it).
                var destination = app.destinations[appIndex]
                destination.count = 1
                destination.bytesIn = flowBytes.inbound
                destination.bytesOut = flowBytes.outbound
                destination.isLive = open
                destination.firstSeen = flow.timestamp
                destination.lastSeen = lastActivity
                destination.lastVerdict = flow.verdict
                destination.ip = flow.remoteIP
                destination.lastApp = flow.app
                destination.lastDirection = flow.direction
                processDestinationIndex[processDestinationKey, default: [:]][destinationKey] = process.destinations.count
                process.destinations.append(destination)
            }
            processes[key, default: [:]][processKey] = process
        }

        // Under All, apps known from history but with no in-memory flows (e.g. after relaunch).
        if timeWindow == .all {
            for known in knownApps {
                let key = Self.groupKey(for: known.identity)
                if var app = groups[key] {
                    if !app.identities.contains(where: { $0.matchKey == known.identity.matchKey }) {
                        app.identities.append(known.identity)
                        groups[key] = app
                    }
                    continue
                }
                groups[key] = AppSummary(
                    id: key,
                    name: nameResolver(known.identity.executablePath),
                    executablePath: known.identity.executablePath,
                    identities: [known.identity],
                    destinations: [],
                    firstSeen: known.firstSeen,
                    lastSeen: known.lastSeen,
                    flowCount: known.flowCount,
                    blockedCount: known.blockedCount,
                    bytesIn: known.bytesIn,
                    bytesOut: known.bytesOut,
                    isActive: false,
                    ruleState: .none)
            }
        }

        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [AppSummary] = []
        for var app in groups.values {
            if !isEnforcing {
                for index in app.destinations.indices {
                    app.destinations[index].wouldBlock = wouldBlock(app.destinations[index])
                }
            }
            app.isActive = app.hasOpenConnection || app.lastSeen >= liveCutoff
            app.ruleState = ruleState(for: app.identities)
            app.disconnect = disconnectStatus(for: app.identities, now: now)
            app.processes = (processes[app.id] ?? [:]).values.map { process in
                var process = process
                process.isActive = process.hasOpenConnection || process.lastSeen >= liveCutoff
                process.ruleState = ruleState(for: [process.identity])
                process.disconnect = disconnectStatus(for: [process.identity], now: now)
                if !isEnforcing {
                    for index in process.destinations.indices {
                        process.destinations[index].wouldBlock = wouldBlock(process.destinations[index])
                    }
                }
                process.destinations.sort { lhs, rhs in
                    if lhs.isLive != rhs.isLive { return lhs.isLive }
                    if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                    return lhs.displayHost.localizedStandardCompare(rhs.displayHost) == .orderedAscending
                }
                return process
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            app.destinations.sort { lhs, rhs in
                if lhs.isLive != rhs.isLive { return lhs.isLive }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.displayHost.localizedStandardCompare(rhs.displayHost) == .orderedAscending
            }

            if !query.isEmpty, !appMatches(app, query: query) {
                guard !app.destinations.isEmpty else { continue }
                app.destinations = app.destinations.filter { destinationMatches($0, query: query) }
                if app.destinations.isEmpty { continue }
                app.processes = app.processes.compactMap { process in
                    var process = process
                    process.destinations = process.destinations.filter { destinationMatches($0, query: query) }
                    return process.destinations.isEmpty ? nil : process
                }
            }
            result.append(app)
        }
        result.sort { lhs, rhs in
            if lhs.hasOpenConnection != rhs.hasOpenConnection { return lhs.hasOpenConnection }
            // Open apps are all "active now": keep them in a stable, alphabetical order.
            if !lhs.hasOpenConnection, lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
        return result
    }

    /// Groups helper processes with their app: outermost .app bundle path, else the rule match key.
    nonisolated static func groupKey(for app: AppIdentity) -> String {
        if let bundle = AppIconService.appBundleURL(forExecutablePath: app.executablePath) {
            return "bundle:\(bundle.path)"
        }
        return app.matchKey
    }

    /// Monitor mode: whether the current rules and mode would block this destination.
    func wouldBlock(_ destination: DestinationSummary) -> Bool {
        guard let app = destination.lastApp else { return false }
        // PTR names aren't what the filter would match on (it sees SNI / DNS answers).
        return wouldBlock(app: app, host: destination.hostIsReverseDNS ? nil : destination.host, ip: destination.ip,
                          port: destination.port, proto: destination.proto, direction: destination.lastDirection)
    }

    func wouldBlock(_ record: FlowRecord) -> Bool {
        wouldBlock(app: record.app, host: record.hostIsReverseDNS ? nil : record.host, ip: record.ip,
                   port: record.port, proto: record.proto, direction: record.direction)
    }

    private func wouldBlock(
        app: AppIdentity, host: String?, ip: String, port: Int, proto: TransportProtocol, direction: FlowDirection
    ) -> Bool {
        let flow = FlowDescriptor(app: app, host: host, ip: ip, port: port, proto: proto, direction: direction)
        return RuleEngine.evaluate(flow, mode: mode, rules: rules, hostIsFinal: true).decision == .block
    }

    /// Every identity grouped with `app` (helpers and their parent), from memory and history.
    func groupIdentities(for app: AppIdentity) -> [AppIdentity] {
        let key = Self.groupKey(for: app)
        var result = [app]
        var seen: Set<String> = [app.matchKey]
        for identity in flows.map(\.app) + knownApps.map(\.identity)
        where Self.groupKey(for: identity) == key && seen.insert(identity.matchKey).inserted {
            result.append(identity)
        }
        return result
    }

    private func appMatches(_ app: AppSummary, query: String) -> Bool {
        if app.name.lowercased().contains(query) { return true }
        if app.executablePath.lowercased().contains(query) { return true }
        return app.identities.contains { ($0.bundleID ?? "").lowercased().contains(query) }
    }

    private func destinationMatches(_ destination: DestinationSummary, query: String) -> Bool {
        if (destination.host ?? "").lowercased().contains(query) { return true }
        if destination.ip.lowercased().contains(query) { return true }
        guard let code = destination.countryCode else { return false }
        return code.lowercased() == query || CountryCentroids.name(for: code).lowercased().contains(query)
    }

    /// Connections seen in the last hour (in-memory flows only).
    func connectionCount(since date: Date) -> Int {
        flows.reduce(0) { $0 + ($1.timestamp >= date ? 1 : 0) }
    }

    func blockedCount(since date: Date) -> Int {
        flows.reduce(0) { $0 + ($1.timestamp >= date && $1.verdict == .blocked ? 1 : 0) }
    }

    // MARK: - Rules

    /// Blocked only when every identity has an app block rule in effect (an app with
    /// one disconnected helper isn't blocked); allowed when any has an allow rule.
    func ruleState(for identities: [AppIdentity]) -> AppSummary.RuleState {
        let keys = Set(identities.map(\.matchKey))
        guard !keys.isEmpty else { return .none }
        let now = Date()
        var blocked: Set<String> = []
        var allowed = false
        for rule in rules where rule.isInEffect(at: now) {
            guard case .app(let identity) = rule.target, keys.contains(identity.matchKey) else { continue }
            if rule.action == .block { blocked.insert(identity.matchKey) } else { allowed = true }
        }
        if keys.isSubset(of: blocked) { return .blocked }
        return allowed ? .allowed : .none
    }


    func addRule(_ rule: Rule) {
        upsertRule(rule)
    }

    /// Inserts `rule`, or replaces the rule with the same ID. The extension
    /// persists "always" approval rules with `id == requestID`, so the app must
    /// store the identical rule exactly once.
    func upsertRule(_ rule: Rule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        rulesChanged()
    }

    func replaceAllRules(_ newRules: [Rule]) {
        rules = newRules
        rulesChanged()
    }

    /// Adds rules whose IDs are not present yet. Returns how many were added.
    @discardableResult
    func mergeRules(_ imported: [Rule]) -> Int {
        let existing = Set(rules.map(\.id))
        let added = imported.filter { !existing.contains($0.id) }
        guard !added.isEmpty else { return 0 }
        rules.append(contentsOf: added)
        rulesChanged()
        return added.count
    }

    func removeRules(ids: Set<UUID>) {
        let before = rules.count
        rules.removeAll { ids.contains($0.id) }
        if rules.count != before { rulesChanged() }
    }

    /// Nil makes the rule permanent.
    func setRuleExpiry(_ id: UUID, to expiry: Date?) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].expiresAt != expiry else { return }
        updateRules { $0[index].expiresAt = expiry }
    }

    func setRule(_ id: UUID, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].isEnabled != enabled else { return }
        rules[index].isEnabled = enabled
        rulesChanged()
    }

    /// Replaces any whole-app rules for these identities with one `action` rule each.
    func setAppRule(_ action: RuleAction, for identities: [AppIdentity]) {
        let keys = Set(identities.map(\.matchKey))
        rules.removeAll { rule in
            if case .app(let identity) = rule.target { return keys.contains(identity.matchKey) }
            return false
        }
        var seen = Set<String>()
        for identity in identities where seen.insert(identity.matchKey).inserted {
            rules.append(Rule(target: .app(identity), action: action))
        }
        rulesChanged()
    }

    /// Replaces any global rule for exactly this domain.
    func setDomainRule(_ action: RuleAction, domain: String) {
        let normalized = DomainMatcher.normalize(domain)
        guard !normalized.isEmpty else { return }
        rules.removeAll { rule in
            if case .domain(let existing, _) = rule.target { return DomainMatcher.normalize(existing) == normalized }
            return false
        }
        rules.append(Rule(target: .domain(normalized, includeSubdomains: true), action: action))
        rulesChanged()
    }

    /// Changes the rule set and persists/pushes it (used by the Disconnect extension).
    func updateRules(_ change: (inout [Rule]) -> Void) {
        change(&rules)
        rulesChanged()
    }

    private func rulesChanged() {
        let ids = Set(rules.map(\.id))
        if !disconnectRuleIDs.isSubset(of: ids) { disconnectRuleIDs.formIntersection(ids) }
        saveRules()
        post(Self.rulesDidChange)
        dropDecidedApprovals()
        scheduleExpiryPurge()
    }

    /// Removes rules whose `expiresAt` has passed. The extension already ignores them
    /// (it evaluates with the current time); this keeps the list and the pushed set tidy.
    func purgeExpiredRules(now: Date = Date()) {
        guard rules.contains(where: { ($0.expiresAt ?? .distantFuture) <= now }) else {
            scheduleExpiryPurge(now: now)
            return
        }
        updateRules { $0.removeAll { ($0.expiresAt ?? .distantFuture) <= now } }
    }

    private func scheduleExpiryPurge(now: Date = Date()) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let next = rules.compactMap(\.expiresAt).filter({ $0 > now }).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.purgeExpiredRules() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func loadRules() -> [Rule] {
        guard let rulesDatabase else { return [] }
        do {
            return try rulesDatabase.loadRules()
        } catch {
            logger.error("Could not load rules: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Synchronous: rules are small and must survive a crash right after a change.
    private func saveRules() {
        guard let rulesDatabase else { return }
        do {
            try rulesDatabase.saveRules(rules)
        } catch {
            logger.error("Could not save rules: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Mode

    func setMode(_ newMode: FilterMode) {
        if pausedUntil != nil { cancelPause(restoring: false) }
        applyMode(newMode)
    }

    /// Switches to Allow All for `duration`, then restores the previous mode.
    func pauseFiltering(for duration: TimeInterval) {
        let previous = pausedUntil == nil ? mode : (modeBeforePause ?? mode)
        let until = Date().addingTimeInterval(duration)
        pausedUntil = until
        modeBeforePause = previous
        if persistsPreferences {
            Preferences.pausedUntil = until
            Preferences.modeBeforePause = previous
        }
        schedulePauseEnd(at: until)
        applyMode(.allowAll)
    }

    func resumeFiltering() {
        cancelPause(restoring: true)
    }

    private func applyMode(_ newMode: FilterMode) {
        guard newMode != mode else {
            post(Self.modeDidChange)
            return
        }
        mode = newMode
        if persistsPreferences { Preferences.filterMode = newMode }
        post(Self.modeDidChange)
        dropDecidedApprovals()
    }

    /// Applies a pause persisted before the last quit (see `PauseSchedule.restore`).
    private func restorePause(now: Date = Date()) {
        let state = PauseSchedule.restore(
            savedMode: mode, pausedUntil: Preferences.pausedUntil,
            modeBeforePause: Preferences.modeBeforePause, now: now)
        mode = state.mode
        Preferences.filterMode = state.mode
        pausedUntil = state.pausedUntil
        modeBeforePause = state.modeBeforePause
        Preferences.pausedUntil = state.pausedUntil
        Preferences.modeBeforePause = state.modeBeforePause
        if let until = state.pausedUntil { schedulePauseEnd(at: until) }
    }

    private func schedulePauseEnd(at date: Date) {
        pauseTimer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPause(restoring: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func cancelPause(restoring: Bool) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        let previous = modeBeforePause
        pausedUntil = nil
        modeBeforePause = nil
        if persistsPreferences {
            Preferences.pausedUntil = nil
            Preferences.modeBeforePause = nil
        }
        if restoring { applyMode(previous ?? .blockList) }
    }

    // MARK: - Approvals

    /// Adds a request, or updates the pending one with the same ID or app.
    func enqueueApproval(_ request: ApprovalRequest) {
        if let index = pendingApprovals.firstIndex(where: {
            $0.requestID == request.requestID || $0.app.matchKey == request.app.matchKey
        }) {
            pendingApprovals[index] = request
        } else {
            pendingApprovals.append(request)
        }
        post(Self.approvalsDidChange)
    }

    @discardableResult
    func removeApproval(_ requestID: UUID) -> ApprovalRequest? {
        guard let index = pendingApprovals.firstIndex(where: { $0.requestID == requestID }) else { return nil }
        let request = pendingApprovals.remove(at: index)
        post(Self.approvalsDidChange)
        return request
    }

    /// The extension resolves paused flows itself when a rule or mode change now
    /// decides them; there is no cancel event, so mirror that here.
    private func dropDecidedApprovals() {
        guard !pendingApprovals.isEmpty else { return }
        let before = pendingApprovals.count
        pendingApprovals.removeAll { request in
            guard mode == .requireApproval else { return true }
            return !request.destinations.contains { destination in
                let flow = FlowDescriptor(
                    app: request.app, host: destination.host, ip: destination.ip,
                    port: destination.port, proto: destination.proto, direction: .outbound)
                return RuleEngine.evaluate(flow, mode: mode, rules: rules, hostIsFinal: true).decision == .needsApproval
            }
        }
        if pendingApprovals.count != before { post(Self.approvalsDidChange) }
    }

    /// Drops requests the extension has already timed out on.
    func expireApprovals(olderThan cutoff: Date) {
        let before = pendingApprovals.count
        pendingApprovals.removeAll { $0.firstSeen < cutoff }
        if pendingApprovals.count != before { post(Self.approvalsDidChange) }
    }

    // MARK: -

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }
}
