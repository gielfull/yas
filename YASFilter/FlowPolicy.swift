import Foundation
import YASShared

/// What the filter knows about a flow at a given moment.
struct InspectedFlow: Sendable {
    /// `NEFilterFlow.identifier`; also the `FlowEvent.id` and `TrafficStat.flowID`.
    let id: UUID
    var descriptor: FlowDescriptor
    /// Executable of the process that actually opened the socket, when it is a
    /// different process from `descriptor.app` (e.g. a system daemon acting for
    /// the app). Logged only: `FlowEvent` has no field for it yet.
    let processPath: String?
}

/// What the provider should do with a flow. Pure: no NetworkExtension types, so it
/// can be tested without a running filter.
enum FlowPlan: Hashable, Sendable {
    case allow(matchedRuleID: UUID?)
    case block(matchedRuleID: UUID?)
    /// Pause and ask the user (`ApprovalCoordinator`).
    case needsApproval
    /// Peek the first outbound bytes for a TLS ClientHello, then decide.
    case peekClientHello
    /// DNS: always allowed; inbound responses feed the DNS cache.
    case sniffDNS
}

enum FlowPolicy {
    /// First outbound peek. Chrome's post-quantum ClientHello is ~2 KB and it
    /// randomizes extension order, so SNI can sit near the end of it.
    static let clientHelloPeekBytes = 2_048
    /// Largest TLS record we'll wait for (header + 2^14 payload).
    static let maxClientHelloBytes = 5 + 16_384
    /// Extra peeks allowed while a ClientHello record is still arriving.
    static let maxClientHelloRetries = 3
    /// Inbound peek per DNS read. Covers any UDP answer without EDNS jumbo sizes.
    static let dnsPeekBytes = 4_096
    /// DNS responses parsed per flow before the flow is simply allowed.
    static let maxDNSResponsesPerFlow = 64

    static func isDNS(_ flow: FlowDescriptor) -> Bool {
        flow.port == 53 && flow.direction == .outbound
    }

    /// Only outbound TCP carries our ClientHello. UDP 443 (QUIC) encrypts it, so
    /// those flows get IP + DNS cache only.
    static func canPeekClientHello(_ flow: FlowDescriptor) -> Bool {
        flow.proto == .tcp && flow.direction == .outbound && flow.host == nil
    }

    /// Decides the verdict shape at `handleNewFlow` time.
    ///
    /// Unknown-host outbound TCP is peeked even when the rules don't depend on the
    /// host: the hostname is what the user sees in the UI and in approval prompts.
    /// `allowAll` is the kill-switch-adjacent fast path: no rules, no peeking.
    static func plan(
        for flow: FlowDescriptor,
        mode: FilterMode,
        rules: [Rule],
        options: EngineOptions = .default
    ) -> FlowPlan {
        if isDNS(flow) { return .sniffDNS }
        if mode == .allowAll { return .allow(matchedRuleID: nil) }

        let peekable = canPeekClientHello(flow)
        let evaluation = RuleEngine.evaluate(
            flow, mode: mode, rules: rules, options: options, hostIsFinal: !peekable)
        switch evaluation.decision {
        case .block:
            return .block(matchedRuleID: evaluation.matchedRuleID)
        case .needsMoreData:
            return .peekClientHello
        case .allow:
            return peekable ? .peekClientHello : .allow(matchedRuleID: evaluation.matchedRuleID)
        case .needsApproval:
            return peekable ? .peekClientHello : .needsApproval
        }
    }

    /// Final decision once no more hostname sources are available (after peeking).
    static func finalPlan(
        for flow: FlowDescriptor,
        mode: FilterMode,
        rules: [Rule],
        options: EngineOptions = .default
    ) -> FlowPlan {
        if mode == .allowAll { return .allow(matchedRuleID: nil) }
        let evaluation = RuleEngine.evaluate(
            flow, mode: mode, rules: rules, options: options, hostIsFinal: true)
        switch evaluation.decision {
        case .block:
            return .block(matchedRuleID: evaluation.matchedRuleID)
        case .allow, .needsMoreData:
            // needsMoreData cannot happen with hostIsFinal; fail open if it ever does.
            return .allow(matchedRuleID: evaluation.matchedRuleID)
        case .needsApproval:
            return .needsApproval
        }
    }

    /// If `data` starts with a TLS handshake record that is not complete yet, the
    /// total number of bytes needed to hold the whole record; otherwise nil.
    static func clientHelloBytesNeeded(_ data: Data) -> Int? {
        guard data.count >= 5 else {
            // Too short to tell; wait only if what we have looks like TLS.
            let prefix = [UInt8](data.prefix(2))
            let looksLikeTLS = prefix.first == 0x16 && (prefix.count < 2 || prefix[1] == 0x03)
            return looksLikeTLS && !data.isEmpty ? clientHelloPeekBytes : nil
        }
        let bytes = [UInt8](data.prefix(5))
        guard bytes[0] == 0x16, bytes[1] == 0x03 else { return nil }
        let recordLength = Int(bytes[3]) << 8 | Int(bytes[4])
        let total = 5 + recordLength
        guard total > data.count else { return nil }
        return min(total, maxClientHelloBytes)
    }

    /// Canonical IP string for display and DNS-cache lookups: strips an IPv6 scope
    /// (`fe80::1%en0`) and unwraps IPv4-mapped IPv6 (`::ffff:1.2.3.4`).
    static func normalizeIP(_ ip: String) -> String {
        var ip = ip
        if let percent = ip.firstIndex(of: "%") {
            ip = String(ip[..<percent])
        }
        let lower = ip.lowercased()
        if lower.hasPrefix("::ffff:"), lower.dropFirst(7).contains(".") {
            return String(lower.dropFirst(7))
        }
        return lower
    }

    /// Whether `host` is an IP literal rather than a name (then it is no hostname).
    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let bare = normalizeIP(host)
        return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
    }
}
