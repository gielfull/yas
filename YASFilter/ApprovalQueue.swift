import Foundation
import YASShared

/// Where a paused flow was going. One `ApprovalDestination` aggregates the flows
/// that share all four fields.
struct DestinationKey: Hashable, Sendable {
    var host: String?
    var ip: String
    var port: Int
    var proto: TransportProtocol

    init(host: String?, ip: String, port: Int, proto: TransportProtocol) {
        self.host = host
        self.ip = ip
        self.port = port
        self.proto = proto
    }

    init(_ flow: FlowDescriptor) {
        self.init(host: flow.host, ip: flow.ip, port: flow.port, proto: flow.proto)
    }
}

/// Paused flows grouped into one approval request per app (`AppIdentity.matchKey`).
///
/// Pure state: no queues, no timers, no clock. The caller passes `now` and applies
/// the returned flow IDs, so grouping and timeouts are testable.
struct ApprovalQueue<FlowID: Hashable & Sendable>: Sendable {
    enum EnqueueOutcome: Hashable, Sendable {
        /// First flow for this app: send the request to the app.
        case created(ApprovalRequest)
        /// A new destination joined an open request: send the updated request
        /// (same `requestID`) so the app can refresh its prompt.
        case updated(ApprovalRequest)
        /// Another flow to a destination already listed; nothing to send.
        case unchanged(requestID: UUID)
    }

    /// Flows taken out of a request.
    struct Taken: Sendable {
        let requestID: UUID
        let app: AppIdentity
        let flows: [FlowID]
        /// The request with the flows that are still waiting, or nil if it closed.
        let remaining: ApprovalRequest?
    }

    private struct Pending: Sendable {
        var request: ApprovalRequest
        /// In arrival order.
        var flows: [(id: FlowID, destination: DestinationKey)]
    }

    private var pending: [UUID: Pending] = [:]
    private var requestIDByApp: [String: UUID] = [:]
    /// Recently closed requests, so an "always" answer that arrives after the
    /// timeout still persists its rule.
    private var closed = BoundedCache<UUID, AppIdentity>(capacity: 256)

    init() {}

    var isEmpty: Bool { pending.isEmpty }
    var pendingFlowCount: Int { pending.values.reduce(0) { $0 + $1.flows.count } }
    var requestIDs: [UUID] { Array(pending.keys) }

    func request(_ requestID: UUID) -> ApprovalRequest? {
        pending[requestID]?.request
    }

    func requestID(forApp app: AppIdentity) -> UUID? {
        requestIDByApp[app.matchKey]
    }

    /// App of an open or recently closed request.
    func app(for requestID: UUID) -> AppIdentity? {
        pending[requestID]?.request.app ?? closed[requestID]
    }

    mutating func enqueue(
        flow: FlowID,
        app: AppIdentity,
        destination: DestinationKey,
        now: Date,
        makeRequestID: () -> UUID = UUID.init
    ) -> EnqueueOutcome {
        if let requestID = requestIDByApp[app.matchKey], var entry = pending[requestID] {
            let isNewDestination = !entry.flows.contains { $0.destination == destination }
            entry.flows.append((flow, destination))
            entry.request.destinations = Self.destinations(of: entry.flows)
            pending[requestID] = entry
            return isNewDestination ? .updated(entry.request) : .unchanged(requestID: requestID)
        }
        let requestID = makeRequestID()
        let flows = [(id: flow, destination: destination)]
        let request = ApprovalRequest(
            requestID: requestID, app: app, destinations: Self.destinations(of: flows), firstSeen: now)
        pending[requestID] = Pending(request: request, flows: flows)
        requestIDByApp[app.matchKey] = requestID
        return .created(request)
    }

    /// Takes the flows of `requestID` that `matches` accepts (all when nil).
    mutating func take(
        requestID: UUID,
        where matches: ((DestinationKey) -> Bool)? = nil
    ) -> Taken? {
        guard var entry = pending[requestID] else { return nil }
        let taken = entry.flows.filter { matches?($0.destination) ?? true }
        entry.flows.removeAll { matches?($0.destination) ?? true }
        return finish(requestID: requestID, entry: entry, takenIDs: taken.map(\.id))
    }

    /// Removes specific flows (e.g. resolved by a rule change or closed by the
    /// system), from whichever requests hold them.
    mutating func remove(flows ids: Set<FlowID>) -> [Taken] {
        var results: [Taken] = []
        for (requestID, var entry) in pending {
            let taken = entry.flows.filter { ids.contains($0.id) }
            guard !taken.isEmpty else { continue }
            entry.flows.removeAll { ids.contains($0.id) }
            if let result = finish(requestID: requestID, entry: entry, takenIDs: taken.map(\.id)) {
                results.append(result)
            }
        }
        return results
    }

    /// Takes every flow of `requestID` if it has waited at least `timeout`.
    mutating func expire(requestID: UUID, now: Date, timeout: TimeInterval) -> Taken? {
        guard let entry = pending[requestID],
              now.timeIntervalSince(entry.request.firstSeen) >= timeout
        else { return nil }
        return take(requestID: requestID)
    }

    /// Takes every request that has waited at least `timeout`.
    mutating func expireAll(now: Date, timeout: TimeInterval) -> [Taken] {
        requestIDs.compactMap { expire(requestID: $0, now: now, timeout: timeout) }
    }

    /// Takes everything (app disconnected, filter stopping).
    mutating func drainAll() -> [Taken] {
        requestIDs.compactMap { take(requestID: $0) }
    }

    private mutating func finish(requestID: UUID, entry: Pending, takenIDs: [FlowID]) -> Taken? {
        guard !takenIDs.isEmpty else { return nil }
        let app = entry.request.app
        if entry.flows.isEmpty {
            pending[requestID] = nil
            if requestIDByApp[app.matchKey] == requestID {
                requestIDByApp[app.matchKey] = nil
            }
            closed[requestID] = app
            return Taken(requestID: requestID, app: app, flows: takenIDs, remaining: nil)
        }
        var entry = entry
        entry.request.destinations = Self.destinations(of: entry.flows)
        pending[requestID] = entry
        return Taken(requestID: requestID, app: app, flows: takenIDs, remaining: entry.request)
    }

    /// Aggregates flows into destinations, in first-seen order.
    private static func destinations(of flows: [(id: FlowID, destination: DestinationKey)]) -> [ApprovalDestination] {
        var order: [DestinationKey] = []
        var counts: [DestinationKey: Int] = [:]
        for flow in flows {
            if counts[flow.destination] == nil { order.append(flow.destination) }
            counts[flow.destination, default: 0] += 1
        }
        return order.map { key in
            ApprovalDestination(host: key.host, ip: key.ip, port: key.port, proto: key.proto, count: counts[key] ?? 0)
        }
    }
}

extension ApprovalDecision {
    /// Whether a paused flow to `destination` is covered by this decision.
    /// App-wide decisions cover every flow; domain decisions only flows whose
    /// hostname is that domain or a subdomain (unknown hosts are not covered).
    func covers(_ destination: DestinationKey) -> Bool {
        guard let domain, !DomainMatcher.normalize(domain).isEmpty else { return true }
        guard let host = destination.host else { return false }
        return DomainMatcher.matches(host: host, domain: domain, includeSubdomains: true)
    }
}
