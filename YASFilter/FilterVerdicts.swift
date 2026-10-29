import Foundation
import NetworkExtension
import YASShared

/// Verdict factories. Every final verdict reports so the
/// provider gets `NEFilterReport` statistics for traffic accounting.
enum FilterVerdicts {
    static func allowNewFlow() -> NEFilterNewFlowVerdict {
        reporting(.allow())
    }

    static func dropNewFlow() -> NEFilterNewFlowVerdict {
        reporting(.drop())
    }

    /// Peek the first outbound bytes (TLS ClientHello). Inbound is filtered only
    /// when the flow will be watched live afterwards (`LiveFlowTable`): inbound
    /// filtering can't be switched on once the flow has started.
    static func peekClientHello(watchInbound: Bool) -> NEFilterNewFlowVerdict {
        reporting(.filterDataVerdict(
            withFilterInbound: watchInbound, peekInboundBytes: watchInbound ? LiveInspection.peekBytes : 0,
            filterOutbound: true, peekOutboundBytes: FlowPolicy.clientHelloPeekBytes))
    }

    /// Allowed, but watched in both directions so it can be cut if the rules
    /// change. The first data callback in each direction hands out a pass window.
    static func watchNewFlow() -> NEFilterNewFlowVerdict {
        reporting(.filterDataVerdict(
            withFilterInbound: true, peekInboundBytes: LiveInspection.peekBytes,
            filterOutbound: true, peekOutboundBytes: LiveInspection.peekBytes))
    }

    /// Let `bytes` through, then peek a little so we get the next callback.
    /// Not reporting: a report per window would cost an extra round trip per chunk;
    /// the new-flow verdict already enabled statistics and close reports.
    static func pass(_ bytes: Int) -> NEFilterDataVerdict {
        NEFilterDataVerdict(passBytes: bytes, peekBytes: LiveInspection.peekBytes)
    }

    /// Peek inbound DNS responses; outbound queries pass untouched.
    static func sniffDNS() -> NEFilterNewFlowVerdict {
        reporting(.filterDataVerdict(
            withFilterInbound: true, peekInboundBytes: FlowPolicy.dnsPeekBytes,
            filterOutbound: false, peekOutboundBytes: 0))
    }

    static func allowData() -> NEFilterDataVerdict {
        reporting(.allow())
    }

    static func dropData() -> NEFilterDataVerdict {
        reporting(.drop())
    }

    private static func reporting(_ verdict: NEFilterNewFlowVerdict) -> NEFilterNewFlowVerdict {
        verdict.shouldReport = true
        verdict.statisticsReportFrequency = .medium
        return verdict
    }

    private static func reporting(_ verdict: NEFilterDataVerdict) -> NEFilterDataVerdict {
        verdict.shouldReport = true
        verdict.statisticsReportFrequency = .medium
        return verdict
    }
}

enum FlowEvents {
    /// `id` defaults to the flow's identifier; pass a fresh one for a second event
    /// about the same flow (e.g. cut while live).
    static func make(
        _ inspected: InspectedFlow, id: UUID? = nil, verdict: Verdict, matchedRuleID: UUID?, now: Date
    ) -> FlowEvent {
        let flow = inspected.descriptor
        return FlowEvent(
            id: id ?? inspected.id,
            timestamp: now,
            app: flow.app,
            remoteHost: flow.host,
            remoteIP: flow.ip,
            remotePort: flow.port,
            proto: flow.proto,
            direction: flow.direction,
            verdict: verdict,
            matchedRuleID: matchedRuleID)
    }
}
