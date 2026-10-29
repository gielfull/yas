import Foundation

/// An A/AAAA answer attributed back to the name the client asked for.
public struct DNSAddressAnswer: Hashable, Sendable {
    /// Canonical IP string (`inet_ntop` form, e.g. `2600:1403::1aca`).
    public let ip: String
    /// Lowest TTL along the CNAME chain from the question name to this record.
    public let ttl: UInt32
    /// The queried name (lowercased, no trailing dot), not the CNAME target.
    public let hostname: String
    /// The owner name of the address record (last CNAME target), for diagnostics.
    public let canonicalName: String

    public init(ip: String, ttl: UInt32, hostname: String, canonicalName: String) {
        self.ip = ip
        self.ttl = ttl
        self.hostname = hostname
        self.canonicalName = canonicalName
    }
}

public struct DNSResponse: Hashable, Sendable {
    public let transactionID: UInt16
    public let isResponse: Bool
    public let responseCode: UInt8
    /// First question name, lowercased, no trailing dot.
    public let questionName: String?
    /// A/AAAA answers reachable from `questionName` through CNAMEs.
    public let answers: [DNSAddressAnswer]
}

/// Parses DNS messages seen by the DNS sniffer.
public enum DNSParser {
    private static let recordTypeA: UInt16 = 1
    private static let recordTypeCNAME: UInt16 = 5
    private static let recordTypeAAAA: UInt16 = 28
    private static let classIN: UInt16 = 1
    /// Upper bound on compression-pointer jumps per name (loop protection).
    private static let maxPointerJumps = 32
    private static let maxCNAMEChain = 16

    /// Parses a DNS message (UDP payload). Returns nil if the header or question
    /// is malformed. Answer records after a malformed one are ignored.
    public static func parse(_ data: Data) -> DNSResponse? {
        parse(bytes: [UInt8](data))
    }

    /// Parses the first DNS message of a TCP stream (2-byte big-endian length prefix).
    /// Returns nil if the prefixed message is not fully contained in `data`.
    public static func parseTCP(_ data: Data) -> DNSResponse? {
        var reader = ByteReader([UInt8](data))
        guard let length = reader.readUInt16().map(Int.init),
              let message = reader.readBytes(length)
        else { return nil }
        return parse(bytes: Array(message))
    }

    private struct RawRecord {
        let name: String
        let type: UInt16
        let ttl: UInt32
        let data: ArraySlice<UInt8>
        let dataOffset: Int
    }

    static func parse(bytes: [UInt8]) -> DNSResponse? {
        var reader = ByteReader(bytes)
        guard let id = reader.readUInt16(),
              let flags = reader.readUInt16(),
              let questionCount = reader.readUInt16(),
              let answerCount = reader.readUInt16(),
              reader.skip(4)  // authority + additional counts
        else { return nil }

        var questionName: String?
        for index in 0..<Int(questionCount) {
            guard let name = readName(bytes, reader: &reader), reader.skip(4) else { return nil }
            if index == 0 { questionName = name }
        }

        var records: [RawRecord] = []
        for _ in 0..<Int(answerCount) {
            guard let record = readRecord(bytes, reader: &reader) else { break }
            records.append(record)
        }

        let answers = questionName.map { resolveAnswers(for: $0, records: records, bytes: bytes) } ?? []
        return DNSResponse(
            transactionID: id,
            isResponse: flags & 0x8000 != 0,
            responseCode: UInt8(flags & 0x000F),
            questionName: questionName,
            answers: answers
        )
    }

    private static func readRecord(_ bytes: [UInt8], reader: inout ByteReader) -> RawRecord? {
        guard let name = readName(bytes, reader: &reader),
              let type = reader.readUInt16(),
              let recordClass = reader.readUInt16(),
              let ttl = reader.readUInt32(),
              let length = reader.readUInt16().map(Int.init)
        else { return nil }
        let dataOffset = reader.offset
        guard let data = reader.readBytes(length) else { return nil }
        // Only class IN is meaningful here; keep walking past other classes.
        return RawRecord(name: name, type: recordClass == classIN ? type : 0, ttl: ttl, data: data, dataOffset: dataOffset)
    }

    /// Maps address records back to the question name by following CNAMEs.
    private static func resolveAnswers(for question: String, records: [RawRecord], bytes: [UInt8]) -> [DNSAddressAnswer] {
        var cnames: [String: (target: String, ttl: UInt32)] = [:]
        for record in records where record.type == recordTypeCNAME {
            var rdata = ByteReader(bytes, offset: record.dataOffset)
            if let target = readName(bytes, reader: &rdata) {
                cnames[record.name] = (target, record.ttl)
            }
        }

        // Walk the chain question -> ... -> canonical name, tracking the lowest TTL.
        var chainTTL: [String: UInt32] = [question: .max]
        var current = question
        var currentTTL = UInt32.max
        for _ in 0..<maxCNAMEChain {
            guard let next = cnames[current], chainTTL[next.target] == nil else { break }
            currentTTL = min(currentTTL, next.ttl)
            chainTTL[next.target] = currentTTL
            current = next.target
        }

        var answers: [DNSAddressAnswer] = []
        for record in records {
            guard let inheritedTTL = chainTTL[record.name] else { continue }
            let ip: String?
            switch record.type {
            case recordTypeA where record.data.count == 4:
                ip = formatIP(record.data, family: AF_INET)
            case recordTypeAAAA where record.data.count == 16:
                ip = formatIP(record.data, family: AF_INET6)
            default:
                ip = nil
            }
            guard let ip else { continue }
            answers.append(DNSAddressAnswer(
                ip: ip,
                ttl: min(record.ttl, inheritedTTL),
                hostname: question,
                canonicalName: record.name
            ))
        }
        return answers
    }

    /// Reads a possibly-compressed domain name. Returns it lowercased without the
    /// trailing dot ("" for the root). Nil on truncation, bad label types, pointer
    /// loops, or names longer than 255 bytes.
    static func readName(_ bytes: [UInt8], reader: inout ByteReader) -> String? {
        var labels: [String] = []
        var position = reader.offset
        var resumeOffset: Int?
        var jumps = 0
        var totalLength = 0

        while true {
            guard position < bytes.count else { return nil }
            let length = Int(bytes[position])
            switch length & 0xC0 {
            case 0x00:
                if length == 0 {
                    position += 1
                    let end = resumeOffset ?? position
                    guard reader.skip(end - reader.offset) else { return nil }
                    return labels.joined(separator: ".")
                }
                let start = position + 1
                guard start + length <= bytes.count else { return nil }
                totalLength += length + 1
                guard totalLength <= 255 else { return nil }
                labels.append(String(decoding: bytes[start..<(start + length)], as: UTF8.self).lowercased())
                position = start + length
            case 0xC0:
                guard position + 1 < bytes.count else { return nil }
                jumps += 1
                guard jumps <= maxPointerJumps else { return nil }
                if resumeOffset == nil { resumeOffset = position + 2 }
                position = (length & 0x3F) << 8 | Int(bytes[position + 1])
            default:
                return nil  // 0x40 / 0x80 label types are not valid in messages
            }
        }
    }

    private static func formatIP(_ bytes: ArraySlice<UInt8>, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let formatted = Array(bytes).withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard formatted != nil else { return nil }
        let text = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: text, as: UTF8.self)
    }
}
