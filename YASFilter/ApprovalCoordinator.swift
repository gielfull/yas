import Foundation
import NetworkExtension
import YASShared

/// Require Approval mode: holds paused flows, one prompt per app,
/// and guarantees every paused flow is resumed (answer, timeout, rule change,
/// app disconnect, or filter stop).
///
/// `@unchecked Sendable`: all mutable state (`queue`-confined below) is only
/// touched on `queue`, and `NEFilterFlow` objects never leave it except to be
/// handed to `resume`, which NetworkExtension accepts from any thread.
final class ApprovalCoordinator: @unchecked Sendable {
    /// How the flow was paused, which decides the verdict type it resumes with.
    enum PauseKind: Sendable {
        /// Paused from `handleNewFlow`: resume with an `NEFilterNewFlowVerdict`.
        case newFlow
        /// Paused from `handleOutboundData`: resume with an `NEFilterDataVerdict`.
        case data
    }

    /// Resumes a paused flow with the decided action. The provider builds the
    /// verdict, since an allowed flow may continue as a live (watched) flow.
    typealias Resume = (NEFilterFlow, InspectedFlow, PauseKind, RuleAction) -> Void

    /// Carries a paused flow onto `queue`.
    ///
    /// `@unchecked Sendable`: NetworkExtension predates Sendable annotations, but
    /// the framework itself hands flow objects between its queues, and
    /// `resumeFlow(_:with:)` is documented for use after the callback returned,
    /// i.e. from another thread. We never mutate the flow; we only hold it and
    /// pass it back to `resumeFlow`.
    private struct PausedFlow: @unchecked Sendable {
        let flow: NEFilterFlow
        let kind: PauseKind
        let inspected: InspectedFlow
    }

    private let queue = DispatchQueue(label: "com.gful.yas.filter.approval")
    private let store: RuleStore
    private let events: FilterEventSink
    private let options: EngineOptions
    private let now: @Sendable () -> Date

    // Confined to `queue`.
    private var approvals = ApprovalQueue<UUID>()
    private var paused: [UUID: PausedFlow] = [:]
    private var resume: Resume?

    init(
        store: RuleStore,
        events: FilterEventSink,
        options: EngineOptions,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.events = events
        self.options = options
        self.now = now
    }

    /// Sets the function that resumes flows (wraps the provider's `resumeFlow`).
    func attach(resume: @escaping Resume) {
        queue.sync { self.resume = resume }
    }

    /// Takes ownership of a flow the caller is about to return a pause verdict for.
    /// Call only when `events.hasClient`; otherwise use `fallbackAction` directly.
    func enqueue(_ flow: NEFilterFlow, inspected: InspectedFlow, kind: PauseKind) {
        let entry = PausedFlow(flow: flow, kind: kind, inspected: inspected)
        queue.async { [self] in
            let id = inspected.id
            paused[id] = entry
            let outcome = approvals.enqueue(
                flow: id,
                app: inspected.descriptor.app,
                destination: DestinationKey(inspected.descriptor),
                now: now())
            switch outcome {
            case .created(let request):
                Log.approval.info(
                    "New request \(request.requestID, privacy: .public) for \(request.app.matchKey, privacy: .public)")
                events.requestApproval(request)
                scheduleTimeout(for: request.requestID)
            case .updated(let request):
                events.requestApproval(request)
            case .unchanged:
                break
            }
            // The app may have gone between the caller's check and now. Deferred:
            // this block can run before the caller has returned its pause verdict,
            // and a flow must not be resumed before it is paused.
            if !events.hasClient {
                queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                    if !events.hasClient { drainAll(reason: "no app connected") }
                }
            }
        }
    }

    /// The user answered a request.
    func resolve(requestID: UUID, decision: ApprovalDecision) {
        queue.async { [self] in
            guard let app = approvals.app(for: requestID) else {
                Log.approval.error("Decision for unknown request \(requestID, privacy: .public)")
                return
            }
            // Persist first, so flows that arrive while we resume already match.
            let rule = persistRule(for: decision, app: app, requestID: requestID)

            guard let taken = approvals.take(requestID: requestID, where: decision.covers) else {
                // Late answer (after timeout): the rule is still worth keeping.
                return
            }
            let verdict: Verdict = decision.action == .allow ? .approved : .blocked
            finish(taken, action: decision.action, verdict: verdict, matchedRuleID: rule?.id)
            Log.approval.info(
                "Request \(requestID, privacy: .public) resolved: \(decision.action.rawValue, privacy: .public) \(decision.scope.rawValue, privacy: .public), \(taken.flows.count) flows")
        }
    }

    /// Rules or mode changed: resume every paused flow the new rules now decide.
    /// Switching to `allowAll` (kill-switch territory) releases everything.
    func reevaluate() {
        queue.async { [self] in
            guard !paused.isEmpty else { return }
            let state = store.snapshot
            var decided: [RuleAction: [UUID: UUID?]] = [:]
            for (id, entry) in paused {
                switch FlowPolicy.finalPlan(
                    for: entry.inspected.descriptor, mode: state.mode, rules: state.rules, options: options) {
                case .allow(let ruleID): decided[.allow, default: [:]][id] = ruleID
                case .block(let ruleID): decided[.block, default: [:]][id] = ruleID
                case .needsApproval, .peekClientHello, .sniffDNS: continue
                }
            }
            for (action, flows) in decided {
                for taken in approvals.remove(flows: Set(flows.keys)) {
                    for id in taken.flows {
                        resumeFlow(id, action: action, verdict: action == .allow ? .allowed : .blocked,
                                   matchedRuleID: flows[id] ?? nil)
                    }
                    if let remaining = taken.remaining {
                        events.requestApproval(remaining)
                    }
                }
            }
        }
    }

    /// Resumes everything with the no-client fallback (app gone, filter stopping).
    func resumeAll(reason: String) {
        queue.async { [self] in drainAll(reason: reason) }
    }

    /// Like `resumeAll`, but returns once done. For `stopFilter`.
    func resumeAllAndWait(reason: String) {
        queue.sync { drainAll(reason: reason) }
    }

    /// Verdict for a flow that needs approval while nobody can answer.
    func fallbackAction() -> RuleAction {
        store.settings.noClientAction
    }

    // MARK: - On `queue`

    /// The timer is monotonic but `expire` compares wall-clock dates. If the clock
    /// moved backwards the request is not due yet: re-arm for the remainder, and on
    /// the next attempt release it regardless, so no flow is ever held forever.
    private func scheduleTimeout(for requestID: UUID, after delay: TimeInterval? = nil, attempt: Int = 0) {
        let timeout = store.settings.approvalTimeout
        queue.asyncAfter(deadline: .now() + (delay ?? timeout)) { [self] in
            guard let request = approvals.request(requestID) else { return }
            let expired = attempt >= 1
                ? approvals.take(requestID: requestID)
                : approvals.expire(requestID: requestID, now: now(), timeout: timeout)
            guard let taken = expired else {
                let elapsed = now().timeIntervalSince(request.firstSeen)
                scheduleTimeout(for: requestID, after: (timeout - elapsed).clamped(to: 1...timeout), attempt: attempt + 1)
                return
            }
            let action = store.settings.timeoutAction
            Log.approval.notice(
                "Request \(requestID, privacy: .public) timed out after \(Int(timeout))s: \(action.rawValue, privacy: .public) once, \(taken.flows.count) flows")
            finish(taken, action: action, verdict: action == .allow ? .allowed : .blocked, matchedRuleID: nil)
        }
    }

    private func drainAll(reason: String) {
        guard !approvals.isEmpty else { return }
        let action = store.settings.noClientAction
        let drained = approvals.drainAll()
        let count = drained.reduce(0) { $0 + $1.flows.count }
        Log.approval.notice(
            "Resuming \(count) paused flows (\(reason, privacy: .public)): \(action.rawValue, privacy: .public)")
        for taken in drained {
            finish(taken, action: action, verdict: action == .allow ? .allowed : .blocked, matchedRuleID: nil)
        }
    }

    private func finish(_ taken: ApprovalQueue<UUID>.Taken, action: RuleAction, verdict: Verdict, matchedRuleID: UUID?) {
        for id in taken.flows {
            resumeFlow(id, action: action, verdict: verdict, matchedRuleID: matchedRuleID)
        }
        if let remaining = taken.remaining {
            events.requestApproval(remaining)
        }
    }

    private func resumeFlow(_ id: UUID, action: RuleAction, verdict: Verdict, matchedRuleID: UUID?) {
        guard let entry = paused.removeValue(forKey: id) else { return }
        if let resume {
            resume(entry.flow, entry.inspected, entry.kind, action)
        } else {
            Log.approval.fault("No resume function attached; flow \(id, privacy: .public) stays paused")
        }
        events.report(FlowEvents.make(entry.inspected, verdict: verdict, matchedRuleID: matchedRuleID, now: now()))
    }

    /// Persists the rule for an "always" decision. The rule's ID is the request ID
    /// (unless a rule with that ID already exists, e.g. a second per-domain answer
    /// to the same request), so the app can build the identical rule from its own
    /// copy of the request with `decision.makeRule(for: request.app, id: request.requestID)`.
    private func persistRule(for decision: ApprovalDecision, app: AppIdentity, requestID: UUID) -> Rule? {
        let id = store.containsRule(id: requestID) ? UUID() : requestID
        guard let rule = decision.makeRule(for: app, id: id, createdAt: now()) else { return nil }
        store.addRule(rule)
        Log.approval.info("Persisted rule \(rule.id, privacy: .public) from request \(requestID, privacy: .public)")
        return rule
    }
}
