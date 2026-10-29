import Darwin
import Foundation

/// Minimal reader for the MaxMind DB format (https://maxmind.github.io/MaxMind-DB/),
/// enough for DB-IP Lite Country: binary search tree with 24/28/32-bit records,
/// the full data-section type set, and IPv4 lookups in IPv6 trees.
struct MMDBReader: Sendable {
    indirect enum Value: Sendable, Equatable {
        case string(String)
        case double(Double)
        case bytes(Data)
        case uint(UInt64)
        case int(Int32)
        case map([String: Value])
        case array([Value])
        case bool(Bool)
        case float(Float)
        case uint128(Data)

        subscript(key: String) -> Value? {
            if case .map(let map) = self { return map[key] }
            return nil
        }

        var stringValue: String? {
            if case .string(let string) = self { return string }
            return nil
        }

        var integerValue: UInt64? {
            switch self {
            case .uint(let value): value
            case .int(let value) where value >= 0: UInt64(value)
            default: nil
            }
        }
    }

    enum ReaderError: Error, Equatable {
        case metadataNotFound
        case invalidMetadata(String)
        case corrupt(String)
    }

    struct Metadata: Sendable, Equatable {
        let nodeCount: Int
        let recordSize: Int
        let ipVersion: Int
        let databaseType: String
        let buildEpoch: UInt64
    }

    let metadata: Metadata
    private let data: Data
    private let searchTreeSize: Int
    private let dataSectionStart: Int
    private let ipv4StartNode: Int

    private static let metadataMarker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
    private static let maxDepth = 32

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        // Normalize to zero-based indices; slices of a larger Data are not.
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data

        guard let markerEnd = Self.lastMarkerEnd(in: data) else { throw ReaderError.metadataNotFound }
        let decoder = Decoder(data: data, base: markerEnd)
        let (raw, _) = try decoder.decode(at: markerEnd, depth: 0)

        guard let nodeCount = raw["node_count"]?.integerValue,
              let recordSize = raw["record_size"]?.integerValue,
              let ipVersion = raw["ip_version"]?.integerValue
        else { throw ReaderError.invalidMetadata("missing node_count, record_size or ip_version") }
        guard [24, 28, 32].contains(recordSize) else {
            throw ReaderError.invalidMetadata("unsupported record size \(recordSize)")
        }
        guard ipVersion == 4 || ipVersion == 6 else {
            throw ReaderError.invalidMetadata("unsupported ip version \(ipVersion)")
        }

        metadata = Metadata(
            nodeCount: Int(nodeCount),
            recordSize: Int(recordSize),
            ipVersion: Int(ipVersion),
            databaseType: raw["database_type"]?.stringValue ?? "",
            buildEpoch: raw["build_epoch"]?.integerValue ?? 0
        )
        searchTreeSize = (metadata.recordSize * 2 / 8) * metadata.nodeCount
        dataSectionStart = searchTreeSize + 16
        guard dataSectionStart <= markerEnd - Self.metadataMarker.count else {
            throw ReaderError.invalidMetadata("search tree larger than file")
        }

        // IPv4 addresses live under ::/96 in IPv6 trees.
        var node = 0
        if metadata.ipVersion == 6 {
            for _ in 0..<96 where node < metadata.nodeCount {
                node = try Self.readRecord(data: data, metadata: metadata, node: node, bit: 0)
            }
        }
        ipv4StartNode = node
    }

    // MARK: - Lookup

    /// Record for an IPv4/IPv6 address string, or nil when the address is not in the database.
    func lookup(_ ip: String) throws -> Value? {
        guard let bytes = Self.addressBytes(ip) else { return nil }
        return try lookup(bytes: bytes)
    }

    /// `bytes` is 4 (IPv4) or 16 (IPv6) bytes in network order.
    func lookup(bytes: [UInt8]) throws -> Value? {
        var bytes = bytes
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            bytes = Array(bytes[12..<16]) // IPv4-mapped IPv6
        }
        let bitCount: Int
        var node: Int
        switch bytes.count {
        case 4:
            bitCount = 32
            node = ipv4StartNode
        case 16:
            guard metadata.ipVersion == 6 else { return nil }
            bitCount = 128
            node = 0
        default:
            return nil
        }

        for index in 0..<bitCount where node < metadata.nodeCount {
            let bit = Int((bytes[index >> 3] >> (7 - UInt8(index & 7))) & 1)
            node = try Self.readRecord(data: data, metadata: metadata, node: node, bit: bit)
        }

        if node == metadata.nodeCount { return nil }
        guard node > metadata.nodeCount else { return nil }
        let offset = searchTreeSize + (node - metadata.nodeCount)
        guard offset >= dataSectionStart, offset < data.count else {
            throw ReaderError.corrupt("data pointer out of range")
        }
        let decoder = Decoder(data: data, base: dataSectionStart)
        return try decoder.decode(at: offset, depth: 0).value
    }

    /// ISO 3166-1 alpha-2 code for `ip` (DB-IP / GeoLite2 country layout).
    func countryCode(for ip: String) -> String? {
        guard let record = try? lookup(ip) else { return nil }
        let code = record["country"]?["iso_code"]?.stringValue
            ?? record["registered_country"]?["iso_code"]?.stringValue
        return code?.uppercased()
    }

    // MARK: - Tree

    private static func readRecord(data: Data, metadata: Metadata, node: Int, bit: Int) throws -> Int {
        let nodeBytes = metadata.recordSize * 2 / 8
        let base = node * nodeBytes
        guard base + nodeBytes <= data.count else { throw ReaderError.corrupt("node \(node) out of range") }
        func byte(_ index: Int) -> Int { Int(data[base + index]) }

        switch metadata.recordSize {
        case 24:
            let start = bit == 0 ? 0 : 3
            return byte(start) << 16 | byte(start + 1) << 8 | byte(start + 2)
        case 28:
            if bit == 0 {
                return (byte(3) & 0xF0) << 20 | byte(0) << 16 | byte(1) << 8 | byte(2)
            }
            return (byte(3) & 0x0F) << 24 | byte(4) << 16 | byte(5) << 8 | byte(6)
        default:
            let start = bit == 0 ? 0 : 4
            return byte(start) << 24 | byte(start + 1) << 16 | byte(start + 2) << 8 | byte(start + 3)
        }
    }

    private static func lastMarkerEnd(in data: Data) -> Int? {
        let marker = metadataMarker
        let searchStart = max(0, data.count - 128 * 1024)
        var index = data.count - marker.count
        while index >= searchStart {
            var matches = true
            for offset in 0..<marker.count where data[index + offset] != marker[offset] {
                matches = false
                break
            }
            if matches { return index + marker.count }
            index -= 1
        }
        return nil
    }

    /// Parses an IPv4 or IPv6 literal (optionally bracketed or with a zone suffix).
    static func addressBytes(_ ip: String) -> [UInt8]? {
        var literal = ip.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let percent = literal.firstIndex(of: "%") { literal = String(literal[..<percent]) }

        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    // MARK: - Data section

    private struct Decoder {
        let data: Data
        /// Pointers are relative to this offset (data section or metadata start).
        let base: Int

        func decode(at offset: Int, depth: Int) throws -> (value: Value, next: Int) {
            guard depth < MMDBReader.maxDepth else { throw ReaderError.corrupt("nesting too deep") }
            var cursor = offset
            let control = try byte(&cursor)
            var type = Int(control >> 5)

            if type == 1 {
                let target = try pointer(control: control, cursor: &cursor)
                let (value, _) = try decode(at: base + target, depth: depth + 1)
                return (value, cursor)
            }
            if type == 0 {
                type = 7 + Int(try byte(&cursor))
            }
            let size = try payloadSize(control: control, cursor: &cursor)

            switch type {
            case 2:
                let bytes = try take(size, &cursor)
                guard let string = String(data: bytes, encoding: .utf8) else {
                    throw ReaderError.corrupt("invalid UTF-8 string")
                }
                return (.string(string), cursor)
            case 3:
                guard size == 8 else { throw ReaderError.corrupt("double of size \(size)") }
                let bits = try unsigned(size, &cursor)
                return (.double(Double(bitPattern: bits)), cursor)
            case 4:
                return (.bytes(try take(size, &cursor)), cursor)
            case 5, 6, 9:
                guard size <= 8 else { throw ReaderError.corrupt("integer of size \(size)") }
                return (.uint(try unsigned(size, &cursor)), cursor)
            case 7:
                var map: [String: Value] = [:]
                for _ in 0..<size {
                    let (key, afterKey) = try decode(at: cursor, depth: depth + 1)
                    guard case .string(let keyString) = key else { throw ReaderError.corrupt("non-string map key") }
                    let (value, afterValue) = try decode(at: afterKey, depth: depth + 1)
                    map[keyString] = value
                    cursor = afterValue
                }
                return (.map(map), cursor)
            case 8:
                guard size <= 4 else { throw ReaderError.corrupt("int32 of size \(size)") }
                let raw = UInt32(truncatingIfNeeded: try unsigned(size, &cursor))
                return (.int(Int32(bitPattern: raw)), cursor)
            case 10:
                guard size <= 16 else { throw ReaderError.corrupt("uint128 of size \(size)") }
                return (.uint128(try take(size, &cursor)), cursor)
            case 11:
                var array: [Value] = []
                array.reserveCapacity(size)
                for _ in 0..<size {
                    let (value, next) = try decode(at: cursor, depth: depth + 1)
                    array.append(value)
                    cursor = next
                }
                return (.array(array), cursor)
            case 14:
                return (.bool(size != 0), cursor)
            case 15:
                guard size == 4 else { throw ReaderError.corrupt("float of size \(size)") }
                let bits = UInt32(truncatingIfNeeded: try unsigned(size, &cursor))
                return (.float(Float(bitPattern: bits)), cursor)
            default:
                throw ReaderError.corrupt("unsupported data type \(type)")
            }
        }

        private func byte(_ cursor: inout Int) throws -> UInt8 {
            guard cursor >= 0, cursor < data.count else { throw ReaderError.corrupt("read past end") }
            defer { cursor += 1 }
            return data[cursor]
        }

        private func take(_ count: Int, _ cursor: inout Int) throws -> Data {
            guard count >= 0, cursor >= 0, cursor + count <= data.count else {
                throw ReaderError.corrupt("read past end")
            }
            defer { cursor += count }
            return data.subdata(in: cursor..<(cursor + count))
        }

        private func unsigned(_ count: Int, _ cursor: inout Int) throws -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<count {
                value = value << 8 | UInt64(try byte(&cursor))
            }
            return value
        }

        private func payloadSize(control: UInt8, cursor: inout Int) throws -> Int {
            let size = Int(control & 0x1F)
            switch size {
            case 29: return 29 + Int(try unsigned(1, &cursor))
            case 30: return 285 + Int(try unsigned(2, &cursor))
            case 31: return 65_821 + Int(try unsigned(3, &cursor))
            default: return size
            }
        }

        private func pointer(control: UInt8, cursor: inout Int) throws -> Int {
            let sizeBits = Int((control >> 3) & 0x3)
            let high = Int(control & 0x7)
            switch sizeBits {
            case 0: return high << 8 | Int(try unsigned(1, &cursor))
            case 1: return (high << 16 | Int(try unsigned(2, &cursor))) + 2048
            case 2: return (high << 24 | Int(try unsigned(3, &cursor))) + 526_336
            default: return Int(try unsigned(4, &cursor))
            }
        }
    }
}
