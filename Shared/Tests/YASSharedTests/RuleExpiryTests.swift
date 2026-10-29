import Foundation
import Testing
@testable import YASShared

private let chrome = AppIdentity(
    bundleID: "com.google.Chrome", signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV",
    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    isAppleSigned: false, isValidlySigned: true)
// Millisecond-exact so it survives ISO 8601 with fractional seconds.
private let now = Date(timeIntervalSince1970: 1_790_000_000.5)

private func flow(host: String? = "www.example.com") -> FlowDescriptor {
    FlowDescriptor(app: chrome, host: host, ip: "93.184.215.14", port: 443, proto: .tcp, direction: .outbound)
}

@Suite("Rule expiry")
struct RuleExpiryTests {
    @Test func legacyPayloadWithoutExpiresAtDecodes() throws {
        // A rule as encoded before `expiresAt` existed.
        let json = """
        [{"action":"block","createdAt":"2026-09-01T10:00:00.000Z","id":"6F1B6C8B-2E47-4E30-9C5B-4B1E2E3A0A11",\
        "isEnabled":true,"note":"old","target":{"domain":{"_0":"example.com","includeSubdomains":true}}}]
        """
        let rules = try PayloadCoder.decode([Rule].self, from: Data(json.utf8))
        #expect(rules.count == 1)
        #expect(rules[0].expiresAt == nil)
        #expect(rules[0].note == "old")
        #expect(rules[0].isInEffect(at: now))
    }

    @Test func expiresAtRoundTripsAndIsOmittedWhenNil() throws {
        let timed = Rule(target: .app(chrome), action: .block, createdAt: now, expiresAt: now.addingTimeInterval(900))
        let decoded = try PayloadCoder.decode(Rule.self, from: PayloadCoder.encode(timed))
        #expect(decoded == timed)
        let untimed = String(decoding: try PayloadCoder.encode(Rule(target: .app(chrome), action: .block, createdAt: now)), as: UTF8.self)
        #expect(!untimed.contains("expiresAt"), "old decoders never see the new key for permanent rules")
    }

    @Test func expiredRulesAreIgnoredAtTheExactBoundary() {
        let rule = Rule(target: .app(chrome), action: .block, expiresAt: now)
        let before = RuleEngine.evaluate(flow(), mode: .blockList, rules: [rule], now: now.addingTimeInterval(-0.001))
        #expect(before.decision == .block)
        #expect(before.matchedRuleID == rule.id)
        #expect(RuleEngine.evaluate(flow(), mode: .blockList, rules: [rule], now: now).decision == .allow,
                "a rule expiring exactly now no longer applies")
        #expect(RuleEngine.evaluate(flow(), mode: .blockList, rules: [rule], now: now.addingTimeInterval(60)).decision == .allow)
    }

    @Test func expiryAppliesToEveryRuleKindAndMode() {
        let expiredDomain = Rule(target: .domain("example.com", includeSubdomains: true), action: .block, expiresAt: now)
        let expiredAppDomain = Rule(target: .appDomain(chrome, "example.com"), action: .block, expiresAt: now)
        #expect(RuleEngine.evaluate(flow(), mode: .blockList, rules: [expiredDomain, expiredAppDomain], now: now).decision == .allow)

        // Require Approval: an expired allow rule no longer exempts the app from prompting.
        let expiredAllow = Rule(target: .app(chrome), action: .allow, expiresAt: now)
        #expect(RuleEngine.evaluate(flow(), mode: .requireApproval, rules: [expiredAllow], hostIsFinal: true, now: now).decision
            == .needsApproval)

        // An expired domain rule must not trigger an SNI peek for an unknown host.
        #expect(RuleEngine.evaluate(flow(host: nil), mode: .blockList, rules: [expiredDomain], now: now).decision == .allow)
        let liveDomain = Rule(target: .domain("example.com", includeSubdomains: true), action: .block, expiresAt: now.addingTimeInterval(1))
        #expect(RuleEngine.evaluate(flow(host: nil), mode: .blockList, rules: [liveDomain], now: now).decision == .needsMoreData)
    }

    @Test func permanentAndTimedRulesCombine() {
        let timedBlock = Rule(target: .app(chrome), action: .block, expiresAt: now.addingTimeInterval(300))
        let permanentAllow = Rule(target: .app(chrome), action: .allow)
        #expect(RuleEngine.evaluate(flow(), mode: .blockList, rules: [timedBlock, permanentAllow], now: now).decision == .block)
        #expect(RuleEngine.evaluate(flow(), mode: .blockList, rules: [timedBlock, permanentAllow], now: now.addingTimeInterval(300)).decision
            == .allow, "after the timed block ends the permanent allow applies again")
    }
}
