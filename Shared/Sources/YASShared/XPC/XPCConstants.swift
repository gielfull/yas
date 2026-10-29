import Foundation

/// Identifiers shared by the app and the filter extension.
public enum XPCConstants {
    public static let appBundleID = "com.gful.yas"
    public static let filterBundleID = "com.gful.yas.filter"
    public static let appGroup = "group.com.gful.yas"
    /// Must match `NEMachServiceName` in the extension's Info.plist.
    public static let machServiceName = "group.com.gful.yas.filter.xpc"
    public static let appLoggerSubsystem = "com.gful.yas"
    public static let filterLoggerSubsystem = "com.gful.yas.filter"

    /// Code-signing requirement for `NSXPCConnection.setCodeSigningRequirement(_:)`:
    /// an Apple-issued certificate (Apple Development or Developer ID) for `teamID`,
    /// with signing identifier `identifier`.
    ///
    /// The extension uses it with the app's ID to validate clients; the app can use
    /// it with `filterBundleID` to validate the extension. Returns nil if `teamID`
    /// or `identifier` contain characters that could alter the requirement.
    public static func codeSigningRequirement(teamID: String, identifier: String = appBundleID) -> String? {
        let teamIsValid = !teamID.isEmpty && teamID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let identifierIsValid = !identifier.isEmpty && identifier.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }
        guard teamIsValid, identifierIsValid else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
