import Foundation

/// Code-signing identity of the process that owns a flow.
public struct AppIdentity: Codable, Hashable, Sendable {
    public let bundleID: String?
    public let signingID: String?
    public let teamID: String?
    public let executablePath: String
    public let isAppleSigned: Bool
    public let isValidlySigned: Bool

    public init(
        bundleID: String?,
        signingID: String?,
        teamID: String?,
        executablePath: String,
        isAppleSigned: Bool,
        isValidlySigned: Bool
    ) {
        self.bundleID = bundleID
        self.signingID = signingID
        self.teamID = teamID
        self.executablePath = executablePath
        self.isAppleSigned = isAppleSigned
        self.isValidlySigned = isValidlySigned
    }

    /// Whether the signing identifier can be trusted as an identity: the signature
    /// is valid and anchored to a team (Developer ID / App Store) or to Apple.
    /// Ad-hoc signatures carry an arbitrary, forgeable identifier, so they don't count.
    public var hasTrustedSigningIdentity: Bool {
        isValidlySigned && signingID != nil && (teamID != nil || isAppleSigned)
    }

    /// Stable key used to match rules against flows.
    ///
    /// Trusted signatures match by signing identifier + team (so updates and moves
    /// keep their rules); everything else matches by executable path.
    public var matchKey: String {
        if hasTrustedSigningIdentity, let signingID {
            let team = teamID ?? "apple"
            return "sig:\(team):\(signingID)"
        }
        return "path:\(executablePath)"
    }
}
