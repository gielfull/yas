import Foundation
import Testing
@testable import YASShared

private let app = AppIdentity(
    bundleID: "com.tinyspeck.slackmacgap", signingID: "com.tinyspeck.slackmacgap", teamID: "BQR82RBBHL",
    executablePath: "/Applications/Slack.app/Contents/MacOS/Slack", isAppleSigned: false, isValidlySigned: true)
private let cli = AppIdentity(
    bundleID: nil, signingID: nil, teamID: nil, executablePath: "/usr/local/bin/tool",
    isAppleSigned: false, isValidlySigned: false)
// Millisecond-exact so it survives ISO 8601 with fractional seconds.
private let stamp = Date(timeIntervalSince1970: 1_758_463_200.25)

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try PayloadCoder.encode(value)
    return try PayloadCoder.decode(T.self, from: data)
}

@Suite("XPC payload coding")
struct PayloadTests {
    @Test func rulesOfEveryKindRoundTrip() throws {
        let rules = [
            Rule(target: .app(app), action: .block, isEnabled: true, createdAt: stamp, note: "no chat"),
            Rule(target: .app(cli), action: .allow, isEnabled: false, createdAt: stamp),
            Rule(target: .domain("example.com", includeSubdomains: true), action: .block, createdAt: stamp),
            Rule(target: .domain("exact.example.com", includeSubdomains: false), action: .allow, createdAt: stamp),
            Rule(target: .appDomain(app, "slack.com"), action: .allow, createdAt: stamp),
        ]
        #expect(try roundTrip(rules) == rules)
    }

    @Test func flowEventsRoundTrip() throws {
        let events = [
            FlowEvent(id: UUID(), timestamp: stamp, app: app, remoteHost: "edge.slack.com", remoteIP: "1.2.3.4",
                      remotePort: 443, proto: .tcp, direction: .outbound, verdict: .allowed, matchedRuleID: UUID()),
            FlowEvent(id: UUID(), timestamp: stamp, app: cli, remoteHost: nil, remoteIP: "2001:db8::1",
                      remotePort: 53, proto: .udp, direction: .inbound, verdict: .pending, matchedRuleID: nil),
        ]
        #expect(try roundTrip(events) == events)
    }

    @Test func trafficStatsRoundTrip() throws {
        let stats = [TrafficStat(flowID: UUID(), bytesInDelta: 1 << 40, bytesOutDelta: 0, timestamp: stamp)]
        #expect(try roundTrip(stats) == stats)
    }

    @Test func approvalRequestRoundTrip() throws {
        let request = ApprovalRequest(
            requestID: UUID(), app: app,
            destinations: [
                ApprovalDestination(host: "slack.com", ip: "1.2.3.4", port: 443, proto: .tcp, count: 3),
                ApprovalDestination(host: nil, ip: "5.6.7.8", port: 3478, proto: .udp, count: 1),
            ],
            firstSeen: stamp)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.requestCount == 4)
    }

    @Test(arguments: [
        ApprovalDecision(action: .allow, scope: .once),
        ApprovalDecision(action: .allow, scope: .always),
        ApprovalDecision(action: .block, scope: .once, domain: "tracker.example.com"),
        ApprovalDecision(action: .block, scope: .always, domain: "tracker.example.com"),
    ])
    func approvalDecisionRoundTrip(decision: ApprovalDecision) throws {
        #expect(try roundTrip(decision) == decision)
    }

    @Test func datesAreISO8601WithMilliseconds() throws {
        let data = try PayloadCoder.encode(TrafficStat(flowID: UUID(), bytesInDelta: 1, bytesOutDelta: 2, timestamp: stamp))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"timestamp\":\"2025-09-21T14:00:00.250Z\""))
    }

    @Test func decodesWholeSecondDates() throws {
        let json = #"{"flowID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","bytesInDelta":1,"bytesOutDelta":2,"timestamp":"2025-09-21T14:00:00Z"}"#
        let stat = try PayloadCoder.decode(TrafficStat.self, from: Data(json.utf8))
        #expect(stat.timestamp == Date(timeIntervalSince1970: 1_758_463_200))
    }

    @Test func rejectsNonISODates() {
        let json = #"{"flowID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","bytesInDelta":1,"bytesOutDelta":2,"timestamp":12345}"#
        #expect(throws: DecodingError.self) { try PayloadCoder.decode(TrafficStat.self, from: Data(json.utf8)) }
    }

    @Test func decisionMakesPersistentRuleOnlyForAlways() throws {
        #expect(ApprovalDecision(action: .allow, scope: .once).makeRule(for: app) == nil)

        let appRule = try #require(ApprovalDecision(action: .block, scope: .always).makeRule(for: app))
        #expect(appRule.target == .app(app))
        #expect(appRule.action == .block)
        #expect(appRule.isEnabled)

        let scoped = try #require(ApprovalDecision(action: .allow, scope: .always, domain: "slack.com").makeRule(for: app))
        #expect(scoped.target == .appDomain(app, "slack.com"))

        let blankDomain = try #require(ApprovalDecision(action: .allow, scope: .always, domain: " ").makeRule(for: app))
        #expect(blankDomain.target == .app(app))
    }
}

@Suite("XPC contract")
struct XPCContractTests {
    @Test func identifiersMatchBundleIDs() {
        #expect(XPCConstants.appBundleID == "com.gful.yas")
        #expect(XPCConstants.filterBundleID == "com.gful.yas.filter")
        #expect(XPCConstants.appGroup == "group.com.gful.yas")
        #expect(XPCConstants.machServiceName == "group.com.gful.yas.filter.xpc")
        // The Mach service must live under the app group for the sandbox to allow it.
        #expect(XPCConstants.machServiceName.hasPrefix(XPCConstants.appGroup + "."))
    }

    @Test func codeSigningRequirement() {
        #expect(XPCConstants.codeSigningRequirement(teamID: "ABCDE12345")
            == #"anchor apple generic and identifier "com.gful.yas" and certificate leaf[subject.OU] = "ABCDE12345""#)
        #expect(XPCConstants.codeSigningRequirement(teamID: "ABCDE12345", identifier: XPCConstants.filterBundleID)?
            .contains(#"identifier "com.gful.yas.filter""#) == true)
    }

    @Test(arguments: ["", "ABC\" or anchor apple", "ABC DEF", "ÄBCDE12345"])
    func codeSigningRequirementRejectsInjection(teamID: String) {
        #expect(XPCConstants.codeSigningRequirement(teamID: teamID) == nil)
    }

    @Test func protocolsAreObjCExposed() {
        // NSXPCInterface requires @objc protocols with the contract selectors.
        let control = NSXPCInterface(with: FilterControlProtocol.self)
        let events = NSXPCInterface(with: FilterEventsProtocol.self)
        #expect(control.protocol === FilterControlProtocol.self as Protocol)
        #expect(events.protocol === FilterEventsProtocol.self as Protocol)
        #expect(NSStringFromSelector(#selector(FilterControlProtocol.register(reply:))) == "registerWithReply:")
        #expect(NSStringFromSelector(#selector(FilterControlProtocol.setMode(_:reply:))) == "setMode:reply:")
        #expect(NSStringFromSelector(#selector(FilterControlProtocol.replaceRules(_:reply:))) == "replaceRules:reply:")
        #expect(NSStringFromSelector(#selector(FilterControlProtocol.resolveApproval(_:decisionJSON:))) == "resolveApproval:decisionJSON:")
        #expect(NSStringFromSelector(#selector(FilterEventsProtocol.flowsObserved(_:))) == "flowsObserved:")
        #expect(NSStringFromSelector(#selector(FilterEventsProtocol.trafficStats(_:))) == "trafficStats:")
        #expect(NSStringFromSelector(#selector(FilterEventsProtocol.approvalRequested(_:))) == "approvalRequested:")
    }

    @Test func modeTravelsAsRawValue() {
        for mode in FilterMode.allCases {
            #expect(FilterMode(rawValue: mode.rawValue) == mode)
        }
        #expect(FilterMode(rawValue: "bogus") == nil)
    }
}
