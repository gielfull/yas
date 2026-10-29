import Foundation
import os

/// Thread-safe LRU cache mapping IP -> hostname with TTL expiry.
///
/// Uses a lock rather than an actor because the extension's filter path
/// (`handleNewFlow`) is synchronous. All operations are O(1).
public final class DNSCache: Sendable {
    public let capacity: Int
    /// TTLs below this are raised to it, so a connection opened a few seconds after
    /// a short-TTL answer (common with CDNs) still gets its hostname.
    public let minimumTTL: TimeInterval

    private let state: OSAllocatedUnfairLock<State>

    public init(capacity: Int = 4_096, minimumTTL: TimeInterval = 60) {
        precondition(capacity > 0, "DNSCache capacity must be positive")
        self.capacity = capacity
        self.minimumTTL = max(0, minimumTTL)
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Stores `ip -> hostname`, replacing any previous mapping and marking it most recent.
    public func insert(ip: String, hostname: String, ttl: TimeInterval, now: Date = Date()) {
        let key = Self.key(ip)
        let host = DomainMatcher.normalize(hostname)
        guard !key.isEmpty, !host.isEmpty else { return }
        let expiry = now.addingTimeInterval(max(ttl, minimumTTL))
        let capacity = capacity
        state.withLock { state in
            state.upsert(key: key, hostname: host, expiry: expiry)
            while state.entries.count > capacity, let oldest = state.tail {
                state.remove(key: oldest)
            }
        }
    }

    /// Stores every address answer of a parsed response.
    public func insert(_ response: DNSResponse, now: Date = Date()) {
        for answer in response.answers {
            insert(ip: answer.ip, hostname: answer.hostname, ttl: TimeInterval(answer.ttl), now: now)
        }
    }

    /// Returns the hostname for `ip` if present and unexpired, marking it most recent.
    /// Expired entries are removed.
    public func hostname(for ip: String, now: Date = Date()) -> String? {
        let key = Self.key(ip)
        return state.withLock { state in
            guard let entry = state.entries[key] else { return nil }
            guard entry.expiry > now else {
                state.remove(key: key)
                return nil
            }
            state.moveToFront(key: key)
            return entry.hostname
        }
    }

    /// Drops all expired entries.
    public func removeExpired(now: Date = Date()) {
        state.withLock { state in
            let expired = state.entries.filter { $0.value.expiry <= now }.map(\.key)
            for key in expired {
                state.remove(key: key)
            }
        }
    }

    public func removeAll() {
        state.withLock { $0 = State() }
    }

    private static func key(_ ip: String) -> String {
        ip.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Doubly linked LRU list keyed by IP

    private struct Entry: Sendable {
        var hostname: String
        var expiry: Date
        var newer: String?
        var older: String?
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        /// Most recently used.
        var head: String?
        /// Least recently used.
        var tail: String?

        mutating func upsert(key: String, hostname: String, expiry: Date) {
            if entries[key] != nil {
                entries[key]?.hostname = hostname
                entries[key]?.expiry = expiry
                moveToFront(key: key)
                return
            }
            entries[key] = Entry(hostname: hostname, expiry: expiry, newer: nil, older: head)
            if let head { entries[head]?.newer = key }
            head = key
            if tail == nil { tail = key }
        }

        mutating func moveToFront(key: String) {
            guard head != key else { return }
            unlink(key: key)
            entries[key]?.newer = nil
            entries[key]?.older = head
            if let head { entries[head]?.newer = key }
            head = key
            if tail == nil { tail = key }
        }

        mutating func remove(key: String) {
            guard entries[key] != nil else { return }
            unlink(key: key)
            entries[key] = nil
        }

        private mutating func unlink(key: String) {
            guard let entry = entries[key] else { return }
            if let newer = entry.newer {
                entries[newer]?.older = entry.older
            } else {
                head = entry.older
            }
            if let older = entry.older {
                entries[older]?.newer = entry.newer
            } else {
                tail = entry.newer
            }
        }
    }
}
