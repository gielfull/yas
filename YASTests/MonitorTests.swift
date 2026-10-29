import Darwin
import YASShared
import XCTest
@testable import YAS

// MARK: - socket_fdinfo parsing

final class SocketParserTests: XCTestCase {
    private func bytes(_ ip: String) -> [UInt8] {
        MMDBReader.addressBytes(ip)!
    }

    /// A fake `socket_fdinfo` as libproc would fill it (ports in network byte order).
    private func socket(
        kind: Int32 = Int32(SOCKINFO_TCP), family: Int32 = AF_INET, protocolNumber: Int32 = IPPROTO_TCP,
        state: Int32 = TSI_S_ESTABLISHED, remote: String? = "93.184.215.14", remotePort: UInt16 = 443,
        localPort: UInt16 = 51_234, mappedV4: Bool = false
    ) -> socket_fdinfo {
        var info = socket_fdinfo()
        info.psi.soi_kind = kind
        info.psi.soi_family = family
        info.psi.soi_protocol = protocolNumber
        var endpoint = in_sockinfo()
        endpoint.insi_fport = Int32(remotePort.bigEndian)
        endpoint.insi_lport = Int32(localPort.bigEndian)
        if let remote {
            let address = bytes(remote)
            if address.count == 4 && !mappedV4 {
                endpoint.insi_vflag = UInt8(INI_IPV4)
                withUnsafeMutableBytes(of: &endpoint.insi_faddr.ina_46.i46a_addr4) { $0.copyBytes(from: address) }
            } else {
                endpoint.insi_vflag = UInt8(INI_IPV6)
                let v6 = address.count == 4 ? [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + address : address
                withUnsafeMutableBytes(of: &endpoint.insi_faddr.ina_6) { $0.copyBytes(from: v6) }
            }
        } else {
            endpoint.insi_vflag = UInt8(INI_IPV4)
        }
        if kind == Int32(SOCKINFO_TCP) {
            info.psi.soi_proto.pri_tcp.tcpsi_ini = endpoint
            info.psi.soi_proto.pri_tcp.tcpsi_state = state
        } else {
            info.psi.soi_proto.pri_in = endpoint
        }
        return info
    }

    func testIPv4EstablishedTCP() throws {
        let parsed = try XCTUnwrap(SocketParser.parse(socket()))
        XCTAssertEqual(parsed, ParsedSocket(proto: .tcp, localPort: 51_234, remoteIP: "93.184.215.14", remotePort: 443))
        XCTAssertFalse(parsed.isListening)
    }

    func testPortsAreConvertedFromNetworkByteOrder() {
        XCTAssertEqual(SocketParser.port(fromNetworkOrder: Int32(UInt16(443).bigEndian)), 443)
        XCTAssertEqual(SocketParser.port(fromNetworkOrder: Int32(UInt16(19_302).bigEndian)), 19_302)
        // Reading the raw value as host order would be wrong on little-endian Macs.
        XCTAssertEqual(SocketParser.port(fromNetworkOrder: 443), 47_873)
    }

    func testIPv6AndIPv4MappedIPv6() throws {
        let v6 = try XCTUnwrap(SocketParser.parse(socket(family: AF_INET6, remote: "2606:4700::1111")))
        XCTAssertEqual(v6.remoteIP, "2606:4700::1111")
        let mapped = try XCTUnwrap(SocketParser.parse(socket(family: AF_INET6, remote: "1.1.1.1", mappedV4: true)))
        XCTAssertEqual(mapped.remoteIP, "1.1.1.1", "IPv4-mapped IPv6 is shown as IPv4 (so GeoIP and rules see it)")
    }

    func testListeningAndClosedSockets() throws {
        let listener = try XCTUnwrap(SocketParser.parse(socket(state: TSI_S_LISTEN, remote: nil, remotePort: 0, localPort: 8080)))
        XCTAssertTrue(listener.isListening)
        XCTAssertEqual(listener.localPort, 8080)
        XCTAssertNil(SocketParser.parse(socket(state: TSI_S_CLOSED)))
    }

    func testUDPConnectedAndUnconnected() throws {
        let quic = try XCTUnwrap(SocketParser.parse(socket(kind: Int32(SOCKINFO_IN), protocolNumber: IPPROTO_UDP,
                                                           remote: "142.250.184.228", remotePort: 443)))
        XCTAssertEqual(quic.proto, .udp)
        XCTAssertEqual(quic.remotePort, 443)
        XCTAssertNil(SocketParser.parse(socket(kind: Int32(SOCKINFO_IN), protocolNumber: IPPROTO_UDP, remote: nil, remotePort: 0)),
                     "unconnected UDP has no peer")
    }

    func testSkipsLocalAndNonInternetSockets() {
        for ip in ["127.0.0.1", "169.254.10.1", "224.0.0.251", "0.0.0.0", "::1", "fe80::1", "ff02::fb"] {
            let family = ip.contains(":") ? AF_INET6 : AF_INET
            XCTAssertNil(SocketParser.parse(socket(family: family, remote: ip)), ip)
        }
        XCTAssertNil(SocketParser.parse(socket(family: AF_UNIX)))
        XCTAssertNil(SocketParser.parse(socket(kind: 99)))
    }
}

// MARK: - Flow diff

final class FlowTrackerTests: XCTestCase {
    private let app = AppIdentity(bundleID: nil, signingID: "com.apple.curl", teamID: nil,
                                  executablePath: "/usr/bin/curl", isAppleSigned: true, isValidlySigned: true)

    private func observation(process: String = "100:1", localPort: Int = 50_000, remote: String = "1.1.1.1") -> SocketObservation {
        SocketObservation(
            processKey: process, pid: 100, app: app,
            socket: ParsedSocket(proto: .tcp, localPort: localPort, remoteIP: remote, remotePort: 443), direction: .outbound)
    }

    func testAppearPersistDisappear() {
        var tracker = FlowTracker()
        var ids = (1...10).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }.makeIterator()
        let t0 = Date(timeIntervalSince1970: 1000)

        let first = tracker.apply([observation(), observation(localPort: 50_001)], at: t0) { ids.next()! }
        XCTAssertEqual(first.appeared.count, 2)
        XCTAssertEqual(first.appeared.first?.timestamp, t0)
        XCTAssertEqual(first.appeared.first?.verdict, .allowed)
        XCTAssertTrue(first.closed.isEmpty)

        let second = tracker.apply([observation(), observation(localPort: 50_001)], at: t0.addingTimeInterval(2)) { ids.next()! }
        XCTAssertTrue(second.appeared.isEmpty, "still-open sockets are not new flows")
        XCTAssertEqual(Set(second.present), Set(first.appeared.map(\.id)))

        let third = tracker.apply([observation()], at: t0.addingTimeInterval(4)) { ids.next()! }
        XCTAssertTrue(third.appeared.isEmpty)
        XCTAssertEqual(third.closed, [first.appeared[1].id], "the socket that vanished is closed")
        XCTAssertEqual(third.present, [first.appeared[0].id])

        let fourth = tracker.apply([observation(localPort: 50_001)], at: t0.addingTimeInterval(6)) { ids.next()! }
        XCTAssertEqual(fourth.appeared.count, 1, "a reused port after closing is a new flow")
        XCTAssertNotEqual(fourth.appeared[0].id, first.appeared[1].id)
    }

    func testDuplicateFdsAndPidReuse() {
        var tracker = FlowTracker()
        let update = tracker.apply([observation(), observation()], at: Date())
        XCTAssertEqual(update.appeared.count, 1, "two fds for one socket are one flow")
        let reused = tracker.apply([observation(process: "100:2")], at: Date())
        XCTAssertEqual(reused.appeared.count, 1, "same pid, new start time: a different process")
        XCTAssertEqual(reused.closed.count, 1)
    }
}

// MARK: - Reverse DNS cache

/// Test-only lookup counter; guarded by a lock because lookups run on a background queue.
private final class LookupLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func record(_ ip: String) { lock.lock(); names.append(ip); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return names.count }
}

@MainActor
final class ReverseDNSCacheTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 10_000)

    private func makeCache(log: LookupLog, capacity: Int = 100, maxConcurrent: Int = 4) -> ReverseDNSCache {
        ReverseDNSCache(
            capacity: capacity, positiveTTL: 3600, negativeTTL: 300, maxConcurrent: maxConcurrent,
            now: { [unowned self] in self.clock },
            lookup: { ip in
                log.record(ip)
                return ip == "1.1.1.1" ? "one.one.one.one" : nil
            })
    }

    private func waitUntilIdle(_ cache: ReverseDNSCache) async throws {
        for _ in 0..<200 where cache.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(cache.pendingCount, 0)
    }

    func testPositiveAnswersExpireAfterTheirTTL() async throws {
        let log = LookupLog()
        let cache = makeCache(log: log)
        var resolved: [String: String] = [:]
        cache.onResolve = { resolved[$0] = $1 }

        cache.request("1.1.1.1")
        cache.request("1.1.1.1") // de-duplicated while in flight
        try await waitUntilIdle(cache)
        XCTAssertEqual(cache.host(for: "1.1.1.1"), "one.one.one.one")
        XCTAssertEqual(resolved["1.1.1.1"], "one.one.one.one")
        XCTAssertEqual(log.count, 1)

        clock = clock.addingTimeInterval(3599)
        cache.request("1.1.1.1")
        XCTAssertEqual(log.count, 1, "fresh answers are not looked up again")
        XCTAssertEqual(cache.host(for: "1.1.1.1"), "one.one.one.one")

        clock = clock.addingTimeInterval(2)
        XCTAssertNil(cache.host(for: "1.1.1.1"), "expired after an hour")
        cache.request("1.1.1.1")
        try await waitUntilIdle(cache)
        XCTAssertEqual(log.count, 2)
    }

    func testNegativeAnswersUseTheShorterTTL() async throws {
        let log = LookupLog()
        let cache = makeCache(log: log)
        cache.request("2.2.2.2")
        try await waitUntilIdle(cache)
        XCTAssertNil(cache.host(for: "2.2.2.2"))
        cache.request("2.2.2.2")
        XCTAssertEqual(log.count, 1, "a missing PTR is cached too")
        clock = clock.addingTimeInterval(301)
        cache.request("2.2.2.2")
        try await waitUntilIdle(cache)
        XCTAssertEqual(log.count, 2)
    }

    func testCapacityEvictsSoonestToExpire() {
        let cache = makeCache(log: LookupLog(), capacity: 3)
        cache.record("10.0.0.1", host: "a")
        cache.record("10.0.0.2", host: nil) // negative: expires first
        cache.record("10.0.0.3", host: "c")
        cache.record("10.0.0.4", host: "d")
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.host(for: "10.0.0.2"))
        XCTAssertEqual(cache.host(for: "10.0.0.1"), "a")
        XCTAssertEqual(cache.host(for: "10.0.0.4"), "d")
    }

    func testConcurrencyIsBounded() async throws {
        let log = LookupLog()
        let cache = makeCache(log: log, maxConcurrent: 2)
        for index in 1...6 { cache.request("3.3.3.\(index)") }
        XCTAssertLessThanOrEqual(cache.pendingCount, 6)
        try await waitUntilIdle(cache)
        XCTAssertEqual(log.count, 6, "queued lookups all run eventually")
    }
}

// MARK: - Source selection and Store behaviour in monitor mode

final class DataSourceSelectionTests: XCTestCase {
    func testSelection() {
        XCTAssertEqual(DataSourceSelection.select(demoRequested: false, filterEnabled: false), .monitor, "monitor is the default")
        XCTAssertEqual(DataSourceSelection.select(demoRequested: false, filterEnabled: true), .filter)
        XCTAssertEqual(DataSourceSelection.select(demoRequested: true, filterEnabled: false), .demo)
        XCTAssertEqual(DataSourceSelection.select(demoRequested: true, filterEnabled: true), .demo, "-demo is explicit")
    }
}

@MainActor
final class MonitorStoreTests: XCTestCase {
    private let chrome = AppIdentity(
        bundleID: "com.google.Chrome", signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        isAppleSigned: false, isValidlySigned: true)

    private func event(at date: Date, ip: String = "142.250.184.228", host: String? = nil) -> FlowEvent {
        FlowEvent(id: UUID(), timestamp: date, app: chrome, remoteHost: host, remoteIP: ip, remotePort: 443,
                  proto: .tcp, direction: .outbound, verdict: .allowed, matchedRuleID: nil)
    }

    private func makeStore(history: HistoryDatabase? = nil) -> Store {
        let store = Store(geo: GeoIPService(databaseURL: nil), history: history, persistsPreferences: false) { _ in "Google Chrome" }
        store.setSource(.monitor)
        return store
    }

    func testMonitorModeIsNotEnforcingAndHasNoBytes() {
        let store = makeStore()
        XCTAssertFalse(store.isEnforcing)
        XCTAssertFalse(store.hasByteCounts)
        store.setSource(.filter)
        XCTAssertTrue(store.isEnforcing)
        XCTAssertTrue(store.hasByteCounts)
    }

    func testOpenSocketsKeepLongLivedConnectionsListedAndLive() throws {
        let store = makeStore()
        let now = Date()
        let old = event(at: now.addingTimeInterval(-3600))
        store.ingest([old], source: .monitor)
        store.timeWindow = .fiveMinutes
        XCTAssertTrue(store.appSummaries(now: now).isEmpty, "an hour-old flow that isn't open is outside 5 min")

        store.setOpenFlows([old.id], closed: [], at: now)
        let open = try XCTUnwrap(store.appSummaries(now: now).first)
        XCTAssertTrue(open.isActive, "the socket is still open")
        XCTAssertTrue(open.hasOpenConnection)
        XCTAssertEqual(open.destinations.first?.isLive, true)

        store.setOpenFlows([], closed: [old.id], at: now.addingTimeInterval(-20))
        let closed = try XCTUnwrap(store.appSummaries(now: now).first, "closed 20 s ago: still in the 5 min window")
        XCTAssertFalse(closed.isActive)
        XCTAssertEqual(closed.destinations.first?.isLive, false)
        XCTAssertTrue(store.appSummaries(now: now.addingTimeInterval(300)).isEmpty, "…and ages out without new traffic")
    }

    func testReverseDNSNameFillsTheHostAndIsMarked() throws {
        let store = makeStore()
        store.ingest([event(at: Date())], source: .monitor)
        XCTAssertEqual(store.appSummaries().first?.destinations.first?.displayHost, "142.250.184.228")
        store.setReverseDNSHost("lhr48s09-in-f4.1e100.net", for: "142.250.184.228")
        let destination = try XCTUnwrap(store.appSummaries().first?.destinations.first)
        XCTAssertEqual(destination.displayHost, "lhr48s09-in-f4.1e100.net")
        XCTAssertTrue(destination.hostIsReverseDNS)
    }

    func testWouldBlockUsesRulesButNotReverseDNSNames() throws {
        let store = makeStore()
        store.ingest([event(at: Date())], source: .monitor)
        store.setReverseDNSHost("lhr48s09-in-f4.1e100.net", for: "142.250.184.228")
        store.setDomainRule(.block, domain: "1e100.net")
        XCTAssertEqual(store.appSummaries().first?.destinations.first?.wouldBlock, false,
                       "the filter matches SNI/DNS names, never PTR guesses")
        store.setAppRule(.block, for: [chrome])
        XCTAssertEqual(store.appSummaries().first?.destinations.first?.wouldBlock, true)
        store.setSource(.filter)
        XCTAssertEqual(store.appSummaries().first?.destinations.first?.wouldBlock, false, "only computed when not enforcing")
    }

    func testMonitorFlowsAreRecordedAsMonitorAndPTRNamesReachHistory() async throws {
        let database = try HistoryDatabase()
        let store = makeStore(history: database)
        let flow = event(at: Date())
        store.ingest([flow], source: .monitor)
        store.flushHistory()
        var stored: FlowRecord?
        for _ in 0..<100 where stored == nil {
            stored = try database.flowsSync(matching: HistoryQuery(), limit: 1).first
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(stored?.source, .monitor)
        XCTAssertEqual(stored?.hostIsReverseDNS, false)

        try database.applyReverseDNS(ip: "142.250.184.228", host: "lhr48s09-in-f4.1e100.net")
        let named = try XCTUnwrap(database.flowsSync(matching: HistoryQuery(), limit: 1).first)
        XCTAssertEqual(named.host, "lhr48s09-in-f4.1e100.net")
        XCTAssertTrue(named.hostIsReverseDNS)
        XCTAssertNil(named.observedEvent.remoteHost, "on rehydrate the PTR name is not the flow's own host")

        // A flow that already has a host is never overwritten by a PTR name.
        let withSNI = event(at: Date(), ip: "142.250.184.229", host: "www.google.com")
        try database.insert([FlowRecord(event: withSNI, appName: "Google Chrome", country: nil, source: .filter)])
        try database.applyReverseDNS(ip: "142.250.184.229", host: "other.1e100.net")
        let kept = try database.flowsSync(matching: HistoryQuery(text: "www.google.com"), limit: 1).first
        XCTAssertEqual(kept?.host, "www.google.com")
        XCTAssertEqual(kept?.hostIsReverseDNS, false)
    }
}

final class CommandNameTests: XCTestCase {
    func testVersionedExecutablesAreNamedAfterTheirTool() {
        XCTAssertEqual(AppIconService.commandName(forExecutablePath: "/Users/me/.local/share/claude/versions/2.1.277"), "claude")
        XCTAssertEqual(AppIconService.commandName(forExecutablePath: "/opt/tool/v1.2.3"), "tool")
        XCTAssertEqual(AppIconService.commandName(forExecutablePath: "/usr/bin/ssh"), "ssh")
        XCTAssertEqual(
            AppIconService.commandName(forExecutablePath: "/x/cursor-agent/versions/2026.09.18-9a7762b/node"), "node",
            "a real binary name inside a versioned folder is kept")
    }
}
