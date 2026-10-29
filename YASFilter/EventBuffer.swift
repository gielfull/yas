import Foundation
import YASShared

/// Where the filter sends what it observes. Implemented by `XPCServer`; every
/// method is non-blocking and safe to call from the filter path.
protocol FilterEventSink: Sendable {
    /// Whether an app is connected and registered, i.e. approval prompts can be shown.
    var hasClient: Bool { get }
    func report(_ event: FlowEvent)
    func report(_ stat: TrafficStat)
    /// Sent immediately, not batched. Re-sent with the same `requestID` when the
    /// request gains destinations.
    func requestApproval(_ request: ApprovalRequest)
}

/// FIFO buffer that keeps about `capacity` items, dropping the oldest.
/// Holds flow events and traffic stats between 250 ms flushes. Trims in chunks
/// (it may briefly hold 25% more) so a flood costs O(1) amortized per append.
struct EventBuffer<Element: Sendable>: Sendable {
    let capacity: Int
    private(set) var items: [Element] = []
    private(set) var droppedCount = 0

    init(capacity: Int) {
        precondition(capacity > 0, "EventBuffer capacity must be positive")
        self.capacity = capacity
    }

    var isEmpty: Bool { items.isEmpty }

    mutating func append(_ element: Element) {
        items.append(element)
        if items.count > capacity + max(1, capacity / 4) {
            let overflow = items.count - capacity
            items.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    /// Returns everything buffered and the number dropped since the last drain.
    mutating func drain() -> (items: [Element], dropped: Int) {
        defer {
            items.removeAll(keepingCapacity: true)
            droppedCount = 0
        }
        return (items, droppedCount)
    }
}
