import Foundation
import YASShared
import os
import Security

/// Callbacks from the app, delivered by `FilterControlService`.
protocol FilterControlHandler: AnyObject, Sendable {
    func clientDidRegister()
    func setMode(_ mode: FilterMode)
    func replaceRules(_ rules: [Rule])
    func resolveApproval(requestID: UUID, decision: ApprovalDecision)
    /// The registered app went away. Paused flows must not wait for it.
    func clientDidDisconnect()
}

/// Mach-service XPC listener for the host app.
///
/// Accepts only clients that satisfy a code-signing requirement for the app's
/// identifier and Team ID. The most recently registered connection is "the client":
/// it receives flow events (batched every 250 ms), traffic stats and approval
/// requests.
///
/// `@unchecked Sendable`: every mutable property (connections, buffers, the flush
/// flag) is only touched on `queue`. The one value the filter path reads
/// synchronously, `hasClient`, lives in its own lock.
final class XPCServer: NSObject, NSXPCListenerDelegate, FilterEventSink, @unchecked Sendable {
    static let flushInterval: DispatchTimeInterval = .milliseconds(250)

    private let queue = DispatchQueue(label: "com.gful.yas.filter.xpc")
    private let clientPresent = OSAllocatedUnfairLock(initialState: false)
    private let requirement: String?

    // Confined to `queue`.
    private var listener: NSXPCListener?
    private var connections: [UUID: NSXPCConnection] = [:]
    private var clientID: UUID?
    private var flowEvents = EventBuffer<FlowEvent>(capacity: 5_000)
    private var trafficStats = EventBuffer<TrafficStat>(capacity: 5_000)
    private var flushScheduled = false
    private weak var handler: FilterControlHandler?

    override init() {
        requirement = Self.makeClientRequirement()
        super.init()
    }

    var hasClient: Bool { clientPresent.withLock { $0 } }

    func start(handler: FilterControlHandler) {
        queue.sync {
            self.handler = handler
            guard listener == nil else { return }
            let listener = NSXPCListener(machServiceName: XPCConstants.machServiceName)
            listener.delegate = self
            listener.resume()
            self.listener = listener
            Log.xpc.info("Listening on \(XPCConstants.machServiceName, privacy: .public)")
        }
    }

    func stop() {
        let (listener, open): (NSXPCListener?, [NSXPCConnection]) = queue.sync {
            defer {
                self.listener = nil
                connections.removeAll()
                clientID = nil
                clientPresent.withLock { $0 = false }
            }
            return (self.listener, Array(connections.values))
        }
        // Outside `queue`: invalidation handlers hop onto it.
        listener?.invalidate()
        open.forEach { $0.invalidate() }
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let requirement else {
            Log.xpc.error("Rejecting XPC client pid \(newConnection.processIdentifier): no code-signing requirement available")
            return false
        }
        // Enforced by the system on every message; a mismatch invalidates the connection.
        newConnection.setCodeSigningRequirement(requirement)

        let id = UUID()
        newConnection.exportedInterface = NSXPCInterface(with: FilterControlProtocol.self)
        newConnection.exportedObject = FilterControlService(server: self, connectionID: id)
        newConnection.remoteObjectInterface = NSXPCInterface(with: FilterEventsProtocol.self)
        newConnection.invalidationHandler = { [weak self] in
            self?.connectionEnded(id, reason: "invalidated")
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.connectionEnded(id, reason: "interrupted")
        }
        queue.sync { connections[id] = newConnection }
        newConnection.resume()
        Log.xpc.info("Accepted XPC connection from pid \(newConnection.processIdentifier)")
        return true
    }

    // MARK: - Calls from the app (via FilterControlService)

    fileprivate func register(connectionID: UUID) -> Bool {
        let (accepted, handler): (Bool, FilterControlHandler?) = queue.sync {
            guard connections[connectionID] != nil else { return (false, nil) }
            clientID = connectionID
            clientPresent.withLock { $0 = true }
            scheduleFlush()
            return (true, self.handler)
        }
        if accepted {
            Log.xpc.info("App registered")
            handler?.clientDidRegister()
        }
        return accepted
    }

    fileprivate var controlHandler: FilterControlHandler? {
        queue.sync { handler }
    }

    private func connectionEnded(_ id: UUID, reason: String) {
        let (connection, wasClient, handler): (NSXPCConnection?, Bool, FilterControlHandler?) = queue.sync {
            let connection = connections.removeValue(forKey: id)
            guard clientID == id else { return (connection, false, nil) }
            clientID = nil
            clientPresent.withLock { $0 = false }
            return (connection, true, self.handler)
        }
        // Interruption leaves the connection object usable, but the app reconnects
        // with a fresh one, so drop it either way.
        if reason == "interrupted" { connection?.invalidate() }
        guard wasClient else { return }
        Log.xpc.notice("App connection \(reason, privacy: .public)")
        handler?.clientDidDisconnect()
    }

    // MARK: - FilterEventSink

    func report(_ event: FlowEvent) {
        queue.async { [self] in
            flowEvents.append(event)
            scheduleFlush()
        }
    }

    func report(_ stat: TrafficStat) {
        queue.async { [self] in
            trafficStats.append(stat)
            scheduleFlush()
        }
    }

    func requestApproval(_ request: ApprovalRequest) {
        queue.async { [self] in
            guard let proxy = clientProxy() else {
                Log.approval.error("No app to show approval request \(request.requestID, privacy: .public)")
                return
            }
            do {
                proxy.approvalRequested(try PayloadCoder.encode(request))
            } catch {
                Log.xpc.error("Could not encode approval request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Batching (on `queue`)

    private func scheduleFlush() {
        guard !flushScheduled, clientID != nil, !(flowEvents.isEmpty && trafficStats.isEmpty) else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.flushInterval) { [self] in
            flushScheduled = false
            flush()
        }
    }

    /// Sends buffered events to the client. Without a client they stay buffered
    /// (bounded) until one registers.
    private func flush() {
        guard let proxy = clientProxy() else { return }
        let events = flowEvents.drain()
        let stats = trafficStats.drain()
        if events.dropped + stats.dropped > 0 {
            Log.xpc.notice("Dropped \(events.dropped) flow events and \(stats.dropped) stats while buffering")
        }
        do {
            if !events.items.isEmpty {
                proxy.flowsObserved(try PayloadCoder.encode(events.items))
            }
            if !stats.items.isEmpty {
                proxy.trafficStats(try PayloadCoder.encode(stats.items))
            }
        } catch {
            Log.xpc.error("Could not encode event batch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func clientProxy() -> FilterEventsProtocol? {
        guard let clientID, let connection = connections[clientID] else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { error in
            Log.xpc.error("Sending to app failed: \(error.localizedDescription, privacy: .public)")
        } as? FilterEventsProtocol
    }

    // MARK: - Client validation

    /// Requirement for the app: Apple-issued certificate for our Team ID and the
    /// app's bundle ID. The Team ID is read from the extension's own signature,
    /// since app and extension are always signed by the same team.
    private static func makeClientRequirement() -> String? {
        if let teamID = AppIdentityResolver.ownTeamID(),
           let requirement = XPCConstants.codeSigningRequirement(teamID: teamID) {
            Log.xpc.info("Client requirement: \(requirement, privacy: .public)")
            return requirement
        }
        #if DEBUG
        // Unsigned / ad-hoc development builds have no Team ID. Anyone can ad-hoc
        // sign a binary with this identifier, so this must never ship.
        let requirement = "identifier \"\(XPCConstants.appBundleID)\""
        Log.xpc.fault(
            "DEBUG BUILD WITHOUT TEAM ID: accepting ANY XPC client signed as \(XPCConstants.appBundleID, privacy: .public). Never ship this.")
        return requirement
        #else
        Log.xpc.fault("Extension has no Team ID; all XPC clients will be rejected")
        return nil
        #endif
    }
}

/// Object exported to the app on each connection. Decodes payloads, validates
/// them, and forwards to the handler.
final class FilterControlService: NSObject, FilterControlProtocol, Sendable {
    private let server: XPCServer
    private let connectionID: UUID

    fileprivate init(server: XPCServer, connectionID: UUID) {
        self.server = server
        self.connectionID = connectionID
    }

    func register(reply: @escaping @Sendable (Bool) -> Void) {
        reply(server.register(connectionID: connectionID))
    }

    func setMode(_ mode: String, reply: @escaping @Sendable (Bool) -> Void) {
        guard let mode = FilterMode(rawValue: mode), let handler = server.controlHandler else {
            Log.xpc.error("Rejected setMode(\(mode, privacy: .public))")
            reply(false)
            return
        }
        handler.setMode(mode)
        reply(true)
    }

    func replaceRules(_ rulesJSON: Data, reply: @escaping @Sendable (Bool) -> Void) {
        guard let handler = server.controlHandler else {
            reply(false)
            return
        }
        do {
            let rules = try PayloadCoder.decode([Rule].self, from: rulesJSON)
            handler.replaceRules(rules)
            reply(true)
        } catch {
            Log.xpc.error("Rejected replaceRules: \(error.localizedDescription, privacy: .public)")
            reply(false)
        }
    }

    func resolveApproval(_ requestID: String, decisionJSON: Data) {
        guard let id = UUID(uuidString: requestID),
              let decision = try? PayloadCoder.decode(ApprovalDecision.self, from: decisionJSON)
        else {
            Log.xpc.error("Rejected malformed approval decision for \(requestID, privacy: .public)")
            return
        }
        server.controlHandler?.resolveApproval(requestID: id, decision: decision)
    }
}
