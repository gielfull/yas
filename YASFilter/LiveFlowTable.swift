import Foundation
import NetworkExtension
import YASShared
import os

/// Allowed flows that stay under watch so they can be cut when the rules change
/// (Disconnect, a new block rule, Block All).
///
/// Two ways a live flow gets cut:
/// 1. **Sweep** (immediate): when mode or rules change, every live flow is
///    re-evaluated off the filter path and newly blocked ones are dropped with
///    `updateFlow(_:using:forDirection:)`, idle or not.
/// 2. **Per chunk** (backstop): each data callback re-checks against the current
///    generation (`LiveInspection.decide`). Covers what the sweep can't see, such as
///    a rule expiring into a block, and flows registered mid-sweep.
///
/// `@unchecked Sendable`: `entries` is lock-protected and Sendable; `update` is
/// only touched on `sweepQueue`. Flow objects are wrapped in `Handle` (see there).
final class LiveFlowTable: @unchecked Sendable {
    typealias Update = (NEFilterSocketFlow, NEFilterDataVerdict) -> Void

    /// Holds a live flow for the sweep.
    ///
    /// `@unchecked Sendable`: NetworkExtension predates Sendable annotations.
    /// `updateFlow(_:using:forDirection:)` exists precisely to be called outside
    /// the flow's callbacks, i.e. from another thread; we never mutate the flow.
    struct Handle: @unchecked Sendable {
        let flow: NEFilterSocketFlow
    }

    private struct Entries: Sendable {
        var states = BoundedCache<UUID, LiveFlowState>(capacity: 16_384)
        var handles = BoundedCache<UUID, Handle>(capacity: 16_384)

        mutating func remove(_ id: UUID) {
            states.removeValue(for: id)
            handles.removeValue(for: id)
        }
    }

    private let entries = OSAllocatedUnfairLock(initialState: Entries())
    private let store: RuleStore
    private let options: EngineOptions
    private let events: FilterEventSink
    private let sweepQueue = DispatchQueue(label: "com.gful.yas.filter.live", qos: .utility)
    // Confined to `sweepQueue`.
    private var update: Update?

    init(store: RuleStore, options: EngineOptions, events: FilterEventSink) {
        self.store = store
        self.options = options
        self.events = events
    }

    /// Sets the function that changes a flow's verdict (the provider's `updateFlow`).
    func attach(update: @escaping Update) {
        sweepQueue.sync { self.update = update }
    }

    var count: Int { entries.withLock { $0.states.count } }

    /// Starts watching an allowed flow. Its first data callback evaluates it.
    func watch(_ flow: NEFilterFlow, inspected: InspectedFlow) {
        let handle = (flow as? NEFilterSocketFlow).map(Handle.init)
        entries.withLock {
            $0.states[inspected.id] = LiveFlowState(inspected: inspected)
            if let handle { $0.handles[inspected.id] = handle }
        }
    }

    func isWatching(_ id: UUID) -> Bool {
        entries.withLock { $0.states[id] != nil }
    }

    func isCut(_ id: UUID) -> Bool {
        entries.withLock { $0.states[id]?.isCut ?? false }
    }

    /// Verdict for a data callback, or nil if the flow is not live. Runs the engine
    /// outside the lock on a cache miss, so callbacks for other flows don't wait.
    func verdict(for id: UUID, offset: Int) -> LiveVerdict? {
        let generation = store.generation
        guard var state = entries.withLock({ $0.states[id] }) else { return nil }
        let decided = LiveInspection.decide(
            &state, generation: generation, offset: offset, options: options,
            snapshot: { store.ruleSnapshot }, now: Date.init)
        let stateToStore = state
        let verdict: LiveVerdict = entries.withLock { entries in
            // Already cut (by the sweep while we were deciding, or by an earlier
            // callback): keep dropping, and never report twice.
            if let current = entries.states[id], current.isCut {
                return .drop(matchedRuleID: nil, report: false)
            }
            switch decided {
            case .release:
                entries.remove(id)
            case .pass, .drop:
                if entries.states[id] != nil { entries.states[id] = stateToStore }
            }
            return decided
        }
        if case .drop(let ruleID, true) = verdict {
            reportCut(state.inspected, matchedRuleID: ruleID, via: "data")
        }
        return verdict
    }

    /// The flow closed.
    func forget(_ id: UUID) {
        entries.withLock { $0.remove(id) }
    }

    func removeAll() {
        entries.withLock { $0 = Entries() }
    }

    /// Re-evaluates every live flow against the current rules and applies the
    /// result right away: cut newly blocked flows, release all of them when the
    /// kill switch (allowAll) or the setting says stop watching.
    func sweep() {
        sweepQueue.async { [self] in
            let snapshot = store.ruleSnapshot
            let now = Date()
            let live: [(UUID, LiveFlowState, Handle?)] = entries.withLock { entries in
                entries.states.keys.compactMap { id in
                    guard let state = entries.states[id], !state.isCut else { return nil }
                    return (id, state, entries.handles[id])
                }
            }
            guard !live.isEmpty else { return }

            var cut = 0
            var released = 0
            for (id, original, handle) in live {
                var state = original
                let outcome = LiveInspection.refresh(&state, snapshot: snapshot, options: options, now: now)
                let refreshed = state
                switch outcome {
                case .allow:
                    entries.withLock { entries in
                        guard entries.states[id]?.isCut == false else { return }
                        entries.states[id] = refreshed
                    }
                case .block(let ruleID):
                    let first: Bool = entries.withLock { entries in
                        guard var current = entries.states[id], !current.isCut else { return false }
                        current.isCut = true
                        current.cached = refreshed.cached
                        entries.states[id] = current
                        return true
                    }
                    guard first else { continue }
                    if let handle { update?(handle.flow, FilterVerdicts.dropData()) }
                    reportCut(state.inspected, matchedRuleID: ruleID, via: "sweep")
                    cut += 1
                case .release:
                    entries.withLock { $0.remove(id) }
                    if let handle { update?(handle.flow, FilterVerdicts.allowData()) }
                    released += 1
                }
            }
            Log.flow.info(
                "Live sweep (generation \(snapshot.generation)): \(live.count) flows, \(cut) cut, \(released) released")
        }
    }

    /// Reported as a new blocked event (fresh ID) so the app's history, which
    /// ignores repeated flow IDs, records the cut.
    private func reportCut(_ inspected: InspectedFlow, matchedRuleID: UUID?, via source: String) {
        let flow = inspected.descriptor
        Log.flow.info("""
            Cut live flow (\(source, privacy: .public)) \(flow.app.matchKey, privacy: .public) \
            \(flow.host ?? flow.ip, privacy: .public):\(flow.port) rule \(matchedRuleID?.uuidString ?? "-", privacy: .public)
            """)
        events.report(FlowEvents.make(
            inspected, id: UUID(), verdict: .blocked, matchedRuleID: matchedRuleID, now: Date()))
    }
}
