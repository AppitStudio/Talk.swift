import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Talk

struct ProductionCredentialTests {
    @Test func selectsApplicationGroupEvenWhenSharedGroupIsFirst() throws {
        let value = try CredentialStore.applicationIdentifier(codeIdentifier: "dev.talk.synthetic.host", entitlements: [
            "com.apple.application-identifier": "OLDPREFIX.dev.talk.synthetic.host",
            "keychain-access-groups": ["TEAM.shared", "OLDPREFIX.dev.talk.synthetic.host"]
        ])
        #expect(value == "OLDPREFIX.dev.talk.synthetic.host")
        let query = CredentialStore.query(service: "synthetic", applicationIdentifier: value)
        #expect(query[kSecAttrAccessGroup as String] as? String == value)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    }

    @Test(arguments: [nil, "", "PREFIX.*", "PREFIX.dev.talk.synthetic.other", ".dev.talk.synthetic.host", "PREFIX\0.dev.talk.synthetic.host"] as [String?])
    func rejectsMissingOrMismatchedAppIdentity(_ identifier: String?) {
        var entitlements: [String: Any] = ["keychain-access-groups": ["PREFIX.shared"]]
        entitlements["com.apple.application-identifier"] = identifier
        #expect(throws: TalkError.credentialConfiguration) {
            try CredentialStore.applicationIdentifier(codeIdentifier: "dev.talk.synthetic.host", entitlements: entitlements)
        }
    }

    @Test func missingEntitlementIsConfigurationFailure() {
        #expect(throws: TalkError.credentialConfiguration) { try CredentialStore.check(errSecMissingEntitlement) }
        #expect(throws: TalkError.credentialLocked) { try CredentialStore.check(errSecInteractionNotAllowed) }
        #expect(throws: TalkError.credentialStorage) { try CredentialStore.check(errSecDecode) }
    }

    @Test func invalidServiceFailsBeforeKeychainAccess() async throws {
        for service in ["", "synthetic\0invalid", String(repeating: "x", count: 1025)] {
            let store = CredentialStore(service: service)
            await #expect(throws: TalkError.credentialConfiguration) { try await store.loadRecords() }
            await #expect(throws: TalkError.credentialConfiguration) { try await store.saveRecords([]) }
            await #expect(throws: TalkError.credentialConfiguration) { try await store.delete() }
        }
    }
}
