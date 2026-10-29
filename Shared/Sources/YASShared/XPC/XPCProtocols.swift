import Foundation

// Payloads are JSON-encoded Codable values (see `PayloadCoder`).
// Reply blocks are `@Sendable` because NSXPC invokes them on its own queues.

/// App -> extension. Exported by the extension's `NSXPCListener`.
@objc public protocol FilterControlProtocol {
    /// Called on every (re)connect before the rules are pushed.
    func register(reply: @escaping @Sendable (Bool) -> Void)
    /// `mode` is a `FilterMode.rawValue`.
    func setMode(_ mode: String, reply: @escaping @Sendable (Bool) -> Void)
    /// `rulesJSON` encodes `[Rule]`; replaces the extension's cached rule set.
    func replaceRules(_ rulesJSON: Data, reply: @escaping @Sendable (Bool) -> Void)
    /// `requestID` is `ApprovalRequest.requestID.uuidString`;
    /// `decisionJSON` encodes `ApprovalDecision`.
    func resolveApproval(_ requestID: String, decisionJSON: Data)
}

/// Extension -> app. Exported by the app on the same connection.
@objc public protocol FilterEventsProtocol {
    /// `batchJSON` encodes `[FlowEvent]`.
    func flowsObserved(_ batchJSON: Data)
    /// `statsJSON` encodes `[TrafficStat]`.
    func trafficStats(_ statsJSON: Data)
    /// `requestJSON` encodes `ApprovalRequest`.
    func approvalRequested(_ requestJSON: Data)
}
