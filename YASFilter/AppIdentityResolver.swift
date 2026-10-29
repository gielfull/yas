import Darwin
import Foundation
import YASShared
import os
import Security

/// Resolves the code-signing identity of a process from its audit token.
///
/// Cached per process image: the key is the token's pid plus its pid version,
/// which the kernel bumps on every `exec`, so a reused pid or a process that
/// re-execs never gets a stale identity. (Stronger than pid + path, and needs no
/// path lookup to compute.) Cache misses read the binary's signature from disk,
/// once per process image.
final class AppIdentityResolver: Sendable {
    struct ProcessKey: Hashable, Sendable {
        let pid: pid_t
        let pidVersion: UInt32
    }

    private let cache: OSAllocatedUnfairLock<BoundedCache<ProcessKey, AppIdentity>>

    init(capacity: Int = 1_024) {
        cache = OSAllocatedUnfairLock(initialState: BoundedCache(capacity: capacity))
    }

    /// `audit_token_t` is eight `UInt32`s: pid is `val[5]`, pid version `val[7]`
    /// (see `audit_token_to_pid` / `audit_token_to_pidversion` in libbsm).
    static func processKey(auditToken token: Data) -> ProcessKey? {
        guard token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let values: [UInt32] = token.withUnsafeBytes { raw in
            (0..<8).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        return ProcessKey(pid: pid_t(bitPattern: values[5]), pidVersion: values[7])
    }

    /// Identity of the process behind `auditToken`, or nil if the token is malformed
    /// or the process can no longer be found and has no readable path.
    func identity(auditToken token: Data) -> AppIdentity? {
        guard let key = Self.processKey(auditToken: token) else { return nil }
        if let cached = cache.withLock({ $0[key] }) { return cached }

        if let identity = Self.lookUp(auditToken: token) {
            cache.withLock { $0[key] = identity }
            return identity
        }
        // Not cached: a transient failure must not pin an unsigned identity on
        // the process for its lifetime.
        guard let fallback = Self.pathOnlyIdentity(pid: key.pid) else {
            Log.identity.error("Could not identify pid \(key.pid)")
            return nil
        }
        Log.identity.notice("Code signature unavailable for pid \(key.pid); matching by path")
        return fallback
    }

    /// Team ID the extension itself is signed with; nil for unsigned or ad-hoc
    /// builds. App and extension always share it.
    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Security framework

    private static func lookUp(auditToken token: Data) -> AppIdentity? {
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = (infoStatus == errSecSuccess ? infoRef as? [String: Any] : nil) ?? [:]

        guard let path = (info[kSecCodeInfoMainExecutable as String] as? URL)?.path
            ?? copyPath(staticCode)
        else { return nil }

        // Dynamic validity: the kernel's view of the running process (not tampered
        // with since launch) plus the on-disk signature.
        let isValid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        let isApple = isValid && satisfies(code, requirement: "anchor apple")
        let plist = info[kSecCodeInfoPList as String] as? [String: Any]

        return AppIdentity(
            bundleID: plist?["CFBundleIdentifier"] as? String,
            signingID: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            executablePath: path,
            isAppleSigned: isApple,
            isValidlySigned: isValid
        )
    }

    private static func copyPath(_ staticCode: SecStaticCode) -> String? {
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).path
    }

    private static func satisfies(_ code: SecCode, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Last resort when the Security framework cannot see the process: an unsigned
    /// identity keyed by executable path.
    private static func pathOnlyIdentity(pid: pid_t) -> AppIdentity? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return AppIdentity(
            bundleID: nil, signingID: nil, teamID: nil,
            executablePath: path, isAppleSigned: false, isValidlySigned: false)
    }
}
