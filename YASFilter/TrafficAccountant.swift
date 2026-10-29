import Foundation
import YASShared

/// Turns `NEFilterReport` byte counts into per-flow deltas (`TrafficStat`).
///
/// Assumes the report counts are cumulative for the flow's lifetime. If a count
/// ever goes backwards the flow is treated as restarted and the new count is the
/// delta. Not thread-safe; wrap it in a lock.
struct TrafficAccountant: Sendable {
    private var totals: BoundedCache<UUID, (inbound: UInt64, outbound: UInt64)>

    /// - Parameter capacity: flows tracked at once; the oldest is forgotten beyond
    ///   it (only matters if the system never reports a flow closed).
    init(capacity: Int = 16_384) {
        totals = BoundedCache(capacity: capacity)
    }

    var trackedFlowCount: Int { totals.count }

    /// Records a report and returns the delta since the previous one, or nil if
    /// nothing moved.
    mutating func record(
        flowID: UUID,
        inboundTotal: UInt64,
        outboundTotal: UInt64,
        isClosed: Bool,
        now: Date
    ) -> TrafficStat? {
        let previous = totals[flowID] ?? (0, 0)
        let inDelta = inboundTotal >= previous.inbound ? inboundTotal - previous.inbound : inboundTotal
        let outDelta = outboundTotal >= previous.outbound ? outboundTotal - previous.outbound : outboundTotal
        if isClosed {
            totals.removeValue(for: flowID)
        } else {
            totals[flowID] = (inboundTotal, outboundTotal)
        }
        guard inDelta > 0 || outDelta > 0 else { return nil }
        return TrafficStat(flowID: flowID, bytesInDelta: inDelta, bytesOutDelta: outDelta, timestamp: now)
    }

    mutating func forget(flowID: UUID) {
        totals.removeValue(for: flowID)
    }
}
