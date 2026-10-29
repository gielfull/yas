import Foundation
import YASShared
import Security

/// Reads code-signing information for apps picked by the user (rules sheet) and
/// for this process (XPC peer requirement).
enum CodeSignature {
    /// Builds the `AppIdentity` the extension would report for the app at `url`.
    static func identity(forAppAt url: URL) -> AppIdentity? {
        guard let bundle = Bundle(url: url), let executable = bundle.executableURL else { return nil }
        let info = signingInformation(at: url)
        return AppIdentity(
            bundleID: bundle.bundleIdentifier,
            signingID: info?.signingID,
            teamID: info?.teamID,
            executablePath: executable.path,
            isAppleSigned: info?.isAppleSigned ?? false,
            isValidlySigned: info?.isValid ?? false
        )
    }

    struct Info: Sendable {
        let signingID: String?
        let teamID: String?
        let isValid: Bool
        let isAppleSigned: Bool
    }

    static func signingInformation(at url: URL) -> Info? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        return information(for: staticCode)
    }

    /// Team identifier this process is signed with, if any.
    static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return information(for: staticCode)?.teamID
    }

    /// Signing info for a running process. Validity comes from the kernel's view of
    /// the running code (cheap), not by re-hashing the file on disk.
    static func runningInformation(for code: SecCode) -> Info? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any]
        else { return nil }
        let isValid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var isAppleSigned = false
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement {
            isAppleSigned = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        return Info(
            signingID: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            isValid: isValid,
            isAppleSigned: isAppleSigned)
    }

    static func information(for code: SecStaticCode) -> Info? {
        var rawInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any]
        else { return nil }

        // Resources are not re-hashed: this runs on the main thread for big bundles.
        let validity = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let isValid = SecStaticCodeCheckValidity(code, validity, nil) == errSecSuccess

        var isAppleSigned = false
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let requirement {
            isAppleSigned = SecStaticCodeCheckValidity(code, validity, requirement) == errSecSuccess
        }

        return Info(
            signingID: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            isValid: isValid,
            isAppleSigned: isAppleSigned
        )
    }
}
