import AppKit
import Carbon
import Testing
@testable import Talk

@MainActor struct AuthenticatedAppRoutingTests {
    private let identity = AppIdentity(bundleID: "dev.example.consumer", teamID: "ABCDEFGHIJ")

    @Test func signingRequirementRejectsMissingAndInjectedIdentity() throws {
        _ = try AuthenticatedAppRouting.requirement(for: identity)
        for value in [AppIdentity(bundleID: "", teamID: "ABCDEFGHIJ"),
                      AppIdentity(bundleID: "dev.example.consumer", teamID: ""),
                      AppIdentity(bundleID: "consumer\" or true", teamID: "ABCDEFGHIJ"),
                      AppIdentity(bundleID: "dev.example.consumer", teamID: "ABC\" or true")] {
            #expect(throws: TalkError.permissionDenied) { try AuthenticatedAppRouting.requirement(for: value) }
        }
    }

    @Test func captureNeedsCurrentEventAndNeverTrustsURLClaims() {
        #expect(AuthenticatedAppMessage.capture(URL(string: "talk-spike-provider://connect?bundle=dev.example.consumer&team=ABCDEFGHIJ")!) == nil)
    }

    @Test func messageMustMatchCurrentGURLEventExactly() throws {
        let url = URL(string: "talk-spike-provider://connect?request=synthetic")!
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: keyDirectObject)
        let token = Data(repeating: 0, count: MemoryLayout<audit_token_t>.size)
        event.setAttribute(try #require(NSAppleEventDescriptor(descriptorType: typeAuditToken, data: token)), forKeyword: keySenderAuditTokenAttr)
        // The OS does not accept a sender-supplied audit-token attribute.
        // A constructed Apple event must never become an authenticated message.
        #expect(AuthenticatedAppRouting.senderAuditToken(for: url, event: event) == nil)
        #expect(AuthenticatedAppRouting.senderAuditToken(for: URL(string: "talk-spike-provider://connect?request=different")!, event: event) == nil)
        event.setAttribute(try #require(NSAppleEventDescriptor(descriptorType: typeAuditToken, data: Data(repeating: 0, count: 4))), forKeyword: keySenderAuditTokenAttr)
        #expect(AuthenticatedAppRouting.senderAuditToken(for: url, event: event) == nil)
    }

    @Test func invalidTokenAndUnsignedApplicationFailClosed() {
        #expect(throws: TalkError.permissionDenied) { try AuthenticatedAppRouting.verify(auditToken: Data(repeating: 0, count: 32)) }
        #expect(throws: TalkError.permissionDenied) {
            try AuthenticatedAppRouting.inspect(applicationURL: URL(fileURLWithPath: "/usr/bin/true"), identity: identity)
        }
    }
}
