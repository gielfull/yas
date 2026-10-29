import Foundation
import Testing
@testable import YASShared

@Suite("SNIParser")
struct SNIParserTests {
    static let host = "www.example.org"

    // MARK: Real ClientHellos

    @Test func tls12ClientHello() {
        #expect(SNIParser.parse(Fixtures.tls12ClientHello) == Self.host)
    }

    @Test func tls13ClientHello() {
        #expect(SNIParser.parse(Fixtures.tls13ClientHello) == Self.host)
    }

    @Test func chromeClientHelloWithGREASE() throws {
        let hello = Fixtures.chromeClientHello
        // Guard the fixture itself: it must really contain GREASE values.
        let bytes = [UInt8](hello)
        #expect(bytes.count == 1955)
        #expect(bytes[78...79].elementsEqual([0x9A, 0x9A]))  // first cipher suite
        #expect(SNIParser.parse(hello) == Self.host)
    }

    @Test func chromeHelloWithinThe1KBPeekWindow() {
        // The extension peeks 1024 outbound bytes; Chrome's hello is ~2 KB.
        #expect(SNIParser.parse(Fixtures.chromeClientHello.prefix(1024)) == Self.host)
    }

    @Test func dataSliceWithNonZeroStartIndex() {
        let padded = Data([0xAA, 0xBB, 0xCC]) + Fixtures.tls12ClientHello
        let slice = padded.dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(SNIParser.parse(slice) == Self.host)
    }

    // MARK: Truncation

    @Test(arguments: [Fixtures.tls12ClientHello, Fixtures.tls13ClientHello, Fixtures.chromeClientHello])
    func everyPrefixReturnsNilUntilTheNameIsComplete(hello: Data) throws {
        let bytes = [UInt8](hello)
        let nameStart = try #require(bytes.firstRange(of: Array(Self.host.utf8))).lowerBound
        let nameEnd = nameStart + Self.host.utf8.count
        for length in 0...bytes.count {
            let result = SNIParser.parse(Data(bytes[0..<length]))
            if length < nameEnd {
                #expect(result == nil, "prefix \(length) of \(bytes.count)")
            } else {
                #expect(result == Self.host, "prefix \(length) of \(bytes.count)")
            }
        }
    }

    // MARK: Fragmentation across TLS records

    @Test func handshakeSplitAcrossTwoRecordsAtEveryOffset() {
        let bytes = [UInt8](Fixtures.tls13ClientHello)
        let handshake = Array(bytes[5...])
        for split in 1..<handshake.count {
            let data = Data(record(Array(handshake[..<split])) + record(Array(handshake[split...])))
            #expect(SNIParser.parse(data) == Self.host, "split at \(split)")
        }
    }

    @Test func handshakeSplitIntoManySmallRecords() {
        let handshake = Array([UInt8](Fixtures.chromeClientHello)[5...])
        var data: [UInt8] = []
        var index = 0
        while index < handshake.count {
            let end = min(index + 100, handshake.count)
            data += record(Array(handshake[index..<end]))
            index = end
        }
        #expect(SNIParser.parse(Data(data)) == Self.host)
    }

    @Test func secondRecordOfWrongTypeStopsReassembly() {
        let handshake = Array([UInt8](Fixtures.tls12ClientHello)[5...])
        var second = record(Array(handshake[40...]))
        second[0] = 0x17  // application_data: not part of the handshake
        #expect(SNIParser.parse(Data(record(Array(handshake[..<40])) + second)) == nil)
    }

    // MARK: Not a ClientHello / garbage

    @Test func emptyAndTinyBuffers() {
        #expect(SNIParser.parse(Data()) == nil)
        #expect(SNIParser.parse(Data([0x16])) == nil)
        #expect(SNIParser.parse(Data([0x16, 0x03, 0x01, 0x00, 0x00])) == nil)
        #expect(SNIParser.parse(Data([0x16, 0x03, 0x01, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00])) == nil)
    }

    @Test func plaintextHTTP() {
        #expect(SNIParser.parse(Data("GET / HTTP/1.1\r\nHost: www.example.org\r\n\r\n".utf8)) == nil)
    }

    @Test func wrongContentTypeOrHandshakeType() {
        var alert = [UInt8](Fixtures.tls12ClientHello)
        alert[0] = 0x15
        #expect(SNIParser.parse(Data(alert)) == nil)

        var serverHello = [UInt8](Fixtures.tls12ClientHello)
        serverHello[5] = 0x02
        #expect(SNIParser.parse(Data(serverHello)) == nil)

        var badVersion = [UInt8](Fixtures.tls12ClientHello)
        badVersion[1] = 0x07
        #expect(SNIParser.parse(Data(badVersion)) == nil)
    }

    @Test func corruptLengthsReturnNil() {
        // Session ID length > 32.
        var session = [UInt8](Fixtures.tls12ClientHello)
        session[5 + 4 + 2 + 32] = 0xFF
        #expect(SNIParser.parse(Data(session)) == nil)

        // Extensions length claims more than the SNI entry actually has room for:
        // the server_name extension's own length now overruns the buffer.
        var bytes = [UInt8](Fixtures.tls12ClientHello)
        let nameStart = bytes.firstRange(of: Array(Self.host.utf8))!.lowerBound
        let extLengthIndex = nameStart - 5 - 2  // ext length field precedes list len(2)+type(1)+len(2)
        bytes[extLengthIndex] = 0xFF
        #expect(SNIParser.parse(Data(bytes)) == nil)
    }

    @Test func invalidHostnameBytesAreRejected() {
        for bad: UInt8 in [0x00, 0x2F, 0x20, 0xFF] {
            var bytes = [UInt8](Fixtures.tls12ClientHello)
            let nameStart = bytes.firstRange(of: Array(Self.host.utf8))!.lowerBound
            bytes[nameStart + 3] = bad
            #expect(SNIParser.parse(Data(bytes)) == nil, "byte \(bad)")
        }
    }

    @Test func randomGarbageNeverCrashes() {
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<5_000 {
            let length = Int(rng.next() % 700)
            var bytes = (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            // Make half of them look like TLS so the parser goes deep.
            if length >= 6, rng.next() % 2 == 0 {
                bytes[0] = 0x16; bytes[1] = 0x03; bytes[5] = 0x01
            }
            _ = SNIParser.parse(Data(bytes))
        }
    }

    @Test func mutatedClientHellosNeverCrash() {
        var rng = SplitMix64(seed: 42)
        let original = [UInt8](Fixtures.chromeClientHello)
        for _ in 0..<3_000 {
            var bytes = original
            for _ in 0..<(1 + rng.next() % 8) {
                bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next())
            }
            let cut = Int(rng.next() % UInt64(bytes.count + 1))
            _ = SNIParser.parse(Data(bytes[0..<cut]))
        }
    }

    @Test(arguments: [(UInt16(0x0A0A), true), (0x1A1A, true), (0x4A4A, true), (0xFAFA, true),
                      (0x0000, false), (0x0A1A, false), (0x0B0B, false), (0xCA34, false), (0xFE0D, false)])
    func greaseValues(value: UInt16, isGREASE: Bool) {
        #expect(SNIParser.isGREASE(value) == isGREASE)
    }

    private func record(_ fragment: [UInt8]) -> [UInt8] {
        [0x16, 0x03, 0x01, UInt8(fragment.count >> 8), UInt8(fragment.count & 0xFF)] + fragment
    }
}

/// Deterministic PRNG so fuzz-style tests are reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
