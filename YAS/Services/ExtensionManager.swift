import AppKit
import NetworkExtension
import YASShared
import os
import SystemExtensions

/// Installs the system extension and drives the content filter configuration.
/// Posts `stateDidChange` on main whenever `state` changes.
@MainActor
final class ExtensionManager: NSObject {
    enum State: Equatable, Sendable {
        case unknown
        case notInstalled
        case needsUserApproval
        case activating
        case enabled
        case disabled
        case error(String)

        var localizedDescription: String {
            switch self {
            case .unknown: String(localized: "Checking…")
            case .notInstalled: String(localized: "Not installed")
            case .needsUserApproval: String(localized: "Waiting for approval in System Settings")
            case .activating: String(localized: "Activating…")
            case .enabled: String(localized: "Filter enabled")
            case .disabled: String(localized: "Filter disabled")
            case .error(let message): message
            }
        }
    }

    static let stateDidChange = Notification.Name("YAS.ExtensionManager.stateDidChange")

    /// System Settings > General > Login Items & Extensions.
    static let extensionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    private(set) var state: State = .unknown {
        didSet {
            guard state != oldValue else { return }
            logger.info("Extension state: \(String(describing: self.state), privacy: .public)")
            NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        }
    }

    /// True once the system extension reported itself activated (or a filter
    /// configuration exists, which implies it was).
    private(set) var isExtensionInstalled = false
    private(set) var isFilterConfigured = false

    private let logger = Logger(subsystem: "com.gful.yas", category: "ExtensionManager")
    private var configurationObserver: NSObjectProtocol?
    /// Whether the in-flight activation should enable the filter when it finishes.
    private var enableAfterActivation = false
    /// Delegate callbacks don't say which kind of request finished; track them.
    private var activationRequests: Set<ObjectIdentifier> = []
    private var deactivationRequests: Set<ObjectIdentifier> = []

    var isRunningFromApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    override init() {
        super.init()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .NEFilterConfigurationDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    // MARK: - Status

    /// Re-reads the filter configuration and the extension's install state.
    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        do {
            let snapshot = try await Self.loadFilterSnapshot()
            isFilterConfigured = snapshot.isConfigured
            if snapshot.isConfigured {
                isExtensionInstalled = true
                state = snapshot.isEnabled ? .enabled : .disabled
                return
            }
        } catch {
            logger.error("loadFromPreferences failed: \(String(describing: error), privacy: .public)")
            if state == .unknown { state = .error(Self.describe(error)) }
        }
        // No filter configuration: ask the system whether the extension is installed.
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: XPCConstants.filterBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - Install / uninstall

    /// Activates the extension, then configures and enables the filter.
    func install() {
        guard isRunningFromApplications else {
            offerMoveToApplications()
            return
        }
        enableAfterActivation = true
        state = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: XPCConstants.filterBundleID, queue: .main)
        request.delegate = self
        activationRequests.insert(ObjectIdentifier(request))
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        enableAfterActivation = false
        Task {
            // Remove the configuration first so nothing points at a missing provider.
            try? await Self.removeFilterConfiguration()
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: XPCConstants.filterBundleID, queue: .main)
            request.delegate = self
            deactivationRequests.insert(ObjectIdentifier(request))
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    // MARK: - Filter on/off (kill switch)

    func enableFilter() {
        Task {
            do {
                try await Self.saveFilterConfiguration(enabled: true)
            } catch {
                logger.error("Enabling the filter failed: \(String(describing: error), privacy: .public)")
                state = .error(Self.describe(error))
            }
            await refreshNow()
        }
    }

    /// Kill switch: must keep working whatever state the extension is in.
    func disableFilter() {
        Task {
            do {
                try await Self.saveFilterConfiguration(enabled: false)
            } catch {
                logger.error("Disabling the filter failed: \(String(describing: error), privacy: .public)")
                state = .error(Self.describe(error))
            }
            await refreshNow()
        }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.extensionSettingsURL)
    }

    // MARK: - /Applications

    /// System extensions only activate from /Applications.
    func offerMoveToApplications() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Move YAS to the Applications folder?")
        alert.informativeText = String(localized: "macOS only activates network extensions for apps in /Applications. YAS will relaunch from there.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { @Sendable _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - NEFilterManager (nonisolated: the manager is not Sendable)

    private struct FilterSnapshot: Sendable {
        let isConfigured: Bool
        let isEnabled: Bool
    }

    private nonisolated static func loadFilterSnapshot() async throws -> FilterSnapshot {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        return FilterSnapshot(isConfigured: manager.providerConfiguration != nil, isEnabled: manager.isEnabled)
    }

    private nonisolated static func saveFilterConfiguration(enabled: Bool) async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        if manager.providerConfiguration == nil {
            guard enabled else { return }
            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterPackets = false
            configuration.filterDataProviderBundleIdentifier = XPCConstants.filterBundleID
            manager.providerConfiguration = configuration
        }
        manager.localizedDescription = "YAS"
        manager.isEnabled = enabled
        try await manager.saveToPreferences()
    }

    private nonisolated static func removeFilterConfiguration() async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        guard manager.providerConfiguration != nil else { return }
        try await manager.removeFromPreferences()
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEFilterErrorDomain {
            return String(localized: "The content filter configuration could not be changed. Is the app signed with the Network Extension entitlement?")
        }
        return nsError.localizedDescription
    }

    // MARK: - Delegate outcomes (main actor)

    private func activationFinished(_ result: OSSystemExtensionRequest.Result) {
        isExtensionInstalled = true
        switch result {
        case .completed:
            if enableAfterActivation {
                enableAfterActivation = false
                enableFilter()
            } else {
                refresh()
            }
        case .willCompleteAfterReboot:
            state = .error(String(localized: "Restart your Mac to finish installing the extension."))
        @unknown default:
            refresh()
        }
    }

    private func deactivationFinished() {
        isExtensionInstalled = false
        isFilterConfigured = false
        state = .notInstalled
    }

    private func requestFinished(_ id: ObjectIdentifier, result: OSSystemExtensionRequest.Result) {
        if deactivationRequests.remove(id) != nil {
            deactivationFinished()
        } else if activationRequests.remove(id) != nil {
            activationFinished(result)
        }
    }

    private func requestFailed(_ id: ObjectIdentifier, error: Error) {
        activationRequests.remove(id)
        deactivationRequests.remove(id)
        logger.error("System extension request failed: \(String(describing: error), privacy: .public)")
        enableAfterActivation = false
        let nsError = error as NSError
        if nsError.domain == OSSystemExtensionErrorDomain,
           nsError.code == OSSystemExtensionError.extensionNotFound.rawValue {
            state = .notInstalled
            return
        }
        state = .error(nsError.localizedDescription)
    }

    private func propertiesFound(installed: Bool, enabled: Bool, awaitingApproval: Bool) {
        isExtensionInstalled = installed
        if awaitingApproval {
            state = .needsUserApproval
        } else if installed {
            state = isFilterConfigured ? (enabled ? .enabled : .disabled) : .disabled
        } else {
            state = .notInstalled
        }
    }
}

// Requests are submitted with `queue: .main`, so every callback arrives on the main thread.
extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            state = .needsUserApproval
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            requestFinished(id, result: result)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            requestFailed(id, error: error)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let matching = properties.filter { !$0.isUninstalling }
        let installed = !matching.isEmpty
        let enabled = matching.contains { $0.isEnabled }
        let awaiting = matching.contains { $0.isAwaitingUserApproval }
        MainActor.assumeIsolated {
            propertiesFound(installed: installed, enabled: enabled, awaitingApproval: awaiting)
        }
    }
}
