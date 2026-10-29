import Foundation
import YASShared
import os

/// App side of the XPC contract: connects to the extension's mach
/// service, exports `FilterEventsProtocol`, pushes mode + rules on every connect,
/// and reconnects with exponential backoff.
@MainActor
final class XPCClient: NSObject {
    static let connectionDidChange = Notification.Name("YAS.XPCClient.connectionDidChange")

    private let store: Store
    private let logger = Logger(subsystem: "com.gful.yas", category: "XPC")
    private var connection: NSXPCConnection?
    private var isRunning = false
    private var backoff: TimeInterval = XPCClient.initialBackoff
    private var reconnectTask: Task<Void, Never>?
    /// Bumped on every new connection so callbacks from a dead one are ignored.
    private var generation = 0

    private static let initialBackoff: TimeInterval = 1
    private static let maxBackoff: TimeInterval = 60

    private(set) var isConnected = false {
        didSet {
            guard isConnected != oldValue else { return }
            NotificationCenter.default.post(name: Self.connectionDidChange, object: self)
        }
    }

    init(store: Store) {
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(rulesChanged), name: Store.rulesDidChange, object: store)
        NotificationCenter.default.addObserver(
            self, selector: #selector(modeChanged), name: Store.modeDidChange, object: store)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        backoff = Self.initialBackoff
        connect()
    }

    func stop() {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        connection?.invalidate()
        connection = nil
        isConnected = false
    }

    // MARK: - Commands

    func resolveApproval(_ request: ApprovalRequest, decision: ApprovalDecision) {
        guard let data = encode(decision) else { return }
        proxy()?.resolveApproval(request.requestID.uuidString, decisionJSON: data)
    }

    @objc private func rulesChanged() {
        pushRules()
    }

    @objc private func modeChanged() {
        pushMode()
    }

    private func pushRules() {
        guard isConnected, let data = encode(store.rules) else { return }
        let count = store.rules.count
        proxy()?.replaceRules(data) { @Sendable [logger] ok in
            if !ok { logger.error("Extension rejected \(count) rules") }
        }
    }

    private func pushMode() {
        guard isConnected else { return }
        let mode = store.mode
        proxy()?.setMode(mode.rawValue) { @Sendable [logger] ok in
            if !ok { logger.error("Extension rejected mode \(mode.rawValue, privacy: .public)") }
        }
    }

    // MARK: - Connection

    private func connect() {
        guard isRunning else { return }
        generation += 1
        let generation = generation

        let connection = NSXPCConnection(machServiceName: XPCConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FilterControlProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: FilterEventsProtocol.self)
        connection.exportedObject = EventsReceiver { [weak self] event in
            self?.handle(event)
        }
        // Only talk to our own extension once the app is signed with a team.
        if let teamID = CodeSignature.currentTeamID(),
           let requirement = XPCConstants.codeSigningRequirement(teamID: teamID, identifier: XPCConstants.filterBundleID) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.interruptionHandler = { @Sendable [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.connectionDropped(generation: generation, reason: "interrupted") }
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.connectionDropped(generation: generation, reason: "invalidated") }
            }
        }
        self.connection = connection
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let message = String(describing: error)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.connectionDropped(generation: generation, reason: message) }
            }
        } as? FilterControlProtocol
        proxy?.register { @Sendable [weak self] ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.registered(ok, generation: generation) }
            }
        }
    }

    private func registered(_ ok: Bool, generation: Int) {
        guard generation == self.generation else { return }
        guard ok else {
            logger.error("Extension refused registration")
            connection?.invalidate()
            return
        }
        logger.info("Connected to filter extension")
        backoff = Self.initialBackoff
        isConnected = true
        pushMode()
        pushRules()
    }

    private func connectionDropped(generation: Int, reason: String) {
        guard generation == self.generation else { return }
        logger.notice("XPC connection lost (\(reason, privacy: .public)); retrying in \(self.backoff)s")
        self.generation += 1
        connection?.invalidate()
        connection = nil
        isConnected = false
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        reconnectTask?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func proxy() -> FilterControlProtocol? {
        let generation = generation
        return connection?.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let message = String(describing: error)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.connectionDropped(generation: generation, reason: message) }
            }
        } as? FilterControlProtocol
    }

    private func encode<T: Encodable>(_ value: T) -> Data? {
        do {
            return try PayloadCoder.encode(value)
        } catch {
            logger.error("Encoding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Events

    enum Event: Sendable {
        case flows([FlowEvent])
        case stats([TrafficStat])
        case approval(ApprovalRequest)
    }

    private func handle(_ event: Event) {
        switch event {
        case .flows(let flows):
            store.ingest(flows)
        case .stats(let stats):
            store.apply(stats)
        case .approval(let request):
            store.enqueueApproval(request)
        }
    }
}

/// Exported to the extension. Decodes on the XPC queue, then delivers on main in
/// arrival order (a serial `DispatchQueue.main` hop, not a `Task`, which could reorder).
private final class EventsReceiver: NSObject, FilterEventsProtocol, Sendable {
    private let sink: @MainActor @Sendable (XPCClient.Event) -> Void
    private let logger = Logger(subsystem: "com.gful.yas", category: "XPC")

    init(sink: @escaping @MainActor @Sendable (XPCClient.Event) -> Void) {
        self.sink = sink
    }

    func flowsObserved(_ batchJSON: Data) {
        deliver { .flows(try PayloadCoder.decode([FlowEvent].self, from: batchJSON)) }
    }

    func trafficStats(_ statsJSON: Data) {
        deliver { .stats(try PayloadCoder.decode([TrafficStat].self, from: statsJSON)) }
    }

    func approvalRequested(_ requestJSON: Data) {
        deliver { .approval(try PayloadCoder.decode(ApprovalRequest.self, from: requestJSON)) }
    }

    private func deliver(_ decode: () throws -> XPCClient.Event) {
        let event: XPCClient.Event
        do {
            event = try decode()
        } catch {
            logger.error("Dropping undecodable payload: \(String(describing: error), privacy: .public)")
            return
        }
        let sink = sink
        DispatchQueue.main.async {
            MainActor.assumeIsolated { sink(event) }
        }
    }
}
