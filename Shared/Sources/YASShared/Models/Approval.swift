import Foundation

/// One distinct destination an app tried to reach while waiting for approval.
public struct ApprovalDestination: Codable, Hashable, Sendable {
    public var host: String?
    public var ip: String
    public var port: Int
    public var proto: TransportProtocol
    /// Number of paused flows to this destination.
    public var count: Int

    public init(host: String?, ip: String, port: Int, proto: TransportProtocol, count: Int) {
        self.host = host
        self.ip = ip
        self.port = port
        self.proto = proto
        self.count = count
    }
}

/// Sent extension -> app: one prompt per app, however many flows are queued.
public struct ApprovalRequest: Codable, Identifiable, Hashable, Sendable {
    public let requestID: UUID
    public let app: AppIdentity
    public var destinations: [ApprovalDestination]
    public let firstSeen: Date

    public var id: UUID { requestID }

    /// Total paused flows across all destinations.
    public var requestCount: Int { destinations.reduce(0) { $0 + $1.count } }

    public init(requestID: UUID, app: AppIdentity, destinations: [ApprovalDestination], firstSeen: Date) {
        self.requestID = requestID
        self.app = app
        self.destinations = destinations
        self.firstSeen = firstSeen
    }
}

/// Sent app -> extension in reply to an `ApprovalRequest`.
public struct ApprovalDecision: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// Resolve the queued flows only; nothing is persisted.
        case once
        /// Resolve the queued flows and persist a rule.
        case always
    }

    public var action: RuleAction
    public var scope: Scope
    /// When set, the decision (and a persisted rule) covers only this domain
    /// and its subdomains for the app; otherwise it covers the whole app.
    public var domain: String?

    public init(action: RuleAction, scope: Scope, domain: String? = nil) {
        self.action = action
        self.scope = scope
        self.domain = domain
    }

    /// The rule to persist for this decision, or nil when `scope == .once`.
    public func makeRule(for app: AppIdentity, id: UUID = UUID(), createdAt: Date = Date()) -> Rule? {
        guard scope == .always else { return nil }
        let target: RuleTarget
        if let domain, !DomainMatcher.normalize(domain).isEmpty {
            target = .appDomain(app, domain)
        } else {
            target = .app(app)
        }
        return Rule(id: id, target: target, action: action, isEnabled: true, createdAt: createdAt)
    }
}
