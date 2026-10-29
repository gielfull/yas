#if DEBUG
import Foundation
import YASShared

/// Synthetic flows for exercising the UI without the signed extension.
/// Enabled with the `-demo` launch argument, or automatically in Debug builds
/// when the filter is not running. Verdicts come from the real `RuleEngine`
/// with the store's mode and rules, so blocking from the UI takes effect.
@MainActor
final class DemoDataSource {
    private struct Destination {
        let host: String?
        let ip: String
        let port: Int
        let proto: TransportProtocol
        let country: String
        let weight: Int
        /// Simulates a blocklist hit regardless of rules.
        var alwaysBlocked = false
    }

    private struct Profile {
        let identities: [AppIdentity]
        let destinations: [Destination]
        /// Chance per tick of emitting traffic; 0 = only seeded history.
        let activity: Double
    }

    /// A long-lived transfer (stream, download) reported in chunks every tick.
    private struct Transfer {
        let flowID: UUID
        var remaining: UInt64
        /// Bytes per second received.
        let rate: Double
        /// Sent bytes as a fraction of received.
        let upstreamRatio: Double
    }

    private let store: Store
    private var profiles: [Profile] = []
    private var transfers: [Transfer] = []
    private var timer: Timer?
    private var lastPrompt: [String: Date] = [:]
    private(set) var isRunning = false

    init(store: Store) {
        self.store = store
    }

    static var isRequestedByLaunchArgument: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        profiles = Self.makeProfiles()
        for profile in profiles {
            for destination in profile.destinations {
                store.geo.registerKnownAddress(destination.ip, countryCode: destination.country)
            }
        }
        seedLongHistoryIfEmpty()
        seedHistory()
        let timer = Timer(timeInterval: 0.8, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        transfers.removeAll()
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    // MARK: - Generation

    private func seedHistory() {
        let now = Date()
        var events: [FlowEvent] = []
        for (index, profile) in profiles.enumerated() {
            // Idle profiles last talked 12 minutes ago; the rest over the last 4 minutes.
            let range: ClosedRange<TimeInterval> = profile.activity == 0 ? 700...760 : 5...240
            for _ in 0..<(profile.activity == 0 ? 6 : 14) {
                let age = TimeInterval.random(in: range) + Double(index)
                events.append(makeFlow(profile, at: now.addingTimeInterval(-age)))
            }
        }
        events.sort { $0.timestamp < $1.timestamp }
        store.ingest(events, source: .demo)
        store.apply(events.map(Self.randomStat))
    }

    private func tick() {
        var events: [FlowEvent] = []
        let now = Date()
        for profile in profiles where profile.activity > 0 && Double.random(in: 0..<1) < profile.activity {
            for _ in 0..<Int.random(in: 1...2) {
                events.append(makeFlow(profile, at: now))
            }
        }
        for event in events where event.verdict != .blocked { startTransferIfLarge(event) }
        store.ingest(events, source: .demo)
        store.apply(events.map(Self.randomStat) + transferChunks(at: now, interval: 0.8))
    }

    /// Spotify audio arrives in multi-megabyte bursts, Chrome sometimes downloads
    /// something big, ChatGPT streams answers.
    private func startTransferIfLarge(_ event: FlowEvent) {
        let host = event.remoteHost ?? ""
        let megabyte = 1_000_000.0
        switch host {
        case "audio-ak.spotifycdn.com":
            transfers.append(Transfer(
                flowID: event.id, remaining: UInt64(Double.random(in: 3...8) * megabyte),
                rate: Double.random(in: 0.3...0.9) * megabyte, upstreamRatio: 0.01))
        case "github.com" where Double.random(in: 0..<1) < 0.04:
            transfers.append(Transfer(
                flowID: event.id, remaining: UInt64(Double.random(in: 10...80) * megabyte),
                rate: Double.random(in: 3...10) * megabyte, upstreamRatio: 0.005))
        case "api.openai.com":
            transfers.append(Transfer(
                flowID: event.id, remaining: UInt64(Double.random(in: 0.1...0.6) * megabyte),
                rate: Double.random(in: 30_000...90_000), upstreamRatio: 0.08))
        default:
            break
        }
    }

    private func transferChunks(at now: Date, interval: TimeInterval) -> [TrafficStat] {
        var stats: [TrafficStat] = []
        for index in transfers.indices {
            let chunk = min(transfers[index].remaining, UInt64(transfers[index].rate * interval * Double.random(in: 0.6...1.4)))
            transfers[index].remaining -= chunk
            stats.append(TrafficStat(
                flowID: transfers[index].flowID, bytesInDelta: chunk,
                bytesOutDelta: UInt64(Double(chunk) * transfers[index].upstreamRatio), timestamp: now))
        }
        transfers.removeAll { $0.remaining == 0 }
        return stats
    }

    /// First run of a demo database: a week of history following a day/night
    /// curve, so the 24h and 7d charts have shape. Flows go through the Store
    /// (and so into the demo database) like live ones.
    private func seedLongHistoryIfEmpty() {
        guard let history = store.history,
              (try? history.flowsSync(matching: HistoryQuery(), limit: 1).isEmpty) == true
        else { return }
        let now = Date()
        var events: [FlowEvent] = []
        var stats: [TrafficStat] = []
        let active = profiles.filter { $0.activity > 0 }
        // One slot per 30 minutes over 7 days, denser (10 min) over the last day.
        var slot = now.addingTimeInterval(-7 * 86_400)
        while slot < now.addingTimeInterval(-600) {
            let spacing: TimeInterval = now.timeIntervalSince(slot) < 86_400 ? 600 : 1800
            let hour = Double(Calendar.current.component(.hour, from: slot))
            let daylight = max(0, sin(Double.pi * (hour - 7) / 16))
            let count = Int((0.3 + 3.5 * daylight) * Double.random(in: 0.5...1.5))
            for _ in 0..<count {
                guard let profile = active.randomElement() else { break }
                let event = makeFlow(profile, at: slot.addingTimeInterval(Double.random(in: 0..<spacing)))
                events.append(event)
                stats.append(Self.historicalStat(for: event))
            }
            slot = slot.addingTimeInterval(spacing)
        }
        events.sort { $0.timestamp < $1.timestamp }
        store.ingest(events, source: .demo)
        store.apply(stats)
    }

    private static func historicalStat(for flow: FlowEvent) -> TrafficStat {
        let megabyte = 1_000_000.0
        let received: Double
        switch flow.remoteHost ?? "" {
        case "audio-ak.spotifycdn.com": received = Double.random(in: 3...9) * megabyte
        case "github.com": received = Double.random(in: 0.2...60) * megabyte
        case "www.google.com", "www.bbc.co.uk", "www.lemonde.fr", "g1.globo.com", "www3.nhk.or.jp":
            received = Double.random(in: 0.3...4) * megabyte
        case "api.openai.com", "chatgpt.com": received = Double.random(in: 0.05...0.8) * megabyte
        default: received = Double.random(in: 5_000...300_000)
        }
        let blocked = flow.verdict == .blocked
        return TrafficStat(
            flowID: flow.id,
            bytesInDelta: blocked ? 0 : UInt64(received),
            bytesOutDelta: blocked ? 0 : UInt64(received * Double.random(in: 0.01...0.08)),
            timestamp: flow.timestamp.addingTimeInterval(Double.random(in: 0...20)))
    }

    private func makeFlow(_ profile: Profile, at date: Date) -> FlowEvent {
        let identity = profile.identities.randomElement()!
        let destination = weightedRandom(profile.destinations)
        let descriptor = FlowDescriptor(
            app: identity,
            host: destination.host,
            ip: destination.ip,
            port: destination.port,
            proto: destination.proto,
            direction: .outbound
        )
        let evaluation = RuleEngine.evaluate(descriptor, mode: store.mode, rules: store.rules, hostIsFinal: true)
        var verdict: Verdict
        switch evaluation.decision {
        case .allow, .needsMoreData: verdict = .allowed
        case .block: verdict = .blocked
        case .needsApproval:
            verdict = .pending
            // Seeded history is long past any approval timeout: no prompt for it.
            if Date().timeIntervalSince(date) < 30 {
                requestApproval(for: identity, destination: destination, at: date)
            }
        }
        if destination.alwaysBlocked, evaluation.decision != .needsApproval, store.mode != .allowAll {
            verdict = .blocked
        }
        return FlowEvent(
            id: UUID(),
            timestamp: date,
            app: identity,
            remoteHost: destination.host,
            remoteIP: destination.ip,
            remotePort: destination.port,
            proto: destination.proto,
            direction: .outbound,
            verdict: verdict,
            matchedRuleID: evaluation.matchedRuleID
        )
    }

    /// One prompt per app, like the extension's ApprovalCoordinator; re-prompts
    /// at most every 30 s after a "once" decision.
    private func requestApproval(for app: AppIdentity, destination: Destination, at date: Date) {
        let key = app.matchKey
        let pendingIndex = store.pendingApprovals.firstIndex { $0.app.matchKey == key }
        if pendingIndex == nil, let last = lastPrompt[key], date.timeIntervalSince(last) < 30 { return }

        var request = pendingIndex.map { store.pendingApprovals[$0] }
            ?? ApprovalRequest(requestID: UUID(), app: app, destinations: [], firstSeen: date)
        if let existing = request.destinations.firstIndex(where: {
            $0.ip == destination.ip && $0.port == destination.port
        }) {
            request.destinations[existing].count += 1
        } else {
            request.destinations.append(ApprovalDestination(
                host: destination.host, ip: destination.ip, port: destination.port,
                proto: destination.proto, count: 1))
        }
        lastPrompt[key] = date
        store.enqueueApproval(request)
    }

    private func weightedRandom(_ destinations: [Destination]) -> Destination {
        let total = destinations.reduce(0) { $0 + $1.weight }
        var pick = Int.random(in: 0..<max(total, 1))
        for destination in destinations {
            pick -= destination.weight
            if pick < 0 { return destination }
        }
        return destinations[0]
    }

    private static func randomStat(for flow: FlowEvent) -> TrafficStat {
        TrafficStat(
            flowID: flow.id,
            bytesInDelta: flow.verdict == .blocked ? 0 : UInt64.random(in: 2_000...250_000),
            bytesOutDelta: flow.verdict == .blocked ? 0 : UInt64.random(in: 500...20_000),
            timestamp: flow.timestamp
        )
    }

    // MARK: - Profiles

    private static func makeProfiles() -> [Profile] {
        let tls = 443
        return [
            Profile(
                identities: [identity(
                    candidates: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"],
                    bundleID: "com.openai.chat", teamID: "2DC432GLL2")],
                destinations: [
                    Destination(host: "chatgpt.com", ip: "104.18.32.47", port: tls, proto: .tcp, country: "US", weight: 6),
                    Destination(host: "ab.chatgpt.com", ip: "104.18.37.228", port: tls, proto: .tcp, country: "US", weight: 3),
                    Destination(host: "api.openai.com", ip: "162.159.140.245", port: tls, proto: .tcp, country: "US", weight: 4),
                    Destination(host: "cdn.oaistatic.com", ip: "104.18.41.158", port: tls, proto: .tcp, country: "US", weight: 2),
                ],
                activity: 0.45
            ),
            Profile(
                identities: [identity(
                    candidates: [
                        "/Applications/Spark Desktop.app/Contents/MacOS/Spark Desktop",
                        "/Applications/Spark.app/Contents/MacOS/Spark",
                    ],
                    bundleID: "com.readdle.SparkDesktop", teamID: "3L68KQB4HG")],
                destinations: [
                    Destination(host: "api.sparkmailapp.com", ip: "52.58.172.9", port: tls, proto: .tcp, country: "DE", weight: 3),
                    Destination(host: "imap.gmail.com", ip: "142.250.27.108", port: 993, proto: .tcp, country: "US", weight: 4),
                    Destination(host: "outlook.office365.com", ip: "52.98.151.66", port: 993, proto: .tcp, country: "IE", weight: 2),
                ],
                activity: 0.2
            ),
            Profile(
                identities: [identity(
                    candidates: ["/Applications/Spotify.app/Contents/MacOS/Spotify"],
                    bundleID: "com.spotify.client", teamID: "2FNC3A47ZF")],
                destinations: [
                    Destination(host: "apresolve.spotify.com", ip: "35.186.224.24", port: tls, proto: .tcp, country: "US", weight: 2),
                    Destination(host: "spclient.wg.spotify.com", ip: "35.186.224.47", port: tls, proto: .tcp, country: "US", weight: 4),
                    Destination(host: "ap-gew4.spotify.com", ip: "104.199.65.124", port: 4070, proto: .tcp, country: "BE", weight: 2),
                    Destination(host: "audio-ak.spotifycdn.com", ip: "23.62.226.11", port: tls, proto: .tcp, country: "NL", weight: 3),
                    Destination(host: "i.scdn.co", ip: "151.101.2.248", port: tls, proto: .tcp, country: "SE", weight: 2),
                ],
                activity: 0.3
            ),
            Profile(
                identities: [
                    identity(
                        candidates: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"],
                        bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV"),
                    identity(
                        candidates: ["/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"],
                        bundleID: "com.google.Chrome.helper", teamID: "EQHXZ8M8AV", resolveSignature: false),
                ],
                destinations: [
                    Destination(host: "www.google.com", ip: "142.250.184.228", port: tls, proto: .tcp, country: "US", weight: 5),
                    Destination(host: "github.com", ip: "140.82.121.4", port: tls, proto: .tcp, country: "DE", weight: 3),
                    Destination(host: "www.bbc.co.uk", ip: "151.101.0.81", port: tls, proto: .tcp, country: "GB", weight: 2),
                    Destination(host: "www.lemonde.fr", ip: "151.101.66.217", port: tls, proto: .tcp, country: "FR", weight: 1),
                    Destination(host: "www3.nhk.or.jp", ip: "23.52.179.214", port: tls, proto: .tcp, country: "JP", weight: 1),
                    Destination(host: "g1.globo.com", ip: "186.192.83.12", port: tls, proto: .tcp, country: "BR", weight: 1),
                    Destination(host: nil, ip: "74.125.250.129", port: 19302, proto: .udp, country: "US", weight: 1),
                    Destination(host: "securepubads.g.doubleclick.net", ip: "142.250.186.66", port: tls, proto: .tcp,
                                country: "US", weight: 2, alwaysBlocked: true),
                ],
                activity: 0.5
            ),
            Profile(
                identities: [AppIdentity(
                    bundleID: nil, signingID: "com.apple.curl", teamID: nil,
                    executablePath: "/usr/bin/curl", isAppleSigned: true, isValidlySigned: true)],
                destinations: [
                    Destination(host: "example.com", ip: "93.184.215.14", port: tls, proto: .tcp, country: "US", weight: 2),
                    Destination(host: "ifconfig.me", ip: "34.160.111.145", port: tls, proto: .tcp, country: "US", weight: 1),
                ],
                activity: 0
            ),
        ]
    }

    /// Uses the installed app's real path and signature when present so icons
    /// and names resolve; otherwise a plausible stand-in.
    private static func identity(
        candidates: [String], bundleID: String, teamID: String, resolveSignature: Bool = true
    ) -> AppIdentity {
        let path = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
        if resolveSignature,
           let bundleURL = AppIconService.appBundleURL(forExecutablePath: path),
           FileManager.default.fileExists(atPath: bundleURL.path),
           let real = CodeSignature.identity(forAppAt: bundleURL) {
            return real
        }
        return AppIdentity(
            bundleID: bundleID, signingID: bundleID, teamID: teamID,
            executablePath: path, isAppleSigned: false, isValidlySigned: true)
    }
}
#endif
