import Foundation
import YASShared

/// The rules as the live-connection check sees them, tagged with a generation.
///
/// `generation` changes whenever mode, rules or settings change (`RuleStore`).
/// Time-based changes (a rule's `expiresAt` passing) don't bump it; instead each
/// cached decision carries `validUntil` = the next expiry after it was made, so a
/// cache hit is "same generation and that instant not reached yet". Same effect as
/// bumping a counter when a rule expires, without a timer.
struct RuleSnapshot: Sendable {
    let generation: UInt64
    let mode: FilterMode
    let rules: [Rule]
    let settings: FilterSettings
    /// `expiresAt` of the enabled rules, ascending.
    let expiries: [Date]

    init(generation: UInt64, mode: FilterMode, rules: [Rule], settings: FilterSettings) {
        self.generation = generation
        self.mode = mode
        self.rules = rules
        self.settings = settings
        self.expiries = rules.compactMap { $0.isEnabled ? $0.expiresAt : nil }.sorted()
    }

    /// The first rule expiry strictly after `now` (binary search), or nil.
    func nextExpiry(after now: Date) -> Date? {
        var low = 0
        var high = expiries.count
        while low < high {
            let mid = (low + high) / 2
            if expiries[mid] <= now { low = mid + 1 } else { high = mid }
        }
        return low < expiries.count ? expiries[low] : nil
    }
}

/// What the current rules say about an allowed, already-open flow.
enum LiveOutcome: Hashable, Sendable {
    /// Still allowed: keep watching.
    case allow
    /// Now blocked: cut it.
    case block(matchedRuleID: UUID?)
    /// Stop watching for good (allowAll kill switch, or the feature turned off).
    case release
}

/// The verdict for one data callback of a live flow.
enum LiveVerdict: Hashable, Sendable {
    /// Let `bytes` through without calling us, then show us the next bytes.
    case pass(bytes: Int)
    /// Drop the flow. `report` is false when it was already reported as cut.
    case drop(matchedRuleID: UUID?, report: Bool)
    /// Final allow; no more callbacks for this flow.
    case release
}

/// Per-flow state for a live (allowed, still inspected) flow.
struct LiveFlowState: Sendable {
    struct Cached: Hashable, Sendable {
        let generation: UInt64
        /// Re-evaluate at or after this instant (a rule expires then). Nil = never.
        let validUntil: Date?
        let outcome: LiveOutcome
    }

    let inspected: InspectedFlow
    var cached: Cached?
    /// Set once the flow was cut, so later callbacks (other direction) keep
    /// dropping it and it is reported only once.
    var isCut = false

    init(inspected: InspectedFlow, cached: Cached? = nil) {
        self.inspected = inspected
        self.cached = cached
    }

    /// Whether `cached` still answers for `generation` at `now()`. `now` is only
    /// called when the cached decision has an expiry to check against.
    func cacheHit(generation: UInt64, now: () -> Date) -> LiveOutcome? {
        guard let cached, cached.generation == generation else { return nil }
        if let validUntil = cached.validUntil, now() >= validUntil { return nil }
        return cached.outcome
    }
}

/// Pure decisions for "cut open connections when the rules now block them".
/// No NetworkExtension types, so it is unit tested.
enum LiveInspection {
    /// First pass window: most request/response flows finish inside it, so they
    /// cost one callback per direction.
    static let minimumWindow = 256 * 1_024
    /// Largest pass window, reached after ~1 MB in a direction. Bulk transfers
    /// then cost one callback per MB per direction.
    static let maximumWindow = 1_024 * 1_024
    /// Bytes shown to us after each window. We never read them, so keep the copy
    /// small; non-zero so there is a next callback.
    static let peekBytes = 512

    /// Pass window for a direction that has already moved `offset` bytes: grows with
    /// the flow (256 KB, 256 KB, 512 KB, 1 MB, 1 MB, ...), so short flows are checked
    /// often in time and long transfers rarely in bytes.
    static func window(offset: Int) -> Int {
        min(max(offset, minimumWindow), maximumWindow)
    }

    /// Whether an allowed flow should stay under watch. Exempt:
    /// - DNS: has its own sniffing path, always allowed.
    /// - YAS itself (and anything else exempt from Block All): cutting the app's
    ///   own connections could strand the user without its UI.
    /// - Loopback: local IPC between processes (helpers, dev servers). New loopback
    ///   connections still obey the rules; only mid-stream cuts are skipped, since
    ///   they can wedge the apps on both ends.
    static func isEligible(_ flow: FlowDescriptor, options: EngineOptions) -> Bool {
        if FlowPolicy.isDNS(flow) { return false }
        if isLoopback(flow.ip) { return false }
        return !options.isExemptFromBlockAll(flow.app)
    }

    /// Whether a new flow that the rules allow gets a live (filterData) verdict
    /// instead of a final allow. allowAll stays on the cheap final-allow path.
    static func shouldWatch(
        _ flow: FlowDescriptor, mode: FilterMode, settings: FilterSettings, options: EngineOptions
    ) -> Bool {
        settings.cutLiveConnections && mode != .allowAll && isEligible(flow, options: options)
    }

    /// Full evaluation against the current rules. A flow that would now need
    /// approval is left running: it was allowed when it opened, and prompting
    /// mid-stream is not something the user asked for.
    static func outcome(
        for flow: FlowDescriptor, snapshot: RuleSnapshot, options: EngineOptions, now: Date
    ) -> LiveOutcome {
        guard snapshot.settings.cutLiveConnections, snapshot.mode != .allowAll else { return .release }
        let evaluation = RuleEngine.evaluate(
            flow, mode: snapshot.mode, rules: snapshot.rules, options: options, hostIsFinal: true, now: now)
        switch evaluation.decision {
        case .block: return .block(matchedRuleID: evaluation.matchedRuleID)
        case .allow, .needsApproval, .needsMoreData: return .allow
        }
    }

    /// Re-evaluates (or reuses the cached result) and stores it in `state`.
    static func refresh(
        _ state: inout LiveFlowState, snapshot: RuleSnapshot, options: EngineOptions, now: Date
    ) -> LiveOutcome {
        let outcome = outcome(for: state.inspected.descriptor, snapshot: snapshot, options: options, now: now)
        state.cached = .init(
            generation: snapshot.generation, validUntil: snapshot.nextExpiry(after: now), outcome: outcome)
        return outcome
    }

    /// The hot path, once per data callback of a live flow.
    ///
    /// Cache hit (the common case): an integer compare, plus a clock read only if a
    /// rule is due to expire. Miss: `snapshot()` is fetched and the engine runs once.
    static func decide(
        _ state: inout LiveFlowState,
        generation: UInt64,
        offset: Int,
        options: EngineOptions,
        snapshot: () -> RuleSnapshot,
        now: () -> Date
    ) -> LiveVerdict {
        if state.isCut {
            return .drop(matchedRuleID: blockedRuleID(state.cached?.outcome), report: false)
        }
        let outcome = state.cacheHit(generation: generation, now: now)
            ?? refresh(&state, snapshot: snapshot(), options: options, now: now())
        return verdict(for: outcome, state: &state, offset: offset)
    }

    /// Maps an outcome to a verdict, marking the flow cut on the first block.
    static func verdict(for outcome: LiveOutcome, state: inout LiveFlowState, offset: Int) -> LiveVerdict {
        switch outcome {
        case .allow:
            return .pass(bytes: window(offset: offset))
        case .release:
            return .release
        case .block(let ruleID):
            let first = !state.isCut
            state.isCut = true
            return .drop(matchedRuleID: ruleID, report: first)
        }
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip == "localhost"
    }

    private static func blockedRuleID(_ outcome: LiveOutcome?) -> UUID? {
        if case .block(let id)? = outcome { return id }
        return nil
    }
}
