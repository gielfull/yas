import Foundation

/// Extracts the TLS SNI hostname from the first outbound bytes of a flow.
public enum SNIParser {
    /// Largest TLS record fragment allowed (2^14 plus the TLS 1.2 ciphertext slack).
    private static let maxRecordLength = 16_384 + 2_048

    /// Returns the `server_name` host_name of a TLS ClientHello, or nil.
    ///
    /// Accepts a handshake split across several TLS records, and a buffer cut short
    /// (e.g. a 1 KB peek) as long as the whole server_name extension is inside it.
    /// Non-TLS, garbage or truncated-before-SNI input returns nil; never traps.
    public static func parse(_ data: Data) -> String? {
        guard let handshake = handshakeBytes(from: data) else { return nil }
        return parseClientHello(handshake)
    }

    /// Concatenates the payloads of consecutive handshake records (content type 0x16).
    private static func handshakeBytes(from data: Data) -> [UInt8]? {
        var reader = ByteReader([UInt8](data))
        var handshake: [UInt8] = []
        while reader.remaining > 0 {
            guard let contentType = reader.readUInt8(), contentType == 0x16,
                  let version = reader.readUInt16(), version >> 8 == 0x03,
                  let length = reader.readUInt16().map(Int.init),
                  length > 0, length <= maxRecordLength
            else { break }
            let available = min(length, reader.remaining)
            guard let fragment = reader.readBytes(available) else { break }
            handshake.append(contentsOf: fragment)
            if available < length { break }  // truncated record: use what we have
        }
        return handshake.isEmpty ? nil : handshake
    }

    private static func parseClientHello(_ bytes: [UInt8]) -> String? {
        var reader = ByteReader(bytes)
        guard reader.readUInt8() == 0x01,  // client_hello
              let declaredLength = reader.readUInt24(), declaredLength > 0
        else { return nil }
        // Clamp to the declared message length so trailing records are not misread.
        let end = min(reader.offset + declaredLength, bytes.count)
        var body = ByteReader(Array(bytes[reader.offset..<end]))

        guard body.skip(2),   // legacy_version
              body.skip(32),  // random
              let sessionIDLength = body.readUInt8(), sessionIDLength <= 32,
              body.skip(Int(sessionIDLength)),
              let cipherSuitesLength = body.readUInt16(), cipherSuitesLength % 2 == 0,
              body.skip(Int(cipherSuitesLength)),
              let compressionLength = body.readUInt8(), compressionLength > 0,
              body.skip(Int(compressionLength)),
              let extensionsLength = body.readUInt16().map(Int.init)
        else { return nil }

        let extensionsEnd = body.offset + min(extensionsLength, body.remaining)
        while body.offset + 4 <= extensionsEnd {
            guard let type = body.readUInt16(),
                  let length = body.readUInt16().map(Int.init),
                  body.offset + length <= extensionsEnd,
                  let payload = body.readBytes(length)
            else { return nil }  // extension runs past the data we have
            if isGREASE(type) { continue }
            if type == 0x0000 {
                return parseServerName(Array(payload))
            }
        }
        return nil
    }

    /// RFC 6066 ServerNameList; returns the first host_name entry.
    private static func parseServerName(_ bytes: [UInt8]) -> String? {
        var reader = ByteReader(bytes)
        guard let listLength = reader.readUInt16().map(Int.init), listLength <= reader.remaining else {
            return nil
        }
        let listEnd = reader.offset + listLength
        while reader.offset < listEnd {
            guard let nameType = reader.readUInt8(),
                  let nameLength = reader.readUInt16().map(Int.init),
                  reader.offset + nameLength <= listEnd,
                  let name = reader.readBytes(nameLength)
            else { return nil }
            if nameType == 0x00 {
                return validHostname(name)
            }
        }
        return nil
    }

    /// Hostnames are ASCII letters, digits, '-', '_', '.' and at most 255 bytes.
    private static func validHostname(_ bytes: ArraySlice<UInt8>) -> String? {
        guard !bytes.isEmpty, bytes.count <= 255 else { return nil }
        let allowed = bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
                return true
            default:
                return false
            }
        }
        guard allowed else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// RFC 8701 GREASE values: 0x0A0A, 0x1A1A, ..., 0xFAFA.
    static func isGREASE(_ value: UInt16) -> Bool {
        value & 0x0F0F == 0x0A0A && value >> 8 == value & 0xFF
    }
}
