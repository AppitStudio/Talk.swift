import Foundation
import Testing
@testable import Talk

struct PairingTests {
    @Test func invitationsExpireAndRejectInvalidInput() throws {
        let credential = try PairingCredential()
        let now = Date()
        let invitation = PairingInvitation(credential: credential, port: 12345, providerBundleID: "dev.example.provider", expiresAt: now.addingTimeInterval(60))
        let code = try invitation.code()
        #expect(try PairingInvitation.parse(code, now: now).credential == credential)
        #expect(throws: TalkError.invitationExpired) { try PairingInvitation.parse(code, now: now.addingTimeInterval(61)) }
        #expect(throws: TalkError.invalidInvitation) { try PairingInvitation.parse("https://example.invalid") }
        #expect(throws: TalkError.invalidInvitation) { try PairingInvitation.parse(String(repeating: "x", count: 5000)) }
    }

    @Test func scopesAreExplicit() throws {
        let grant = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["read"])
        #expect(grant.permits("read"))
        #expect(grant.permits("write") == false)
        #expect(grant.permits("*") == false)
    }
}
