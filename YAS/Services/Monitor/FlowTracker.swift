import Foundation
import YASShared

/// Turns successive socket scans into flows: a socket that appears is a new flow
/// (one `FlowEvent`), stays active while present, and is closed when it's gone.
struct FlowTracker {
    struct Key: Hashable, Sendable {
        let processKey: String
        let proto: TransportProtocol
        let localPort: Int
        let remoteIP: String
        let remotePort: Int
    }

    struct Update: Sendable {
        let appeared: [FlowEvent]
        /// Flows still open (including the ones that just appeared).
        let present: [UUID]
        let closed: [UUID]
    }

    private(set) var active: [Key: UUID] = [:]

    mutating func apply(_ observations: [SocketObservation], at now: Date, makeID: () -> UUID = UUID.init) -> Update {
        var seen: [Key: UUID] = [:]
        var appeared: [FlowEvent] = []
        for observation in observations {
            guard let remoteIP = observation.socket.remoteIP else { continue }
            let key = Key(
                processKey: observation.processKey, proto: observation.socket.proto,
                localPort: observation.socket.localPort, remoteIP: remoteIP, remotePort: observation.socket.remotePort)
            guard seen[key] == nil else { continue } // same socket shared by two fds
            if let id = active[key] {
                seen[key] = id
                continue
            }
            let id = makeID()
            seen[key] = id
            appeared.append(FlowEvent(
                id: id, timestamp: now, app: observation.app, remoteHost: nil, remoteIP: remoteIP,
                remotePort: observation.socket.remotePort, proto: observation.socket.proto,
                direction: observation.direction, verdict: .allowed, matchedRuleID: nil))
        }
        let closed = active.filter { seen[$0.key] == nil }.map(\.value)
        active = seen
        return Update(appeared: appeared, present: Array(seen.values), closed: closed)
    }

    mutating func reset() {
        active.removeAll()
    }
}
