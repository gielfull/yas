import Darwin
import YASShared

/// One socket as seen through libproc, reduced to what a flow needs.
struct ParsedSocket: Hashable, Sendable {
    let proto: TransportProtocol
    let localPort: Int
    /// Nil for listening sockets.
    let remoteIP: String?
    let remotePort: Int

    var isListening: Bool { remoteIP == nil }
}

/// Pure conversion of `socket_fdinfo` (sys/proc_info.h) into endpoints.
enum SocketParser {
    /// Connected TCP/UDP sockets to routable addresses, and TCP listeners (so the
    /// caller can tell inbound from outbound). Everything else is nil: unconnected
    /// UDP, closed sockets, Unix/other families, loopback, link-local, multicast.
    static func parse(_ info: socket_fdinfo) -> ParsedSocket? {
        let socket = info.psi
        guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { return nil }

        let endpoint: in_sockinfo
        let proto: TransportProtocol
        switch socket.soi_kind {
        case Int32(SOCKINFO_TCP):
            let tcp = socket.soi_proto.pri_tcp
            endpoint = tcp.tcpsi_ini
            proto = .tcp
            if tcp.tcpsi_state == TSI_S_LISTEN {
                return ParsedSocket(proto: .tcp, localPort: port(fromNetworkOrder: endpoint.insi_lport), remoteIP: nil, remotePort: 0)
            }
            if tcp.tcpsi_state == TSI_S_CLOSED { return nil }
        case Int32(SOCKINFO_IN):
            guard socket.soi_protocol == IPPROTO_UDP else { return nil }
            endpoint = socket.soi_proto.pri_in
            proto = .udp
        default:
            return nil
        }

        let remotePort = port(fromNetworkOrder: endpoint.insi_fport)
        guard remotePort != 0,
              let remote = remoteAddress(endpoint),
              isRoutable(remote)
        else { return nil }
        return ParsedSocket(
            proto: proto, localPort: port(fromNetworkOrder: endpoint.insi_lport), remoteIP: remote, remotePort: remotePort)
    }

    /// libproc stores ports as `int` holding the network-order 16-bit value.
    static func port(fromNetworkOrder raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }

    /// Text form of the foreign address; IPv4-mapped IPv6 addresses come back as IPv4.
    static func remoteAddress(_ endpoint: in_sockinfo) -> String? {
        if endpoint.insi_vflag & UInt8(INI_IPV4) != 0 {
            return format(bytes: withUnsafeBytes(of: endpoint.insi_faddr.ina_46.i46a_addr4) { Array($0) })
        }
        guard endpoint.insi_vflag & UInt8(INI_IPV6) != 0 else { return nil }
        let bytes = withUnsafeBytes(of: endpoint.insi_faddr.ina_6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return format(bytes: Array(bytes[12..<16]))
        }
        return format(bytes: bytes)
    }

    /// 4 bytes -> dotted IPv4, 16 bytes -> IPv6 text (network order in, as stored by the kernel).
    static func format(bytes: [UInt8]) -> String? {
        let family: Int32
        switch bytes.count {
        case 4: family = AF_INET
        case 16: family = AF_INET6
        default: return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let written = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard written != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// Excludes unspecified, loopback, link-local and multicast addresses.
    static func isRoutable(_ ip: String) -> Bool {
        guard let bytes = MMDBReader.addressBytes(ip) else { return false }
        if bytes.count == 4 {
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes[0] == 127 { return false }
            if bytes[0] == 169 && bytes[1] == 254 { return false }
            if bytes[0] >= 224 && bytes[0] <= 239 { return false }
            return true
        }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false } // ::1
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return false } // fe80::/10
        if bytes[0] == 0xFF { return false } // multicast
        return true
    }
}
