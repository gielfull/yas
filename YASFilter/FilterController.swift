import Foundation
import YASShared

/// Applies what the app sends over XPC. The app is the source of truth: it pushes
/// the mode and the full rule set on every connect, and they replace the cache.
final class FilterController: FilterControlHandler {
    private let store: RuleStore
    private let coordinator: ApprovalCoordinator
    /// Mode or rules changed: re-check open connections (`LiveFlowTable.sweep`).
    private let onPolicyChange: @Sendable () -> Void

    init(store: RuleStore, coordinator: ApprovalCoordinator, onPolicyChange: @escaping @Sendable () -> Void) {
        self.store = store
        self.coordinator = coordinator
        self.onPolicyChange = onPolicyChange
    }

    func clientDidRegister() {
        Log.provider.info("App connected; waiting for mode and rules")
    }

    func setMode(_ mode: FilterMode) {
        store.setMode(mode)
        Log.provider.notice("Mode set to \(mode.rawValue, privacy: .public)")
        coordinator.reevaluate()
        onPolicyChange()
    }

    func replaceRules(_ rules: [Rule]) {
        store.replaceRules(rules)
        Log.provider.info("Rules replaced: \(rules.count)")
        coordinator.reevaluate()
        onPolicyChange()
    }

    func resolveApproval(requestID: UUID, decision: ApprovalDecision) {
        coordinator.resolve(requestID: requestID, decision: decision)
    }

    func clientDidDisconnect() {
        coordinator.resumeAll(reason: "app disconnected")
    }
}
