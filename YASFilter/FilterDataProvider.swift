import Foundation
import NetworkExtension
import YASShared
import os

/// Referenced by name from Info.plist:
/// NetworkExtension > NEProviderClasses > com.apple.networkextension.filter-data.
///
/// Pipeline per flow: identify the app, resolve the hostname
/// (`remoteHostname` -> DNS cache -> TLS SNI), evaluate with `RuleEngine`, return
/// a verdict, and report a `FlowEvent`. Allowed flows stay watched when
/// `cutLiveConnections` is on (`LiveFlowTable`), so a later block rule or mode
/// change cuts them even though they are already open. The filter path does no blocking I/O
/// beyond the first code-signature read per process, and never hops threads
/// synchronously.
final class FilterDataProvider: NEFilterDataProvider {
    /// Per-flow state while a decision is pending on data.
    private struct PendingFlows: Sendable {
        struct Peek: Sendable {
            var inspected: InspectedFlow
            var retries = 0
        }

        struct DNSSniff: Sendable {
            let proto: TransportProtocol
            var responses = 0
        }

        var peeks = BoundedCache<UUID, Peek>(capacity: 4_096)
        var dns = BoundedCache<UUID, DNSSniff>(capacity: 4_096)

        mutating func forget(_ id: UUID) {
            peeks.removeValue(for: id)
            dns.removeValue(for: id)
        }
    }

    private let store: RuleStore
    private let dnsCache = DNSCache()
    private let inspector: FlowInspector
    private let server = XPCServer()
    private let options: EngineOptions
    private let coordinator: ApprovalCoordinator
    private let controller: FilterController
    private let live: LiveFlowTable
    private let pending = OSAllocatedUnfairLock(initialState: PendingFlows())
    private let traffic = OSAllocatedUnfairLock(initialState: TrafficAccountant())

    override init() {
        store = RuleStore()
        inspector = FlowInspector(dnsCache: dnsCache)
        // Pin blockAll's self-exemption to our own team once we are signed with one.
        options = EngineOptions(blockAllExemptTeamID: AppIdentityResolver.ownTeamID())
        coordinator = ApprovalCoordinator(store: store, events: server, options: options)
        let live = LiveFlowTable(store: store, options: options, events: server)
        self.live = live
        controller = FilterController(store: store, coordinator: coordinator, onPolicyChange: { live.sweep() })
        super.init()
    }

    // MARK: - Lifecycle

    override func startFilter() async throws {
        store.load()
        coordinator.attach { [weak self] flow, inspected, kind, action in
            self?.resumePaused(flow, inspected: inspected, kind: kind, action: action)
        }
        live.attach { [weak self] flow, verdict in
            self?.update(flow, using: verdict, for: .any)
        }

        let settings = NEFilterSettings(rules: [Self.allTrafficRule()], defaultAction: .allow)
        do {
            try await apply(settings)
        } catch {
            Log.provider.fault("Could not apply filter settings: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        server.start(handler: controller)
        Log.provider.notice("Filter started, mode \(self.store.mode.rawValue, privacy: .public)")
    }

    override func stopFilter(with reason: NEProviderStopReason) async {
        Log.provider.notice("Filter stopping, reason \(reason.rawValue)")
        coordinator.resumeAllAndWait(reason: "filter stopping")
        server.stop()
        pending.withLock { $0 = PendingFlows() }
        live.removeAll()
        store.flush()
    }

    /// Every flow, both directions; default allow for anything else.
    private static func allTrafficRule() -> NEFilterRule {
        let networkRule: NENetworkRule
        if #available(macOS 15.0, *) {
            networkRule = NENetworkRule(
                remoteNetworkEndpoint: nil, remotePrefix: 0,
                localNetworkEndpoint: nil, localPrefix: 0,
                protocol: .any, direction: .any)
        } else {
            networkRule = legacyAllTrafficNetworkRule()
        }
        return NEFilterRule(networkRule: networkRule, action: .filterData)
    }

    /// macOS 14 only: the NWHostEndpoint initializer (deprecated in 15, Swift-private
    /// in the Swift 6 API notes).
    private static func legacyAllTrafficNetworkRule() -> NENetworkRule {
        NENetworkRule(
            __remoteNetwork: nil, remotePrefix: 0,
            localNetwork: nil, localPrefix: 0,
            protocol: .any, direction: .any)
    }

    // MARK: - New flows

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow, let inspected = inspector.inspect(socketFlow) else {
            return FilterVerdicts.allowNewFlow()
        }
        let state = store.snapshot
        let plan = FlowPolicy.plan(for: inspected.descriptor, mode: state.mode, rules: state.rules, options: options)

        switch plan {
        case .sniffDNS:
            pending.withLock { $0.dns[inspected.id] = .init(proto: inspected.descriptor.proto) }
            report(inspected, verdict: .allowed, matchedRuleID: nil)
            return FilterVerdicts.sniffDNS()

        case .allow(let ruleID):
            report(inspected, verdict: .allowed, matchedRuleID: ruleID)
            return allowedNewFlow(flow, inspected: inspected, state: state)

        case .block(let ruleID):
            report(inspected, verdict: .blocked, matchedRuleID: ruleID)
            return FilterVerdicts.dropNewFlow()

        case .peekClientHello:
            pending.withLock { $0.peeks[inspected.id] = .init(inspected: inspected) }
            return FilterVerdicts.peekClientHello(watchInbound: shouldWatch(inspected, state: state))

        case .needsApproval:
            guard server.hasClient else {
                return fallback(inspected) == .allow
                    ? allowedNewFlow(flow, inspected: inspected, state: state) : FilterVerdicts.dropNewFlow()
            }
            coordinator.enqueue(flow, inspected: inspected, kind: .newFlow)
            return .pause()
        }
    }

    // MARK: - Data

    override func handleOutboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        let id = flow.identifier
        guard let peek = pending.withLock({ $0.peeks[id] }) else {
            return liveVerdict(for: id, offset: offset)
        }
        var inspected = peek.inspected
        if let socketFlow = flow as? NEFilterSocketFlow {
            inspected = inspector.refresh(inspected, from: socketFlow)
        }
        if inspected.descriptor.host == nil {
            if let sni = SNIParser.parse(readBytes) {
                inspected.descriptor.host = DomainMatcher.normalize(sni)
            } else if offset == 0,
                      peek.retries < FlowPolicy.maxClientHelloRetries,
                      let needed = FlowPolicy.clientHelloBytesNeeded(readBytes) {
                // The ClientHello is still arriving (e.g. split across TCP segments):
                // pass nothing yet and peek the whole record.
                pending.withLock { $0.peeks[id]?.retries += 1 }
                return NEFilterDataVerdict(passBytes: 0, peekBytes: needed)
            }
        }
        return decideAfterPeek(flow, inspected: inspected, offset: offset)
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        // Outbound closed before we saw a ClientHello: decide with what we have.
        let id = flow.identifier
        guard let peek = pending.withLock({ $0.peeks[id] }) else {
            return live.isCut(id) ? FilterVerdicts.dropData() : FilterVerdicts.allowData()
        }
        return decideAfterPeek(flow, inspected: peek.inspected, offset: nil)
    }

    override func handleInboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        let id = flow.identifier
        let (sniff, isPeeking) = pending.withLock { ($0.dns[id], $0.peeks[id] != nil) }
        guard let sniff else {
            // Server spoke first while we still wait for the ClientHello: let it
            // through and keep watching until the outbound side is decided.
            if isPeeking {
                return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: LiveInspection.peekBytes)
            }
            return liveVerdict(for: id, offset: offset)
        }
        let response = sniff.proto == .tcp ? DNSParser.parseTCP(readBytes) : DNSParser.parse(readBytes)
        if let response, response.isResponse {
            dnsCache.insert(response)
        }
        let responses = sniff.responses + 1
        guard responses < FlowPolicy.maxDNSResponsesPerFlow else {
            pending.withLock { _ = $0.dns.removeValue(for: id) }
            return FilterVerdicts.allowData()
        }
        pending.withLock { $0.dns[id]?.responses = responses }
        // Let this response through and keep peeking at the next one.
        return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: FlowPolicy.dnsPeekBytes)
    }

    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        let id = flow.identifier
        pending.withLock { _ = $0.dns.removeValue(for: id) }
        return live.isCut(id) ? FilterVerdicts.dropData() : FilterVerdicts.allowData()
    }

    /// Final decision for a peeked flow; the hostname is as good as it gets.
    /// `offset` nil: the outbound direction is complete, so an allowed flow gets a
    /// plain allow for it (still watched, and cut via inbound callbacks or the sweep).
    private func decideAfterPeek(_ flow: NEFilterFlow, inspected: InspectedFlow, offset: Int?) -> NEFilterDataVerdict {
        let id = inspected.id
        pending.withLock { _ = $0.peeks.removeValue(for: id) }
        let state = store.snapshot
        switch FlowPolicy.finalPlan(for: inspected.descriptor, mode: state.mode, rules: state.rules, options: options) {
        case .block(let ruleID):
            report(inspected, verdict: .blocked, matchedRuleID: ruleID)
            return FilterVerdicts.dropData()
        case .needsApproval:
            guard server.hasClient else {
                return fallback(inspected) == .allow
                    ? allowedData(flow, inspected: inspected, state: state, offset: offset) : FilterVerdicts.dropData()
            }
            coordinator.enqueue(flow, inspected: inspected, kind: .data)
            return .pause()
        case .allow(let ruleID):
            report(inspected, verdict: .allowed, matchedRuleID: ruleID)
            return allowedData(flow, inspected: inspected, state: state, offset: offset)
        case .peekClientHello, .sniffDNS:
            report(inspected, verdict: .allowed, matchedRuleID: nil)
            return allowedData(flow, inspected: inspected, state: state, offset: offset)
        }
    }

    // MARK: - Reports (traffic accounting)

    override func handle(_ report: NEFilterReport) {
        guard let flow = report.flow else { return }
        let isClosed: Bool
        switch report.event {
        case .statistics: isClosed = false
        case .flowClosed: isClosed = true
        default: return
        }
        let id = flow.identifier
        let inbound = UInt64(report.bytesInboundCount)
        let outbound = UInt64(report.bytesOutboundCount)
        let stat = traffic.withLock {
            $0.record(flowID: id, inboundTotal: inbound, outboundTotal: outbound, isClosed: isClosed, now: Date())
        }
        if isClosed {
            let undecided = pending.withLock { state -> InspectedFlow? in
                defer { state.forget(id) }
                return state.peeks[id]?.inspected
            }
            live.forget(id)
            // Closed while we were still waiting for its first bytes: nothing was
            // sent, but the connection attempt should still show up in the app.
            if let undecided {
                self.report(undecided, verdict: .allowed, matchedRuleID: nil)
            }
        }
        if let stat {
            server.report(stat)
        }
    }

    // MARK: - Live flows

    private func shouldWatch(_ inspected: InspectedFlow, state: FilterState) -> Bool {
        LiveInspection.shouldWatch(inspected.descriptor, mode: state.mode, settings: state.settings, options: options)
    }

    /// Allowed at `handleNewFlow`: watched both ways, or the cheap final allow.
    private func allowedNewFlow(_ flow: NEFilterFlow, inspected: InspectedFlow, state: FilterState) -> NEFilterNewFlowVerdict {
        guard shouldWatch(inspected, state: state) else { return FilterVerdicts.allowNewFlow() }
        live.watch(flow, inspected: inspected)
        return FilterVerdicts.watchNewFlow()
    }

    /// Allowed from a data callback (after SNI, or resumed): pass a window and keep
    /// watching, or allow for good.
    private func allowedData(
        _ flow: NEFilterFlow, inspected: InspectedFlow, state: FilterState, offset: Int?
    ) -> NEFilterDataVerdict {
        guard shouldWatch(inspected, state: state) else { return FilterVerdicts.allowData() }
        live.watch(flow, inspected: inspected)
        guard let offset else { return FilterVerdicts.allowData() }
        return FilterVerdicts.pass(LiveInspection.window(offset: offset))
    }

    /// Data callback for a flow that is not peeking or sniffing: live check, or a
    /// final allow if it isn't watched.
    private func liveVerdict(for id: UUID, offset: Int) -> NEFilterDataVerdict {
        switch live.verdict(for: id, offset: offset) {
        case .pass(let bytes)?: return FilterVerdicts.pass(bytes)
        case .drop?: return FilterVerdicts.dropData()
        case .release?, nil: return FilterVerdicts.allowData()
        }
    }

    /// Resumes a flow paused for approval with the decided action.
    private func resumePaused(_ flow: NEFilterFlow, inspected: InspectedFlow, kind: ApprovalCoordinator.PauseKind, action: RuleAction) {
        let state = store.snapshot
        let verdict: NEFilterVerdict
        switch (kind, action) {
        case (.newFlow, .allow): verdict = allowedNewFlow(flow, inspected: inspected, state: state)
        case (.newFlow, .block): verdict = FilterVerdicts.dropNewFlow()
        case (.data, .allow): verdict = allowedData(flow, inspected: inspected, state: state, offset: 0)
        case (.data, .block): verdict = FilterVerdicts.dropData()
        }
        resumeFlow(flow, with: verdict)
    }

    // MARK: - Helpers

    /// Needs approval but no app can ask the user: apply the configured fallback
    /// (default allow, and the flow is still reported so the app can show it later).
    private func fallback(_ inspected: InspectedFlow) -> RuleAction {
        let action = coordinator.fallbackAction()
        Log.approval.debug(
            "No app connected; \(action.rawValue, privacy: .public) \(inspected.descriptor.app.matchKey, privacy: .public)")
        report(inspected, verdict: action == .allow ? .allowed : .blocked, matchedRuleID: nil)
        return action
    }

    private func report(_ inspected: InspectedFlow, verdict: Verdict, matchedRuleID: UUID?) {
        let flow = inspected.descriptor
        Log.flow.debug("""
            \(verdict.rawValue, privacy: .public) \(flow.app.matchKey, privacy: .public) \
            \(flow.host ?? "-", privacy: .public) \(flow.ip, privacy: .public):\(flow.port) \
            \(flow.proto.rawValue, privacy: .public) \(flow.direction.rawValue, privacy: .public) \
            via \(inspected.processPath ?? "-", privacy: .public)
            """)
        server.report(FlowEvents.make(inspected, verdict: verdict, matchedRuleID: matchedRuleID, now: Date()))
    }
}
