import Foundation

/// Builds tiny MaxMind DB files in memory for tests: a binary trie over the given
/// (non-overlapping) networks, a data section, and a metadata map.
enum MMDBFixture {
    indirect enum Value {
        case string(String)
        case uint16(UInt16)
        case uint32(UInt32)
        case uint64(UInt64)
        case map([(String, Value)])
        /// Pointer into the data section (offset relative to its start).
        case pointer(Int)
        /// Already-encoded bytes.
        case raw([UInt8])
    }

    struct Network {
        let address: [UInt8]
        let prefix: Int
        let record: Value
    }

    static func build(ipVersion: Int, recordSize: Int, networks: [Network], prefixData: [UInt8] = []) -> Data {
        // Trie: children are .node(index), .empty, or .data(index into networks).
        enum Child { case empty, node(Int), data(Int) }
        var nodes: [[Child]] = [[.empty, .empty]]
        for (networkIndex, network) in networks.enumerated() {
            var node = 0
            for bitIndex in 0..<network.prefix {
                let bit = Int((network.address[bitIndex / 8] >> (7 - UInt8(bitIndex % 8))) & 1)
                if bitIndex == network.prefix - 1 {
                    nodes[node][bit] = .data(networkIndex)
                } else if case .node(let next) = nodes[node][bit] {
                    node = next
                } else {
                    nodes.append([.empty, .empty])
                    nodes[node][bit] = .node(nodes.count - 1)
                    node = nodes.count - 1
                }
            }
        }

        // Data section: optional prefix bytes (pointer targets), then one record per network.
        var dataSection = prefixData
        var offsets: [Int] = []
        for network in networks {
            offsets.append(dataSection.count)
            dataSection += encode(network.record)
        }

        let nodeCount = nodes.count
        func value(_ child: Child) -> Int {
            switch child {
            case .empty: nodeCount
            case .node(let index): index
            case .data(let index): nodeCount + 16 + offsets[index]
            }
        }

        var tree: [UInt8] = []
        for node in nodes {
            let left = value(node[0])
            let right = value(node[1])
            switch recordSize {
            case 24:
                tree += bytes(left, count: 3) + bytes(right, count: 3)
            case 28:
                tree += bytes(left & 0xFFFFFF, count: 3)
                tree.append(UInt8(((left >> 24) & 0x0F) << 4 | ((right >> 24) & 0x0F)))
                tree += bytes(right & 0xFFFFFF, count: 3)
            default:
                tree += bytes(left, count: 4) + bytes(right, count: 4)
            }
        }

        let metadata: Value = .map([
            ("node_count", .uint32(UInt32(nodeCount))),
            ("record_size", .uint16(UInt16(recordSize))),
            ("ip_version", .uint16(UInt16(ipVersion))),
            ("database_type", .string("Test-Country")),
            ("binary_format_major_version", .uint16(2)),
            ("build_epoch", .uint64(1_700_000_000)),
        ])
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        return Data(tree + [UInt8](repeating: 0, count: 16) + dataSection + marker + encode(metadata))
    }

    static func encode(_ value: Value) -> [UInt8] {
        switch value {
        case .string(let string):
            let utf8 = Array(string.utf8)
            return control(type: 2, size: utf8.count) + utf8
        case .uint16(let number):
            let payload = minimalBytes(UInt64(number))
            return control(type: 5, size: payload.count) + payload
        case .uint32(let number):
            let payload = minimalBytes(UInt64(number))
            return control(type: 6, size: payload.count) + payload
        case .uint64(let number):
            let payload = minimalBytes(number)
            return control(type: 9, size: payload.count) + payload
        case .map(let pairs):
            var out = control(type: 7, size: pairs.count)
            for (key, item) in pairs { out += encode(.string(key)) + encode(item) }
            return out
        case .pointer(let offset):
            precondition(offset < 2048)
            return [UInt8(1 << 5 | (offset >> 8) & 0x7), UInt8(offset & 0xFF)]
        case .raw(let bytes):
            return bytes
        }
    }

    private static func control(type: Int, size: Int) -> [UInt8] {
        precondition(size < 29)
        if type <= 7 { return [UInt8(type << 5 | size)] }
        return [UInt8(size), UInt8(type - 7)]
    }

    private static func minimalBytes(_ number: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = number
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return bytes
    }

    private static func bytes(_ value: Int, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> (8 * (count - 1 - $0))) & 0xFF) }
    }

    static func country(_ code: String) -> Value {
        .map([("country", .map([("iso_code", .string(code))]))])
    }
}
