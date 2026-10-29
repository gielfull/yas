import Darwin
import Foundation
import Network
import NetworkExtension
import YASShared

/// Turns an `NEFilterSocketFlow` into a `FlowDescriptor`: app identity, remote
/// address, and the best hostname available without reading data
/// (`remoteHostname`, then the DNS cache). SNI is added later by the provider.
final class FlowInspector: Sendable {
    static let unknownApp = AppIdentity(
        bundleID: nil, signingID: nil, teamID: nil,
        executablePath: "(unknown)", isAppleSigned: false, isValidlySigned: false)

    let dnsCache: DNSCache
    private let identities: AppIdentityResolver

    init(dnsCache: DNSCache, identities: AppIdentityResolver = AppIdentityResolver()) {
        self.dnsCache = dnsCache
        self.identities = identities
    }

    /// Nil for anything that is not TCP or UDP.
    func inspect(_ flow: NEFilterSocketFlow) -> InspectedFlow? {
        let proto: TransportProtocol
        switch flow.socketProtocol {
        case IPPROTO_TCP: proto = .tcp
        case IPPROTO_UDP: proto = .udp
        default: return nil
        }
        let direction: FlowDirection = flow.direction == .inbound ? .inbound : .outbound
        let remote = Self.remoteAddress(of: flow)

        // The app is the source application (the one the flow is attributed to,
        // even when a daemon opened it); fall back to the opening process.
        let appToken = flow.sourceAppAuditToken ?? flow.sourceProcessAuditToken
        let app = appToken.flatMap(identities.identity(auditToken:)) ?? Self.unknownApp

        var processPath: String?
        if let processToken = flow.sourceProcessAuditToken,
           let appToken,
           AppIdentityResolver.processKey(auditToken: processToken)
               != AppIdentityResolver.processKey(auditToken: appToken) {
            processPath = identities.identity(auditToken: processToken)?.executablePath
        }

        let descriptor = FlowDescriptor(
            app: app,
            host: hostname(remoteHostname: flow.remoteHostname, ip: remote.ip),
            ip: remote.ip,
            port: remote.port,
            proto: proto,
            direction: direction)
        return InspectedFlow(id: flow.identifier, descriptor: descriptor, processPath: processPath)
    }

    /// Refreshes the remote address (it can be nil at `handleNewFlow` and filled in
    /// once data flows) and, if still unknown, the hostname.
    func refresh(_ inspected: InspectedFlow, from flow: NEFilterSocketFlow) -> InspectedFlow {
        var updated = inspected
        if updated.descriptor.ip.isEmpty {
            let remote = Self.remoteAddress(of: flow)
            updated.descriptor.ip = remote.ip
            updated.descriptor.port = remote.port
        }
        if updated.descriptor.host == nil {
            updated.descriptor.host = hostname(remoteHostname: flow.remoteHostname, ip: updated.descriptor.ip)
        }
        return updated
    }

    /// `remoteHostname` if it is a real name, else the DNS cache.
    func hostname(remoteHostname: String?, ip: String) -> String? {
        if let name = remoteHostname.map(DomainMatcher.normalize), !name.isEmpty, !FlowPolicy.isIPLiteral(name) {
            return name
        }
        guard !ip.isEmpty else { return nil }
        return dnsCache.hostname(for: ip)
    }

    // MARK: - Remote endpoint

    /// ("", 0) when the system has not filled in the endpoint yet.
    static func remoteAddress(of flow: NEFilterSocketFlow) -> (ip: String, port: Int) {
        if #available(macOS 15.0, *) {
            guard case .hostPort(let host, let port)? = flow.remoteFlowEndpoint else { return ("", 0) }
            return (ipString(host), Int(port.rawValue))
        }
        return legacyRemoteAddress(of: flow)
    }

    /// macOS 14 only: `remoteEndpoint` (deprecated in 15, Swift-private in the
    /// Swift 6 API notes) is the only accessor there.
    private static func legacyRemoteAddress(of flow: NEFilterSocketFlow) -> (ip: String, port: Int) {
        guard let endpoint = flow.__remoteEndpoint as? __NWHostEndpoint else { return ("", 0) }
        return (FlowPolicy.normalizeIP(endpoint.hostname), Int(endpoint.port) ?? 0)
    }

    private static func ipString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return FlowPolicy.normalizeIP(ntop(AF_INET, address.rawValue) ?? "\(address)")
        case .ipv6(let address):
            return FlowPolicy.normalizeIP(ntop(AF_INET6, address.rawValue) ?? "\(address)")
        case .name(let name, _):
            return FlowPolicy.normalizeIP(name)
        @unknown default:
            return FlowPolicy.normalizeIP("\(host)")
        }
    }

    private static func ntop(_ family: Int32, _ raw: Data) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = raw.withUnsafeBytes { bytes in
            inet_ntop(family, bytes.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard ok else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
