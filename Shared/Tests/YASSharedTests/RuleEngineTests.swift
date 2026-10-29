import Foundation
import Testing
@testable import YASShared

// MARK: - Fixtures

private let safari = AppIdentity(
    bundleID: "com.apple.Safari", signingID: "com.apple.Safari", teamID: nil,
    executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
    isAppleSigned: true, isValidlySigned: true)
private let slack = AppIdentity(
    bundleID: "com.tinyspeck.slackmacgap", signingID: "com.tinyspeck.slackmacgap", teamID: "BQR82RBBHL",
    executablePath: "/Applications/Slack.app/Contents/MacOS/Slack",
    isAppleSigned: false, isValidlySigned: true)
private let curlTool = AppIdentity(
    bundleID: nil, signingID: nil, teamID: nil,
    executablePath: "/opt/homebrew/bin/curl", isAppleSigned: false, isValidlySigned: false)
private let yas = AppIdentity(
    bundleID: "com.gful.yas", signingID: "com.gful.yas", teamID: "ABCDE12345",
    executablePath: "/Applications/YAS.app/Contents/MacOS/YAS",
    isAppleSigned: false, isValidlySigned: true)

private func flow(
    _ app: AppIdentity, host: String? = "www.example.com", ip: String = "93.184.216.34",
    direction: FlowDirection = .outbound
) -> FlowDescriptor {
    FlowDescriptor(app: app, host: host, ip: ip, port: 443, proto: .tcp, direction: direction)
}

private func rule(_ target: RuleTarget, _ action: RuleAction, enabled: Bool = true) -> Rule {
    Rule(target: target, action: action, isEnabled: enabled, createdAt: Date(timeIntervalSince1970: 0))
}

private func evaluate(
    _ flow: FlowDescriptor, _ mode: FilterMode, _ rules: [Rule],
    options: EngineOptions = .default, hostIsFinal: Bool = false
) -> Evaluation {
    RuleEngine.evaluate(flow, mode: mode, rules: rules, options: options, hostIsFinal: hostIsFinal)
}

// MARK: - Modes

@Suite("RuleEngine modes")
struct RuleEngineModeTests {
    @Test func allowAllIgnoresBlockRules() {
        let rules = [rule(.app(slack), .block), rule(.domain("example.com", includeSubdomains: true), .block)]
        #expect(evaluate(flow(slack), .allowAll, rules) == Evaluation(decision: .allow))
        // Even with an unknown host, allowAll never asks for more data.
        #expect(evaluate(flow(slack, host: nil), .allowAll, rules).decision == .allow)
    }

    @Test func blockAllIgnoresAllowRules() {
        let rules = [rule(.app(slack), .allow), rule(.domain("example.com", includeSubdomains: true), .allow)]
        #expect(evaluate(flow(slack), .blockAll, rules) == Evaluation(decision: .block))
        #expect(evaluate(flow(slack, host: nil), .blockAll, rules).decision == .block)
    }

    @Test func blockAllExemptsYASByDefault() {
        #expect(evaluate(flow(yas), .blockAll, []).decision == .allow)
        #expect(evaluate(flow(safari), .blockAll, []).decision == .block)
    }

    @Test func blockAllDoesNotExemptAdHocImpostor() {
        // Ad-hoc signed (no team, not Apple): the signing ID is forgeable.
        let impostor = AppIdentity(
            bundleID: "com.gful.yas", signingID: "com.gful.yas", teamID: nil,
            executablePath: "/tmp/YAS", isAppleSigned: false, isValidlySigned: true)
        #expect(evaluate(flow(impostor), .blockAll, []).decision == .block)
        let invalid = AppIdentity(
            bundleID: "com.gful.yas", signingID: "com.gful.yas", teamID: "ABCDE12345",
            executablePath: "/tmp/YAS", isAppleSigned: false, isValidlySigned: false)
        #expect(evaluate(flow(invalid), .blockAll, []).decision == .block)
    }

    @Test func blockAllExemptionRespectsTeamID() {
        let pinned = EngineOptions(blockAllExemptTeamID: "ABCDE12345")
        #expect(evaluate(flow(yas), .blockAll, [], options: pinned).decision == .allow)
        let otherTeam = EngineOptions(blockAllExemptTeamID: "ZZZZZ99999")
        #expect(evaluate(flow(yas), .blockAll, [], options: otherTeam).decision == .block)
    }

    @Test func blockAllExemptMatchKeys() {
        let options = EngineOptions(blockAllExemptMatchKeys: [curlTool.matchKey], blockAllExemptSigningIDs: [])
        #expect(evaluate(flow(curlTool), .blockAll, [], options: options).decision == .allow)
        #expect(evaluate(flow(yas), .blockAll, [], options: options).decision == .block)
    }

    @Test func blockListDefaultsToAllow() {
        #expect(evaluate(flow(slack), .blockList, []) == Evaluation(decision: .allow))
    }

    @Test func requireApprovalWithoutRulesNeedsApproval() {
        #expect(evaluate(flow(slack), .requireApproval, []) == Evaluation(decision: .needsApproval))
    }
}

// MARK: - Rule kinds per mode

@Suite("RuleEngine rule kinds")
struct RuleEngineRuleKindTests {
    static let modes: [FilterMode] = [.blockList, .requireApproval]

    @Test(arguments: modes)
    func appBlockRule(mode: FilterMode) {
        let r = rule(.app(slack), .block)
        #expect(evaluate(flow(slack), mode, [r]) == Evaluation(decision: .block, matchedRuleID: r.id))
        // Other apps are unaffected.
        #expect(evaluate(flow(safari), mode, [r]).matchedRuleID == nil)
    }

    @Test(arguments: modes)
    func appAllowRule(mode: FilterMode) {
        let r = rule(.app(slack), .allow)
        #expect(evaluate(flow(slack), mode, [r]) == Evaluation(decision: .allow, matchedRuleID: r.id))
    }

    @Test(arguments: modes)
    func domainBlockRule(mode: FilterMode) {
        let r = rule(.domain("example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack, host: "ads.example.com"), mode, [r]) == Evaluation(decision: .block, matchedRuleID: r.id))
        #expect(evaluate(flow(safari, host: "example.com"), mode, [r]).decision == .block)
        #expect(evaluate(flow(safari, host: "badexample.com"), mode, [r]).decision != .block)
    }

    @Test(arguments: modes)
    func domainAllowRule(mode: FilterMode) {
        let r = rule(.domain("example.com", includeSubdomains: true), .allow)
        #expect(evaluate(flow(slack, host: "cdn.example.com"), mode, [r]) == Evaluation(decision: .allow, matchedRuleID: r.id))
    }

    @Test(arguments: modes)
    func appDomainBlockRuleIsScopedToApp(mode: FilterMode) {
        let r = rule(.appDomain(slack, "example.com"), .block)
        #expect(evaluate(flow(slack, host: "files.example.com"), mode, [r]) == Evaluation(decision: .block, matchedRuleID: r.id))
        #expect(evaluate(flow(safari, host: "files.example.com"), mode, [r]).decision != .block)
        #expect(evaluate(flow(slack, host: "example.org"), mode, [r]).decision != .block)
    }

    @Test(arguments: modes)
    func appDomainAllowRule(mode: FilterMode) {
        let r = rule(.appDomain(slack, "slack.com"), .allow)
        #expect(evaluate(flow(slack, host: "edge.slack.com"), mode, [r]) == Evaluation(decision: .allow, matchedRuleID: r.id))
    }

    @Test func requireApprovalAppDomainAllowDoesNotCoverOtherDomains() {
        let r = rule(.appDomain(slack, "slack.com"), .allow)
        #expect(evaluate(flow(slack, host: "tracker.example.net"), .requireApproval, [r]) == Evaluation(decision: .needsApproval))
    }

    @Test func exactDomainRuleDoesNotMatchSubdomains() {
        let r = rule(.domain("example.com", includeSubdomains: false), .block)
        #expect(evaluate(flow(slack, host: "example.com"), .blockList, [r]).decision == .block)
        #expect(evaluate(flow(slack, host: "EXAMPLE.com."), .blockList, [r]).decision == .block)
        #expect(evaluate(flow(slack, host: "www.example.com"), .blockList, [r]).decision == .allow)
    }

    @Test func flowHostIsNormalized() {
        let r = rule(.domain("Example.COM.", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack, host: "WWW.EXAMPLE.COM."), .blockList, [r]).decision == .block)
    }
}

// MARK: - Precedence and disabled rules

@Suite("RuleEngine precedence")
struct RuleEnginePrecedenceTests {
    @Test func blockBeatsMoreSpecificAllow() {
        let allowAppDomain = rule(.appDomain(slack, "example.com"), .allow)
        let blockApp = rule(.app(slack), .block)
        #expect(evaluate(flow(slack), .blockList, [allowAppDomain, blockApp])
            == Evaluation(decision: .block, matchedRuleID: blockApp.id))
    }

    @Test func domainBlockBeatsAppAllow() {
        let allowApp = rule(.app(slack), .allow)
        let blockDomain = rule(.domain("example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack), .requireApproval, [allowApp, blockDomain])
            == Evaluation(decision: .block, matchedRuleID: blockDomain.id))
    }

    @Test(arguments: [RuleAction.block, .allow])
    func specificityPicksAppDomainThenDomainThenApp(action: RuleAction) {
        let app = rule(.app(slack), action)
        let domain = rule(.domain("example.com", includeSubdomains: true), action)
        let appDomain = rule(.appDomain(slack, "example.com"), action)
        let expected: Evaluation.Decision = action == .block ? .block : .allow

        // List order must not matter.
        for rules in [[app, domain, appDomain], [appDomain, domain, app], [domain, app, appDomain]] {
            #expect(evaluate(flow(slack), .requireApproval, rules) == Evaluation(decision: expected, matchedRuleID: appDomain.id))
        }
        for rules in [[app, domain], [domain, app]] {
            #expect(evaluate(flow(slack), .requireApproval, rules) == Evaluation(decision: expected, matchedRuleID: domain.id))
        }
    }

    @Test func longerDomainWinsWithinTier() {
        let broad = rule(.domain("example.com", includeSubdomains: true), .block)
        let narrow = rule(.domain("www.example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack), .blockList, [broad, narrow]).matchedRuleID == narrow.id)
        #expect(evaluate(flow(slack), .blockList, [narrow, broad]).matchedRuleID == narrow.id)
    }

    @Test func disabledBlockRuleIsIgnored() {
        let r = rule(.app(slack), .block, enabled: false)
        #expect(evaluate(flow(slack), .blockList, [r]) == Evaluation(decision: .allow))
        let d = rule(.domain("example.com", includeSubdomains: true), .block, enabled: false)
        #expect(evaluate(flow(slack), .blockList, [d]) == Evaluation(decision: .allow))
    }

    @Test func disabledAllowRuleIsIgnored() {
        let r = rule(.app(slack), .allow, enabled: false)
        #expect(evaluate(flow(slack), .requireApproval, [r]) == Evaluation(decision: .needsApproval))
    }

    @Test func disabledBlockDoesNotShadowEnabledAllow() {
        let block = rule(.app(slack), .block, enabled: false)
        let allow = rule(.app(slack), .allow)
        #expect(evaluate(flow(slack), .requireApproval, [block, allow]) == Evaluation(decision: .allow, matchedRuleID: allow.id))
    }
}

// MARK: - Unknown host

@Suite("RuleEngine needsMoreData")
struct RuleEngineNeedsMoreDataTests {
    @Test(arguments: [FilterMode.blockList, .requireApproval])
    func domainBlockRuleWithUnknownHostNeedsMoreData(mode: FilterMode) {
        let r = rule(.domain("example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack, host: nil), mode, [r]) == Evaluation(decision: .needsMoreData))
    }

    @Test func emptyHostCountsAsUnknown() {
        let r = rule(.domain("example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack, host: " . "), .blockList, [r]).decision == .needsMoreData)
    }

    @Test func appDomainBlockRuleForThisAppNeedsMoreData() {
        let r = rule(.appDomain(slack, "example.com"), .block)
        #expect(evaluate(flow(slack, host: nil), .blockList, [r]).decision == .needsMoreData)
    }

    @Test func appDomainRuleForAnotherAppDoesNotNeedMoreData() {
        let r = rule(.appDomain(safari, "example.com"), .block)
        #expect(evaluate(flow(slack, host: nil), .blockList, [r]) == Evaluation(decision: .allow))
    }

    @Test func disabledDomainRuleDoesNotNeedMoreData() {
        let r = rule(.domain("example.com", includeSubdomains: true), .block, enabled: false)
        #expect(evaluate(flow(slack, host: nil), .blockList, [r]) == Evaluation(decision: .allow))
    }

    @Test func matchingAppBlockWinsWithoutMoreData() {
        let block = rule(.app(slack), .block)
        let domain = rule(.domain("example.com", includeSubdomains: true), .allow)
        #expect(evaluate(flow(slack, host: nil), .requireApproval, [block, domain])
            == Evaluation(decision: .block, matchedRuleID: block.id))
    }

    @Test func domainAllowRulesCannotChangeBlockListOutcome() {
        // blockList without a block rule already allows, so peeking is pointless.
        let r = rule(.domain("example.com", includeSubdomains: true), .allow)
        #expect(evaluate(flow(slack, host: nil), .blockList, [r]) == Evaluation(decision: .allow))
    }

    @Test func domainAllowRuleCanResolveApproval() {
        let r = rule(.domain("example.com", includeSubdomains: true), .allow)
        #expect(evaluate(flow(slack, host: nil), .requireApproval, [r]) == Evaluation(decision: .needsMoreData))
    }

    @Test func appAllowedButDomainBlockPendingNeedsMoreData() {
        let allow = rule(.app(slack), .allow)
        let block = rule(.domain("example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack, host: nil), .blockList, [allow, block]).decision == .needsMoreData)
    }

    @Test func hostIsFinalGivesADecision() {
        let block = rule(.domain("example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack, host: nil), .blockList, [block], hostIsFinal: true) == Evaluation(decision: .allow))
        let allow = rule(.domain("example.com", includeSubdomains: true), .allow)
        #expect(evaluate(flow(slack, host: nil), .requireApproval, [allow], hostIsFinal: true) == Evaluation(decision: .needsApproval))
    }

    @Test func inboundFlowsNeverNeedMoreData() {
        let r = rule(.domain("example.com", includeSubdomains: true), .block)
        #expect(evaluate(flow(slack, host: nil, direction: .inbound), .blockList, [r]) == Evaluation(decision: .allow))
    }
}

// MARK: - App identity

@Suite("AppIdentity.matchKey")
struct AppIdentityTests {
    @Test func signedAppMatchesAcrossPaths() {
        let moved = AppIdentity(
            bundleID: slack.bundleID, signingID: slack.signingID, teamID: slack.teamID,
            executablePath: "/Users/me/Downloads/Slack.app/Contents/MacOS/Slack",
            isAppleSigned: false, isValidlySigned: true)
        #expect(moved.matchKey == slack.matchKey)
        let r = rule(.app(slack), .block)
        #expect(evaluate(flow(moved), .blockList, [r]).decision == .block)
    }

    @Test func sameSigningIDDifferentTeamDoesNotMatch() {
        let fake = AppIdentity(
            bundleID: slack.bundleID, signingID: slack.signingID, teamID: "EVIL000000",
            executablePath: slack.executablePath, isAppleSigned: false, isValidlySigned: true)
        #expect(fake.matchKey != slack.matchKey)
        #expect(evaluate(flow(fake), .blockList, [rule(.app(slack), .block)]).decision == .allow)
    }

    @Test func unsignedAndAdHocMatchByPath() {
        #expect(curlTool.matchKey == "path:/opt/homebrew/bin/curl")
        let adHoc = AppIdentity(
            bundleID: nil, signingID: "a.out-55555", teamID: nil, executablePath: "/usr/local/bin/tool",
            isAppleSigned: false, isValidlySigned: true)
        #expect(adHoc.matchKey == "path:/usr/local/bin/tool")
    }

    @Test func appleSignedUsesAppleMarker() {
        #expect(safari.matchKey == "sig:apple:com.apple.Safari")
        #expect(slack.matchKey == "sig:BQR82RBBHL:com.tinyspeck.slackmacgap")
    }
}
