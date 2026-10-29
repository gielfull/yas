import Foundation
import Testing
@testable import YASShared

@Suite("DNSCache")
struct DNSCacheTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func insertAndLookup() {
        let cache = DNSCache(capacity: 8, minimumTTL: 0)
        cache.insert(ip: "93.184.216.34", hostname: "WWW.Example.com.", ttl: 60, now: t0)
        #expect(cache.hostname(for: "93.184.216.34", now: t0) == "www.example.com")
        #expect(cache.hostname(for: "1.1.1.1", now: t0) == nil)
    }

    @Test func entriesExpireAfterTTL() {
        let cache = DNSCache(capacity: 8, minimumTTL: 0)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 10, now: t0)
        #expect(cache.hostname(for: "10.0.0.1", now: t0.addingTimeInterval(9.9)) == "a.test")
        #expect(cache.hostname(for: "10.0.0.1", now: t0.addingTimeInterval(10)) == nil)
        #expect(cache.count == 0)  // the expired entry was dropped on lookup
    }

    @Test func minimumTTLExtendsShortAnswers() {
        let cache = DNSCache(capacity: 8, minimumTTL: 60)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 3, now: t0)
        #expect(cache.hostname(for: "10.0.0.1", now: t0.addingTimeInterval(30)) == "a.test")
        #expect(cache.hostname(for: "10.0.0.1", now: t0.addingTimeInterval(61)) == nil)
    }

    @Test func reinsertRefreshesHostnameAndExpiry() {
        let cache = DNSCache(capacity: 8, minimumTTL: 0)
        cache.insert(ip: "10.0.0.1", hostname: "old.test", ttl: 10, now: t0)
        cache.insert(ip: "10.0.0.1", hostname: "new.test", ttl: 100, now: t0.addingTimeInterval(5))
        #expect(cache.count == 1)
        #expect(cache.hostname(for: "10.0.0.1", now: t0.addingTimeInterval(50)) == "new.test")
    }

    @Test func leastRecentlyUsedIsEvicted() {
        let cache = DNSCache(capacity: 3, minimumTTL: 0)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 100, now: t0)
        cache.insert(ip: "10.0.0.2", hostname: "b.test", ttl: 100, now: t0)
        cache.insert(ip: "10.0.0.3", hostname: "c.test", ttl: 100, now: t0)
        // Touch a: b becomes least recently used.
        #expect(cache.hostname(for: "10.0.0.1", now: t0) == "a.test")
        cache.insert(ip: "10.0.0.4", hostname: "d.test", ttl: 100, now: t0)
        #expect(cache.count == 3)
        #expect(cache.hostname(for: "10.0.0.2", now: t0) == nil)
        #expect(cache.hostname(for: "10.0.0.1", now: t0) == "a.test")
        #expect(cache.hostname(for: "10.0.0.3", now: t0) == "c.test")
        #expect(cache.hostname(for: "10.0.0.4", now: t0) == "d.test")
        // Order is now 3 (LRU), 1, 4... touch order was 1, 3, 4 -> 1 is LRU.
        cache.insert(ip: "10.0.0.5", hostname: "e.test", ttl: 100, now: t0)
        #expect(cache.hostname(for: "10.0.0.1", now: t0) == nil)
        #expect(cache.hostname(for: "10.0.0.5", now: t0) == "e.test")
    }

    @Test func reinsertCountsAsUse() {
        let cache = DNSCache(capacity: 2, minimumTTL: 0)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 100, now: t0)
        cache.insert(ip: "10.0.0.2", hostname: "b.test", ttl: 100, now: t0)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 100, now: t0)
        cache.insert(ip: "10.0.0.3", hostname: "c.test", ttl: 100, now: t0)
        #expect(cache.hostname(for: "10.0.0.2", now: t0) == nil)
        #expect(cache.hostname(for: "10.0.0.1", now: t0) == "a.test")
    }

    @Test func capacityOneKeepsOnlyNewest() {
        let cache = DNSCache(capacity: 1, minimumTTL: 0)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 100, now: t0)
        cache.insert(ip: "10.0.0.2", hostname: "b.test", ttl: 100, now: t0)
        #expect(cache.count == 1)
        #expect(cache.hostname(for: "10.0.0.2", now: t0) == "b.test")
        #expect(cache.hostname(for: "10.0.0.1", now: t0) == nil)
    }

    @Test func removeExpired() {
        let cache = DNSCache(capacity: 8, minimumTTL: 0)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 5, now: t0)
        cache.insert(ip: "10.0.0.2", hostname: "b.test", ttl: 50, now: t0)
        cache.insert(ip: "10.0.0.3", hostname: "c.test", ttl: 5, now: t0)
        cache.removeExpired(now: t0.addingTimeInterval(10))
        #expect(cache.count == 1)
        #expect(cache.hostname(for: "10.0.0.2", now: t0.addingTimeInterval(10)) == "b.test")
        // The list stays consistent after removals: eviction still works.
        let small = DNSCache(capacity: 2, minimumTTL: 0)
        small.insert(ip: "1", hostname: "a", ttl: 5, now: t0)
        small.insert(ip: "2", hostname: "b", ttl: 50, now: t0)
        small.removeExpired(now: t0.addingTimeInterval(10))
        small.insert(ip: "3", hostname: "c", ttl: 50, now: t0)
        small.insert(ip: "4", hostname: "d", ttl: 50, now: t0)
        #expect(small.count == 2)
        #expect(small.hostname(for: "2", now: t0) == nil)
    }

    @Test func ipv6KeysAreCaseInsensitive() {
        let cache = DNSCache(capacity: 8, minimumTTL: 0)
        cache.insert(ip: "2600:1403:9C00:6AA::1ACA", hostname: "a.test", ttl: 60, now: t0)
        #expect(cache.hostname(for: "2600:1403:9c00:6aa::1aca", now: t0) == "a.test")
    }

    @Test func insertsParsedResponse() throws {
        let cache = DNSCache(capacity: 16, minimumTTL: 0)
        let response = try #require(DNSParser.parse(Fixtures.dnsResponseAAAA))
        cache.insert(response, now: t0)
        #expect(cache.count == 5)
        #expect(cache.hostname(for: "2600:1403:9c00:697::1aca", now: t0) == "www.apple.com")
        #expect(cache.hostname(for: "2600:1403:9c00:697::1aca", now: t0.addingTimeInterval(10)) == nil)
    }

    @Test func removeAll() {
        let cache = DNSCache(capacity: 8, minimumTTL: 0)
        cache.insert(ip: "10.0.0.1", hostname: "a.test", ttl: 60, now: t0)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.hostname(for: "10.0.0.1", now: t0) == nil)
    }

    @Test func concurrentAccessStaysConsistent() {
        let cache = DNSCache(capacity: 64, minimumTTL: 0)
        let now = t0
        DispatchQueue.concurrentPerform(iterations: 16) { worker in
            for i in 0..<2_000 {
                let ip = "10.\(worker).\(i / 256).\(i % 256)"
                cache.insert(ip: ip, hostname: "h\(worker).test", ttl: 60, now: now)
                _ = cache.hostname(for: "10.\((worker + 1) % 16).0.\(i % 256)", now: now)
            }
        }
        #expect(cache.count == 64)
        // Every remaining entry is still reachable and the list can keep evicting.
        for i in 0..<200 {
            cache.insert(ip: "192.168.0.\(i)", hostname: "z.test", ttl: 60, now: now)
        }
        #expect(cache.count == 64)
        #expect(cache.hostname(for: "192.168.0.199", now: now) == "z.test")
        #expect(cache.hostname(for: "192.168.0.100", now: now) == nil)
    }
}
