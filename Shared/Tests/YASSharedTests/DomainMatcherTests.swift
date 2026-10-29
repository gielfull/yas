import Testing
@testable import YASShared

@Suite("DomainMatcher")
struct DomainMatcherTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let host: String
        let domain: String
        let includeSubdomains: Bool
        let expected: Bool
        var testDescription: String { "\(host) ~ \(domain) sub=\(includeSubdomains) -> \(expected)" }
    }

    static let cases: [Case] = [
        Case(host: "example.com", domain: "example.com", includeSubdomains: true, expected: true),
        Case(host: "ads.example.com", domain: "example.com", includeSubdomains: true, expected: true),
        Case(host: "a.b.ads.example.com", domain: "example.com", includeSubdomains: true, expected: true),
        Case(host: "badexample.com", domain: "example.com", includeSubdomains: true, expected: false),
        Case(host: "example.com.evil.net", domain: "example.com", includeSubdomains: true, expected: false),
        Case(host: "example.com", domain: "ads.example.com", includeSubdomains: true, expected: false),
        Case(host: "ads.example.com", domain: "example.com", includeSubdomains: false, expected: false),
        Case(host: "example.com", domain: "example.com", includeSubdomains: false, expected: true),
        Case(host: "example.com.", domain: "example.com", includeSubdomains: false, expected: true),
        Case(host: "ads.example.com", domain: "example.com.", includeSubdomains: true, expected: true),
        Case(host: "ADS.Example.COM", domain: "example.com", includeSubdomains: true, expected: true),
        Case(host: "example.com", domain: "EXAMPLE.COM", includeSubdomains: false, expected: true),
        Case(host: "com", domain: "example.com", includeSubdomains: true, expected: false),
        Case(host: "", domain: "example.com", includeSubdomains: true, expected: false),
        Case(host: "example.com", domain: "", includeSubdomains: true, expected: false),
        Case(host: ".", domain: ".", includeSubdomains: true, expected: false),
    ]

    @Test(arguments: cases)
    func matching(_ c: Case) {
        #expect(DomainMatcher.matches(host: c.host, domain: c.domain, includeSubdomains: c.includeSubdomains) == c.expected)
    }

    @Test func normalize() {
        #expect(DomainMatcher.normalize(" WWW.Example.COM.. ") == "www.example.com")
        #expect(DomainMatcher.normalize(".") == "")
    }
}
