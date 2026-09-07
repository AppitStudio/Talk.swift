import CryptoKit
import Foundation

/// Ephemeral X25519 agreement. URLs carry public keys only. The separate
/// verification code must be compared in the two apps before provider consent.
enum PairingKeyExchange {
    struct Result: Sendable {
        let credential: PairingCredential
        let verificationCode: String
    }

    static func derive(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                       providerPublicKey: Data, consumerPublicKey: Data, sessionID: UUID,
                       requestID: UUID, providerBundleID: String, consumerBundleID: String) throws -> Result {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        // Length-delimited transcript binds roles, both keys, route labels and
        // both nonces. No ambiguous concatenation or cross-session key reuse.
        var transcript = Data()
        for field in [Data("Talk discoverable pairing v1".utf8), providerPublicKey, consumerPublicKey,
                      Data(sessionID.uuidString.utf8), Data(requestID.uuidString.utf8),
                      Data(providerBundleID.utf8), Data(consumerBundleID.utf8)] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { transcript.append(contentsOf: $0) }
            transcript.append(field)
        }
        let salt = Data(SHA256.hash(data: transcript))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: Data("setup TLS credential".utf8), outputByteCount: 32)
        let verification = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                          sharedInfo: Data("visible verification".utf8), outputByteCount: 6)
        let digits = verification.withUnsafeBytes { $0.map { String(format: "%02X", $0) }.joined() }
        let groups = stride(from: 0, to: 12, by: 4).map { offset in
            String(digits.dropFirst(offset).prefix(4))
        }
        return try Result(credential: PairingCredential(id: requestID, secret: key.withUnsafeBytes { Data($0) }),
                          verificationCode: groups.joined(separator: "-"))
    }
}
