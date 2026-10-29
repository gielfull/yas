import Foundation
import YASShared

/// How long a Disconnect lasts.
enum DisconnectDuration: CaseIterable, Sendable {
    case untilUndone
    case fiveMinutes
    case fifteenMinutes
    case oneHour
    /// Until the next local midnight.
    case untilTomorrow

    /// When the block rule expires; nil = until Reconnect.
    func expiry(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .untilUndone: return nil
        case .fiveMinutes: return now.addingTimeInterval(5 * 60)
        case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
        case .oneHour: return now.addingTimeInterval(3600)
        case .untilTomorrow:
            // Calendar math (not +24 h) so DST days are handled; if midnight doesn't
            // exist that day, the first moment after it.
            return calendar.nextDate(
                after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime, direction: .forward)
        }
    }

    var menuTitle: String {
        switch self {
        case .untilUndone: String(localized: "Disconnect")
        case .fiveMinutes: String(localized: "Disconnect for 5 Minutes")
        case .fifteenMinutes: String(localized: "Disconnect for 15 Minutes")
        case .oneHour: String(localized: "Disconnect for 1 Hour")
        case .untilTomorrow: String(localized: "Disconnect Until Tomorrow")
        }
    }
}

/// A Disconnect in effect for an app or process.
struct DisconnectStatus: Hashable, Sendable {
    /// Nil = until Reconnect.
    let expiresAt: Date?
    /// Other enabled block rules that also cover it (Reconnect won't lift those).
    let otherBlockingRules: Int
}

enum DisconnectCountdown {
    /// "12m", "1h 5m", "<1m": time left, rounded up to the minute.
    static func remaining(until expiry: Date, now: Date) -> String {
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 60 else { return String(localized: "<1m") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? String(localized: "\(hours)h") : String(localized: "\(hours)h \(rest)m")
    }
}

extension Store {
    /// Stored in the rule's note so the Rules window shows where it came from.
    static var disconnectNote: String { String(localized: "Created by Disconnect") }

    /// Disconnect rules that target any of `identities` (including expired ones not yet purged).
    func disconnectRules(for identities: [AppIdentity]) -> [Rule] {
        let keys = Set(identities.map(\.matchKey))
        return rules.filter { rule in
            guard disconnectRuleIDs.contains(rule.id), case .app(let identity) = rule.target else { return false }
            return keys.contains(identity.matchKey)
        }
    }

    /// In effect when every identity has a live Disconnect rule. The expiry shown is
    /// the latest among them (until-undone wins).
    func disconnectStatus(for identities: [AppIdentity], now: Date = Date()) -> DisconnectStatus? {
        guard !identities.isEmpty else { return nil }
        let live = disconnectRules(for: identities).filter { $0.isInEffect(at: now) }
        let covered = Set(live.compactMap { rule -> String? in
            if case .app(let identity) = rule.target { return identity.matchKey }
            return nil
        })
        guard Set(identities.map(\.matchKey)).isSubset(of: covered) else { return nil }
        let expiry: Date? = live.contains { $0.expiresAt == nil } ? nil : live.compactMap(\.expiresAt).max()
        return DisconnectStatus(expiresAt: expiry, otherBlockingRules: otherBlockingRules(for: identities, now: now).count)
    }

    /// Enabled block rules for these identities that Disconnect didn't create.
    func otherBlockingRules(for identities: [AppIdentity], now: Date = Date()) -> [Rule] {
        let keys = Set(identities.map(\.matchKey))
        return rules.filter { rule in
            guard rule.action == .block, rule.isInEffect(at: now), !disconnectRuleIDs.contains(rule.id) else { return false }
            switch rule.target {
            case .app(let identity): return keys.contains(identity.matchKey)
            case .appDomain, .domain: return false
            }
        }
    }

    /// Blocks every identity (replacing earlier Disconnect rules for them). Returns the new rules.
    @discardableResult
    func disconnect(
        _ identities: [AppIdentity], for duration: DisconnectDuration,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [Rule] {
        var seen = Set<String>()
        let created = identities.filter { seen.insert($0.matchKey).inserted }.map {
            Rule(target: .app($0), action: .block, createdAt: now, note: Self.disconnectNote,
                 expiresAt: duration.expiry(from: now, calendar: calendar))
        }
        replaceDisconnectRules(for: identities, with: created)
        return created
    }

    /// Removes exactly the Disconnect rules for these identities. Returns what was removed.
    @discardableResult
    func reconnect(_ identities: [AppIdentity]) -> [Rule] {
        let removed = disconnectRules(for: identities)
        replaceDisconnectRules(for: identities, with: [])
        return removed
    }

    /// Registers an undo that puts back `rules` as the Disconnect rules for `identities`;
    /// undoing registers the inverse, so redo works too.
    func registerDisconnectUndo(
        _ undoManager: UndoManager, for identities: [AppIdentity], restoring rules: [Rule], actionName: String
    ) {
        undoManager.registerUndo(withTarget: self) { store in
            let current = store.disconnectRules(for: identities)
            store.replaceDisconnectRules(for: identities, with: rules)
            store.registerDisconnectUndo(undoManager, for: identities, restoring: current, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    /// Swaps the Disconnect rules for `identities` for `newRules` (same IDs kept),
    /// e.g. to undo. Other rules are never touched.
    func replaceDisconnectRules(for identities: [AppIdentity], with newRules: [Rule]) {
        let old = Set(disconnectRules(for: identities).map(\.id))
        guard !old.isEmpty || !newRules.isEmpty else { return }
        disconnectRuleIDs.subtract(old)
        disconnectRuleIDs.formUnion(newRules.map(\.id))
        updateRules { rules in
            rules.removeAll { old.contains($0.id) }
            rules.append(contentsOf: newRules)
        }
    }
}

/// Status shown on an app or process row (pure, tested).
struct RowStatus: Equatable, Sendable {
    enum Tone: Sendable { case active, idle, blocked, wouldBlock }
    let text: String
    let tone: Tone
    /// Dim the icon: the app/process is cut off (or would be).
    let dimsIcon: Bool

    /// Disconnect wins over other block rules; in monitor-only mode nothing is
    /// enforced, so blocks read "Would block" (never "Disconnected").
    static func make(
        isActive: Bool, ruleState: AppSummary.RuleState, disconnect: DisconnectStatus?, enforcing: Bool, now: Date
    ) -> RowStatus {
        if let disconnect {
            let remaining = disconnect.expiresAt.map { DisconnectCountdown.remaining(until: $0, now: now) }
            switch (enforcing, remaining) {
            case (true, nil): return RowStatus(text: String(localized: "Disconnected"), tone: .blocked, dimsIcon: true)
            case (true, let left?):
                return RowStatus(text: String(localized: "Disconnected · \(left) left"), tone: .blocked, dimsIcon: true)
            case (false, nil): return RowStatus(text: String(localized: "Would block"), tone: .wouldBlock, dimsIcon: true)
            case (false, let left?):
                return RowStatus(text: String(localized: "Would block · \(left) left"), tone: .wouldBlock, dimsIcon: true)
            }
        }
        if ruleState == .blocked {
            return enforcing
                ? RowStatus(text: String(localized: "Blocked"), tone: .blocked, dimsIcon: false)
                : RowStatus(text: String(localized: "Would block"), tone: .wouldBlock, dimsIcon: false)
        }
        return isActive
            ? RowStatus(text: String(localized: "Active"), tone: .active, dimsIcon: false)
            : RowStatus(text: String(localized: "Idle"), tone: .idle, dimsIcon: false)
    }

    /// Tooltip for the Disconnect / Reconnect control.
    static func controlToolTip(disconnect: DisconnectStatus?, enforcing: Bool) -> String {
        if let disconnect {
            var text = String(localized: "Reconnect: removes the block that Disconnect added.")
            if disconnect.otherBlockingRules > 0 {
                text += " " + String(localized: "\(disconnect.otherBlockingRules) other block rules still apply.")
            }
            return text
        }
        return enforcing
            ? String(localized: "Blocks new connections and cuts open ones the next time they send or receive data.")
            : String(localized: "Monitor-only mode: nothing is blocked. The block takes effect once the filter extension is enabled.")
    }
}
