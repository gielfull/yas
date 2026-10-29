import Foundation

/// Global filtering mode chosen by the user.
public enum FilterMode: String, Codable, Sendable, CaseIterable {
    /// Allow everything except what block rules match (default).
    case blockList
    /// Allow everything; rules are ignored.
    case allowAll
    /// Block everything except exempted apps; rules are ignored.
    case blockAll
    /// Apply rules, and ask the user about apps no rule covers.
    case requireApproval
}
