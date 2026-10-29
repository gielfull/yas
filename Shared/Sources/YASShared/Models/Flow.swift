import Foundation

public enum TransportProtocol: String, Codable, Sendable, CaseIterable {
    case tcp
    case udp
}

public enum FlowDirection: String, Codable, Sendable, CaseIterable {
    case outbound
    case inbound
}

public enum Verdict: String, Codable, Sendable, CaseIterable {
    case allowed
    case blocked
    case approved
    case pending
}

/// What the rule engine evaluates: one flow as the extension currently knows it.
public struct FlowDescriptor: Hashable, Sendable {
    public var app: AppIdentity
    /// Remote hostname if known (remoteHostname, SNI, or DNS cache); nil otherwise.
    public var host: String?
    public var ip: String
    public var port: Int
    public var proto: TransportProtocol
    public var direction: FlowDirection

    public init(
        app: AppIdentity,
        host: String?,
        ip: String,
        port: Int,
        proto: TransportProtocol,
        direction: FlowDirection
    ) {
        self.app = app
        self.host = host
        self.ip = ip
        self.port = port
        self.proto = proto
        self.direction = direction
    }
}

/// A flow observed by the extension, reported to the app.
public struct FlowEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let app: AppIdentity
    public let remoteHost: String?
    public let remoteIP: String
    public let remotePort: Int
    public let proto: TransportProtocol
    public let direction: FlowDirection
    public let verdict: Verdict
    public let matchedRuleID: UUID?

    public init(
        id: UUID,
        timestamp: Date,
        app: AppIdentity,
        remoteHost: String?,
        remoteIP: String,
        remotePort: Int,
        proto: TransportProtocol,
        direction: FlowDirection,
        verdict: Verdict,
        matchedRuleID: UUID?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.app = app
        self.remoteHost = remoteHost
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.proto = proto
        self.direction = direction
        self.verdict = verdict
        self.matchedRuleID = matchedRuleID
    }
}

/// Byte-count delta for a flow since its previous report (from `NEFilterReport`).
public struct TrafficStat: Codable, Hashable, Sendable {
    /// `NEFilterFlow.identifier`, same as the `FlowEvent.id` of the flow.
    public let flowID: UUID
    public let bytesInDelta: UInt64
    public let bytesOutDelta: UInt64
    public let timestamp: Date

    public init(flowID: UUID, bytesInDelta: UInt64, bytesOutDelta: UInt64, timestamp: Date) {
        self.flowID = flowID
        self.bytesInDelta = bytesInDelta
        self.bytesOutDelta = bytesOutDelta
        self.timestamp = timestamp
    }
}
