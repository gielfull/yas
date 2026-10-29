import Foundation

/// Tunables for `RuleEngine` that are not user rules.
public struct EngineOptions: Hashable, Sendable {
    /// Apps (by `AppIdentity.matchKey`) still allowed in `blockAll` mode.
    public var blockAllExemptMatchKeys: Set<String>
    /// Signing identifiers still allowed in `blockAll` mode. Only honored for
    /// identities with a trusted signature (`hasTrustedSigningIdentity`), and,
    /// when `blockAllExemptTeamID` is set, only for that team.
    public var blockAllExemptSigningIDs: Set<String>
    /// Restricts `blockAllExemptSigningIDs` to one team. Leave nil until the
    /// project has a Team ID; set it for release builds.
    public var blockAllExemptTeamID: String?

    public init(
        blockAllExemptMatchKeys: Set<String> = [],
        blockAllExemptSigningIDs: Set<String> = [XPCConstants.appBundleID],
        blockAllExemptTeamID: String? = nil
    ) {
        self.blockAllExemptMatchKeys = blockAllExemptMatchKeys
        self.blockAllExemptSigningIDs = blockAllExemptSigningIDs
        self.blockAllExemptTeamID = blockAllExemptTeamID
    }

    /// Exempts the YAS app itself from `blockAll`.
    public static let `default` = EngineOptions()

    public func isExemptFromBlockAll(_ app: AppIdentity) -> Bool {
        if blockAllExemptMatchKeys.contains(app.matchKey) { return true }
        guard app.hasTrustedSigningIdentity,
              let signingID = app.signingID,
              blockAllExemptSigningIDs.contains(signingID)
        else { return false }
        if let team = blockAllExemptTeamID {
            return app.teamID == team
        }
        return true
    }
}

/// Result of evaluating one flow.
public struct Evaluation: Hashable, Sendable {
    public enum Decision: String, Hashable, Sendable {
        case allow
        case block
        case needsApproval
        /// The host is unknown and a domain rule could change the outcome:
        /// peek outbound bytes for SNI, then evaluate again.
        case needsMoreData
    }

    public let decision: Decision
    /// The rule that produced the decision, if any.
    public let matchedRuleID: UUID?

    public init(decision: Decision, matchedRuleID: UUID? = nil) {
        self.decision = decision
        self.matchedRuleID = matchedRuleID
    }
}

/// Pure rule evaluation.
///
/// Order: `allowAll` -> allow; `blockAll` -> block (unless exempt); block rules;
/// allow rules; `requireApproval` with no matching rule -> needsApproval; else allow.
/// Within block and allow rules, specificity is appDomain > domain > app (then the
/// longer domain, then list order) and only decides which rule ID is reported.
/// Disabled rules, and rules whose `expiresAt` is at or before `now`, are ignored.
public enum RuleEngine {
    /// - Parameter hostIsFinal: pass `true` when no further hostname source is
    ///   available (e.g. after SNI peeking found nothing), so the engine returns a
    ///   final decision instead of `.needsMoreData`.
    /// - Parameter now: the time expiring rules are checked against (injected by tests).
    public static func evaluate(
        _ flow: FlowDescriptor,
        mode: FilterMode,
        rules: [Rule],
        options: EngineOptions = .default,
        hostIsFinal: Bool = false,
        now: Date = Date()
    ) -> Evaluation {
        switch mode {
        case .allowAll:
            return Evaluation(decision: .allow)
        case .blockAll:
            let exempt = options.isExemptFromBlockAll(flow.app)
            return Evaluation(decision: exempt ? .allow : .block)
        case .blockList, .requireApproval:
            break
        }

        let host = flow.host.map(DomainMatcher.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let appKey = flow.app.matchKey

        if let rule = bestMatch(action: .block, rules: rules, appKey: appKey, host: host, now: now) {
            return Evaluation(decision: .block, matchedRuleID: rule.id)
        }

        let outcome: Evaluation
        if let rule = bestMatch(action: .allow, rules: rules, appKey: appKey, host: host, now: now) {
            outcome = Evaluation(decision: .allow, matchedRuleID: rule.id)
        } else if mode == .requireApproval {
            outcome = Evaluation(decision: .needsApproval)
        } else {
            outcome = Evaluation(decision: .allow)
        }

        // Unknown host: ask for SNI only if knowing the host could change the decision.
        // Inbound flows never carry our ClientHello, so they get a decision now.
        if host == nil, !hostIsFinal, flow.direction == .outbound {
            if hasDomainRule(action: .block, rules: rules, appKey: appKey, now: now) {
                return Evaluation(decision: .needsMoreData)
            }
            if outcome.decision == .needsApproval,
               hasDomainRule(action: .allow, rules: rules, appKey: appKey, now: now) {
                return Evaluation(decision: .needsMoreData)
            }
        }
        return outcome
    }

    // MARK: - Matching

    /// Tier: appDomain 3, domain 2, app 1. Tie-break: longer domain.
    private static func specificity(of rule: Rule, appKey: String, host: String?) -> (tier: Int, length: Int)? {
        switch rule.target {
        case .app(let app):
            return app.matchKey == appKey ? (1, 0) : nil
        case .domain(let domain, let includeSubdomains):
            guard let host else { return nil }
            let domain = DomainMatcher.normalize(domain)
            guard DomainMatcher.matchesNormalized(host: host, domain: domain, includeSubdomains: includeSubdomains)
            else { return nil }
            return (2, domain.count)
        case .appDomain(let app, let domain):
            guard let host, app.matchKey == appKey else { return nil }
            let domain = DomainMatcher.normalize(domain)
            guard DomainMatcher.matchesNormalized(host: host, domain: domain, includeSubdomains: true)
            else { return nil }
            return (3, domain.count)
        }
    }

    private static func bestMatch(action: RuleAction, rules: [Rule], appKey: String, host: String?, now: Date) -> Rule? {
        var best: (rule: Rule, tier: Int, length: Int)?
        for rule in rules where rule.action == action && rule.isInEffect(at: now) {
            guard let score = specificity(of: rule, appKey: appKey, host: host) else { continue }
            if let current = best, (current.tier, current.length) >= (score.tier, score.length) {
                continue
            }
            best = (rule, score.tier, score.length)
        }
        return best?.rule
    }

    /// Whether an enabled domain-bearing rule with `action` could apply to this app
    /// once the host is known.
    private static func hasDomainRule(action: RuleAction, rules: [Rule], appKey: String, now: Date) -> Bool {
        rules.contains { rule in
            guard rule.action == action, rule.isInEffect(at: now) else { return false }
            switch rule.target {
            case .app:
                return false
            case .domain(let domain, _):
                return !DomainMatcher.normalize(domain).isEmpty
            case .appDomain(let app, let domain):
                return app.matchKey == appKey && !DomainMatcher.normalize(domain).isEmpty
            }
        }
    }
}
