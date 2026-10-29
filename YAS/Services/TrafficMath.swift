import Foundation
import YASShared

/// Time range of the Traffic window, with the slot size used to aggregate buckets.
enum TrafficRange: Int, CaseIterable, Sendable {
    case hour, day, week

    var span: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }

    /// Seconds per chart slot: 1 minute, 15 minutes, 1 hour.
    var step: Int {
        switch self {
        case .hour: 60
        case .day: 900
        case .week: 3600
        }
    }

    var shortTitle: String {
        switch self {
        case .hour: String(localized: "1h")
        case .day: String(localized: "24h")
        case .week: String(localized: "7d")
        }
    }

    /// [start, end) for a chart ending at the slot containing `now`.
    func window(now: Date) -> (start: Date, end: Date) {
        let end = TrafficSeries.slotStart(now, step: step).addingTimeInterval(TimeInterval(step))
        return (end.addingTimeInterval(-span), end)
    }
}

enum TrafficSeries {
    /// Start of the `step`-second slot containing `date` (slots aligned to the epoch).
    static func slotStart(_ date: Date, step: Int) -> Date {
        let seconds = (date.timeIntervalSince1970 / Double(step)).rounded(.down) * Double(step)
        return Date(timeIntervalSince1970: seconds)
    }

    /// One point per slot in [start, end), zero where `points` has none.
    static func filled(_ points: [TrafficPoint], from start: Date, to end: Date, step: Int) -> [TrafficPoint] {
        let byStart = Dictionary(points.map { ($0.start, $0) }, uniquingKeysWith: { lhs, rhs in
            TrafficPoint(start: lhs.start, bytesIn: lhs.bytesIn &+ rhs.bytesIn, bytesOut: lhs.bytesOut &+ rhs.bytesOut)
        })
        var result: [TrafficPoint] = []
        var slot = slotStart(start, step: step)
        while slot < end {
            result.append(byStart[slot] ?? TrafficPoint(start: slot, bytesIn: 0, bytesOut: 0))
            slot = slot.addingTimeInterval(TimeInterval(step))
        }
        return result
    }
}

/// Y axis scale: a "nice" upper bound and tick step (1, 2, 2.5, 5 × 10ⁿ).
enum ChartScale {
    struct Axis: Equatable {
        let upper: Double
        let step: Double

        var ticks: [Double] {
            guard step > 0 else { return [0] }
            return stride(from: 0, through: upper + step / 2, by: step).map { $0 }
        }
    }

    static func axis(forMaximum maximum: Double, targetTicks: Int = 4) -> Axis {
        guard maximum > 0, maximum.isFinite, targetTicks > 0 else { return Axis(upper: 1000, step: 250) }
        let rough = maximum / Double(targetTicks)
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let normalized = rough / magnitude
        let multiplier = [1, 2, 2.5, 5, 10].first { normalized <= $0 + 1e-9 } ?? 10
        let step = multiplier * magnitude
        let upper = (maximum / step).rounded(.up) * step
        return Axis(upper: upper, step: step)
    }
}

/// One row of the Traffic window's per-app table (helpers folded into their app).
struct AppTrafficShare: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let executablePath: String
    var identities: [AppIdentity]
    var bytesIn: UInt64
    var bytesOut: UInt64
    var connections: Int
    /// Fraction of all apps' bytes in the range, 0...1.
    var share: Double

    var total: UInt64 { bytesIn &+ bytesOut }
}

enum TrafficShares {
    /// Groups identities by `groupKey`, sums them, computes each group's share of the
    /// grand total, and sorts by total (then name).
    static func compute(
        _ rows: [AppTraffic],
        groupKey: (AppIdentity) -> String,
        name: (AppTraffic) -> String
    ) -> [AppTrafficShare] {
        var groups: [String: AppTrafficShare] = [:]
        var order: [String] = []
        for row in rows {
            let key = groupKey(row.identity)
            if var group = groups[key] {
                group.identities.append(row.identity)
                group.bytesIn &+= row.bytesIn
                group.bytesOut &+= row.bytesOut
                group.connections += row.connections
                groups[key] = group
            } else {
                order.append(key)
                groups[key] = AppTrafficShare(
                    id: key, name: name(row), executablePath: row.identity.executablePath,
                    identities: [row.identity], bytesIn: row.bytesIn, bytesOut: row.bytesOut,
                    connections: row.connections, share: 0)
            }
        }
        let grandTotal = groups.values.reduce(0.0) { $0 + Double($1.total) }
        return order.compactMap { groups[$0] }
            .map { group in
                var group = group
                group.share = grandTotal > 0 ? Double(group.total) / grandTotal : 0
                return group
            }
            .sorted { lhs, rhs in
                lhs.total != rhs.total ? lhs.total > rhs.total
                    : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
