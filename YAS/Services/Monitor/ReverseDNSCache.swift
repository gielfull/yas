import Darwin
import Foundation

/// Bounded, TTL'd reverse DNS (PTR) cache. Lookups run on a background queue,
/// at most `maxConcurrent` at a time; the scan never waits for them.
@MainActor
final class ReverseDNSCache {
    private struct Entry {
        let host: String?
        let expires: Date
    }

    private let capacity: Int
    private let positiveTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private let maxConcurrent: Int
    private let now: () -> Date
    private let lookup: @Sendable (String) -> String?
    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private var queued: [String] = []

    /// Called on main with (ip, host) when a lookup finds a name.
    var onResolve: ((String, String) -> Void)?

    init(
        capacity: Int = 4000,
        positiveTTL: TimeInterval = 3600,
        negativeTTL: TimeInterval = 600,
        maxConcurrent: Int = 4,
        now: @escaping () -> Date = Date.init,
        lookup: @escaping @Sendable (String) -> String? = ReverseDNSCache.systemLookup
    ) {
        self.capacity = capacity
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        self.maxConcurrent = maxConcurrent
        self.now = now
        self.lookup = lookup
    }

    /// Cached name, if resolved and not expired.
    func host(for ip: String) -> String? {
        guard let entry = entries[ip], entry.expires > now() else { return nil }
        return entry.host
    }

    /// Starts a lookup unless a fresh answer (or a lookup) already exists.
    func request(_ ip: String) {
        if let entry = entries[ip], entry.expires > now() { return }
        guard !inFlight.contains(ip), !queued.contains(ip) else { return }
        queued.append(ip)
        pump()
    }

    var pendingCount: Int { inFlight.count + queued.count }

    private func pump() {
        while inFlight.count < maxConcurrent, !queued.isEmpty {
            let ip = queued.removeFirst()
            inFlight.insert(ip)
            let lookup = lookup
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let host = lookup(ip)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(ip, host: host) }
                }
            }
        }
    }

    private func finish(_ ip: String, host: String?) {
        inFlight.remove(ip)
        record(ip, host: host)
        if let host { onResolve?(ip, host) }
        pump()
    }

    /// Stores an answer (nil = no PTR record) and evicts the soonest-expiring
    /// entries beyond `capacity`.
    func record(_ ip: String, host: String?) {
        entries[ip] = Entry(host: host, expires: now().addingTimeInterval(host == nil ? negativeTTL : positiveTTL))
        guard entries.count > capacity else { return }
        let overflow = entries.count - capacity
        for key in entries.sorted(by: { $0.value.expires < $1.value.expires }).prefix(overflow).map(\.key) {
            entries[key] = nil
        }
    }

    var count: Int { entries.count }

    /// getnameinfo(NI_NAMEREQD): only real PTR names, never the numeric address.
    nonisolated static func systemLookup(_ ip: String) -> String? {
        var storage = sockaddr_storage()
        let length: socklen_t
        if ip.contains(":") {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            guard inet_pton(AF_INET6, ip, &address.sin6_addr) == 1 else { return nil }
            withUnsafeMutableBytes(of: &storage) { raw in
                withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }
            withUnsafeMutableBytes(of: &storage) { raw in
                withUnsafeBytes(of: address) { raw.copyMemory(from: $0) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return name.isEmpty || name == ip ? nil : name
    }
}
