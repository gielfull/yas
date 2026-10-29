import Foundation

public enum RuleAction: String, Codable, Sendable, CaseIterable {
    case allow
    case block
}

public enum RuleTarget: Codable, Hashable, Sendable {
    /// Every flow of an app (matched by `AppIdentity.matchKey`).
    case app(AppIdentity)
    /// A domain for every app. `includeSubdomains == false` means exact host only.
    case domain(String, includeSubdomains: Bool)
    /// A domain (and its subdomains) for one app.
    case appDomain(AppIdentity, String)
}

public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var target: RuleTarget
    public var action: RuleAction
    public var isEnabled: Bool
    public var createdAt: Date
    public var note: String?
    /// The rule stops applying at this instant (e.g. "Disconnect for 15 minutes").
    /// Nil = until removed. Optional so payloads from before it existed still decode.
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        target: RuleTarget,
        action: RuleAction,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        note: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.target = target
        self.action = action
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.note = note
        self.expiresAt = expiresAt
    }

    /// Enabled and not expired at `now` (a rule expiring exactly at `now` no longer applies).
    public func isInEffect(at now: Date) -> Bool {
        guard isEnabled else { return false }
        guard let expiresAt else { return true }
        return expiresAt > now
    }
}
