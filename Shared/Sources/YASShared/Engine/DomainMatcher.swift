import Foundation

/// Hostname normalization and label-boundary domain matching.
public enum DomainMatcher {
    /// Lowercases, trims whitespace and strips trailing dots (`Example.COM.` -> `example.com`).
    public static func normalize(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }

    /// Whether `host` falls under `domain`.
    ///
    /// With `includeSubdomains`, `ads.example.com` matches `example.com` but
    /// `badexample.com` does not (the match must end on a label boundary).
    /// Without it, only the exact name matches. Empty names never match.
    public static func matches(host: String, domain: String, includeSubdomains: Bool) -> Bool {
        let host = normalize(host)
        let domain = normalize(domain)
        return matchesNormalized(host: host, domain: domain, includeSubdomains: includeSubdomains)
    }

    static func matchesNormalized(host: String, domain: String, includeSubdomains: Bool) -> Bool {
        guard !host.isEmpty, !domain.isEmpty else { return false }
        if host == domain { return true }
        guard includeSubdomains, host.count > domain.count else { return false }
        return host.hasSuffix("." + domain)
    }
}
