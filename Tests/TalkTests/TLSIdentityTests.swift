import Foundation
import Security
import Testing
@testable import Talk

struct TLSIdentityTests {
    @Test func roleKeysAreDistinctAndOnlyThePairedKeyIsTrusted() throws {
        let credential = try PairingCredential()
        let clientKey = try PairedTLSIdentity.key(credential: credential, role: .client).publicKey.x963Representation
        let serverKey = try PairedTLSIdentity.key(credential: credential, role: .server).publicKey.x963Representation
        #expect(clientKey != serverKey)
        let identity = try PairedTLSIdentity.make(credential: credential, role: .server)
        let secIdentity = try #require(sec_identity_copy_ref(identity)).takeRetainedValue()
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess)
        let cert = try #require(certificate)
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let resolved = try #require(trust)
        #expect(PairedTLSIdentity.verify(resolved, expectedPublicKey: serverKey))
        #expect(PairedTLSIdentity.verify(resolved, expectedPublicKey: clientKey) == false)
    }

    @Test func credentialDescriptionsAreRedacted() throws {
        let credential = try PairingCredential()
        #expect(String(describing: credential) == "PairingCredential(<redacted>)")
        #expect(String(reflecting: credential) == "PairingCredential(<redacted>)")
    }
}
