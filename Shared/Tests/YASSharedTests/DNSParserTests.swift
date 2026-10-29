import Foundation
import Testing
@testable import YASShared

@Suite("DNSParser")
struct DNSParserTests {
    // MARK: Real responses

    @Test func realAResponseFollowsCNAMEChain() throws {
        let response = try #require(DNSParser.parse(Fixtures.dnsResponseA))
        #expect(response.transactionID == 0x1234)
        #expect(response.isResponse)
        #expect(response.responseCode == 0)
        #expect(response.questionName == "www.apple.com")
        #expect(response.answers == [
            DNSAddressAnswer(ip: "23.37.74.165", ttl: 3, hostname: "www.apple.com",
                             canonicalName: "e6858.dsce9.akamaiedge.net"),
        ])
    }

    @Test func realAAAAResponse() throws {
        let response = try #require(DNSParser.parse(Fixtures.dnsResponseAAAA))
        #expect(response.questionName == "www.apple.com")
        #expect(response.answers.map(\.ip) == [
            "2600:1403:9c00:6aa::1aca", "2600:1403:9c00:699::1aca", "2600:1403:9c00:6ad::1aca",
            "2600:1403:9c00:6a9::1aca", "2600:1403:9c00:697::1aca",
        ])
        #expect(response.answers.allSatisfy { $0.hostname == "www.apple.com" && $0.ttl == 10 })
    }

    @Test func tcpLengthPrefix() throws {
        let message = Fixtures.dnsResponseA
        let framed = Data([UInt8(message.count >> 8), UInt8(message.count & 0xFF)]) + message
        let response = try #require(DNSParser.parseTCP(framed))
        #expect(response == DNSParser.parse(message))
        #expect(DNSParser.parseTCP(framed.prefix(framed.count - 1)) == nil)
        #expect(DNSParser.parseTCP(Data([0x00])) == nil)
    }

    @Test func everyPrefixOfRealResponseIsSafe() {
        let bytes = [UInt8](Fixtures.dnsResponseAAAA)
        for length in 0..<bytes.count {
            let response = DNSParser.parse(Data(bytes[0..<length]))
            // Header + question end at byte 31; anything shorter can't parse.
            if length < 31 { #expect(response == nil, "prefix \(length)") }
            // A truncated message never yields a complete answer set.
            #expect((response?.answers.count ?? 0) < 5, "prefix \(length)")
        }
    }

    // MARK: Hand-built messages

    @Test func chainTTLIsTheMinimumAlongTheChain() throws {
        var m = DNSMessageBuilder(question: "a.test")
        m.cname("a.test", to: "b.test", ttl: 30)
        m.cname("b.test", to: "c.test", ttl: 600)
        m.a("c.test", [10, 0, 0, 1], ttl: 300)
        let response = try #require(DNSParser.parse(m.data))
        #expect(response.answers == [DNSAddressAnswer(ip: "10.0.0.1", ttl: 30, hostname: "a.test", canonicalName: "c.test")])
    }

    @Test func unrelatedAddressRecordsAreIgnored() throws {
        var m = DNSMessageBuilder(question: "a.test")
        m.a("a.test", [10, 0, 0, 1], ttl: 60)
        m.a("evil.test", [6, 6, 6, 6], ttl: 60)
        let response = try #require(DNSParser.parse(m.data))
        #expect(response.answers.map(\.ip) == ["10.0.0.1"])
    }

    @Test func caseAndCompressionAreNormalized() throws {
        var m = DNSMessageBuilder(question: "WWW.Example.COM")
        m.aAtQuestionPointer([192, 0, 2, 7], ttl: 5)
        let response = try #require(DNSParser.parse(m.data))
        #expect(response.questionName == "www.example.com")
        #expect(response.answers.first?.ip == "192.0.2.7")
        #expect(response.answers.first?.hostname == "www.example.com")
    }

    @Test func cnameLoopTerminates() throws {
        var m = DNSMessageBuilder(question: "a.test")
        m.cname("a.test", to: "b.test", ttl: 60)
        m.cname("b.test", to: "a.test", ttl: 60)
        m.a("b.test", [10, 0, 0, 2], ttl: 60)
        let response = try #require(DNSParser.parse(m.data))
        #expect(response.answers.map(\.ip) == ["10.0.0.2"])
    }

    @Test func wrongRDataLengthIsSkipped() throws {
        var m = DNSMessageBuilder(question: "a.test")
        m.record(name: "a.test", type: 1, ttl: 60, rdata: [1, 2, 3])
        m.record(name: "a.test", type: 28, ttl: 60, rdata: [UInt8](repeating: 0, count: 4))
        m.a("a.test", [10, 0, 0, 3], ttl: 60)
        let response = try #require(DNSParser.parse(m.data))
        #expect(response.answers.map(\.ip) == ["10.0.0.3"])
    }

    @Test func queryHasNoAnswers() throws {
        let m = DNSMessageBuilder(question: "a.test", isResponse: false)
        let response = try #require(DNSParser.parse(m.data))
        #expect(!response.isResponse)
        #expect(response.questionName == "a.test")
        #expect(response.answers.isEmpty)
    }

    // MARK: Malformed names

    @Test func selfReferencingPointerInQuestion() {
        // Header (1 question) + question name that is a pointer to itself (offset 12).
        let bytes: [UInt8] = header(questions: 1, answers: 0) + [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01]
        #expect(DNSParser.parse(Data(bytes)) == nil)
    }

    @Test func mutualPointerLoopInAnswer() throws {
        // Answer name: label "x" then pointer to itself -> endless x.x.x... must stop.
        var m = DNSMessageBuilder(question: "a.test")
        let loopOffset = m.bytes.count
        m.bytes += [0x01, UInt8(ascii: "x"), 0xC0, UInt8(loopOffset)]
        m.bytes += [0x00, 0x01, 0x00, 0x01, 0, 0, 0, 60, 0x00, 0x04, 10, 0, 0, 4]
        m.setAnswerCount(1)
        let response = try #require(DNSParser.parse(m.data))
        #expect(response.questionName == "a.test")
        #expect(response.answers.isEmpty)
    }

    @Test func forwardPointerChainIsBounded() throws {
        // 40 pointers each jumping to the next: exceeds the jump limit.
        var bytes = header(questions: 1, answers: 0)
        let start = bytes.count
        for i in 0..<40 {
            let target = start + (i + 1) * 2
            bytes += [0xC0 | UInt8(target >> 8), UInt8(target & 0xFF)]
        }
        bytes += [0x00, 0x00, 0x01, 0x00, 0x01]
        #expect(DNSParser.parse(Data(bytes)) == nil)
    }

    @Test func pointerOutOfBoundsAndReservedLabelTypes() {
        let outOfBounds = header(questions: 1, answers: 0) + [0xC0, 0xFF, 0x00, 0x01, 0x00, 0x01]
        #expect(DNSParser.parse(Data(outOfBounds)) == nil)
        let reserved = header(questions: 1, answers: 0) + [0x41, 0x61, 0x00, 0x00, 0x01, 0x00, 0x01]
        #expect(DNSParser.parse(Data(reserved)) == nil)
        let labelPastEnd = header(questions: 1, answers: 0) + [0x3F, 0x61]
        #expect(DNSParser.parse(Data(labelPastEnd)) == nil)
    }

    @Test func overlongNameIsRejected() {
        var bytes = header(questions: 1, answers: 0)
        for _ in 0..<5 { bytes += [63] + [UInt8](repeating: UInt8(ascii: "a"), count: 63) }
        bytes += [0x00, 0x00, 0x01, 0x00, 0x01]
        #expect(DNSParser.parse(Data(bytes)) == nil)
    }

    @Test func randomGarbageNeverCrashes() {
        var rng = SplitMix64(seed: 53)
        let original = [UInt8](Fixtures.dnsResponseA)
        for _ in 0..<5_000 {
            var bytes = original
            for _ in 0..<(1 + rng.next() % 6) {
                bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next())
            }
            _ = DNSParser.parse(Data(bytes))
            _ = DNSParser.parseTCP(Data(bytes))
        }
    }

    private func header(questions: UInt16, answers: UInt16) -> [UInt8] {
        [0xAB, 0xCD, 0x81, 0x80, UInt8(questions >> 8), UInt8(questions & 0xFF),
         UInt8(answers >> 8), UInt8(answers & 0xFF), 0, 0, 0, 0]
    }
}

/// Minimal DNS response writer for hand-built edge cases (uncompressed names
/// unless stated).
struct DNSMessageBuilder {
    var bytes: [UInt8]
    private var answerCount: UInt16 = 0

    init(question: String, isResponse: Bool = true) {
        bytes = [0x00, 0x01, isResponse ? 0x81 : 0x01, isResponse ? 0x80 : 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        bytes += Self.encode(question) + [0x00, 0x01, 0x00, 0x01]
    }

    var data: Data { Data(bytes) }

    static func encode(_ name: String) -> [UInt8] {
        name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    mutating func setAnswerCount(_ count: UInt16) {
        answerCount = count
        bytes[6] = UInt8(count >> 8)
        bytes[7] = UInt8(count & 0xFF)
    }

    mutating func record(name: String, type: UInt16, ttl: UInt32, rdata: [UInt8]) {
        appendRecord(nameBytes: Self.encode(name), type: type, ttl: ttl, rdata: rdata)
    }

    mutating func a(_ name: String, _ ip: [UInt8], ttl: UInt32) {
        record(name: name, type: 1, ttl: ttl, rdata: ip)
    }

    mutating func cname(_ name: String, to target: String, ttl: UInt32) {
        record(name: name, type: 5, ttl: ttl, rdata: Self.encode(target))
    }

    /// A record whose owner name is a compression pointer to the question (offset 12).
    mutating func aAtQuestionPointer(_ ip: [UInt8], ttl: UInt32) {
        appendRecord(nameBytes: [0xC0, 0x0C], type: 1, ttl: ttl, rdata: ip)
    }

    private mutating func appendRecord(nameBytes: [UInt8], type: UInt16, ttl: UInt32, rdata: [UInt8]) {
        bytes += nameBytes
        bytes += [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]
        bytes += [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)]
        bytes += [UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
        setAnswerCount(answerCount + 1)
    }
}
