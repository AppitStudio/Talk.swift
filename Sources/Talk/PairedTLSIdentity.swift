import CryptoKit
import Foundation
import Security

/// Minimal certificate writer for app-private, pinned TLS identities. Certificate
/// parsing, handshake signatures, encryption and trust evaluation remain in Apple's
/// Security/Network frameworks. These certificates are never system trust anchors.
enum PairedTLSIdentity {
    enum Role: String { case client, server }

    static func key(credential: PairingCredential, role: Role) throws -> P256.Signing.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: credential.secret),
                                           salt: Data(credential.id.uuidString.utf8),
                                           info: Data("Talk local spike TLS 1 \(role.rawValue)".utf8), outputByteCount: 32)
        return try derived.withUnsafeBytes { try P256.Signing.PrivateKey(rawRepresentation: Data($0)) }
    }

    static func make(credential: PairingCredential, role: Role) throws -> sec_identity_t {
        let key = try key(credential: credential, role: role)
        let keyAttributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                          kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                          kSecAttrKeySizeInBits as String: 256]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, keyAttributes as CFDictionary, nil) else {
            throw TalkError.credentialStorage
        }
        let algorithm = sequence(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])) // ecdsa-with-SHA256
        let commonName = sequence(tag(0x31, sequence(oid([0x55, 0x04, 0x03]) + tag(0x0C, Data("Talk \(role.rawValue)".utf8)))))
        let serial = tag(0x02, Data([0]) + Data(SHA256.hash(data: key.publicKey.x963Representation).prefix(16)))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let validity = sequence(tag(0x18, Data(formatter.string(from: Date().addingTimeInterval(-86400)).utf8))
                                + tag(0x18, Data(formatter.string(from: Date().addingTimeInterval(30 * 86400)).utf8)))
        let publicKeyAlgorithm = sequence(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]) // id-ecPublicKey
                                          + oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])) // prime256v1
        let publicKeyInfo = sequence(publicKeyAlgorithm + tag(0x03, Data([0]) + key.publicKey.x963Representation))
        let basicConstraints = sequence(oid([0x55, 0x1D, 0x13]) + tag(0x01, Data([0xFF])) + tag(0x04, sequence(Data())))
        let keyUsage = sequence(oid([0x55, 0x1D, 0x0F]) + tag(0x01, Data([0xFF])) + tag(0x04, tag(0x03, Data([7, 0x80]))))
        let extendedUsage = sequence(oid([0x55, 0x1D, 0x25]) + tag(0x04, sequence(oid([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, role == .server ? 1 : 2]))))
        let extensions = tag(0xA3, sequence(basicConstraints + keyUsage + extendedUsage))
        let body = sequence(tag(0xA0, tag(0x02, Data([2]))) + serial + algorithm + commonName + validity + commonName + publicKeyInfo + extensions)
        let signature = try key.signature(for: body).derRepresentation
        let bytes = sequence(body + algorithm + tag(0x03, Data([0]) + signature))
        guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData),
              let identity = SecIdentityCreate(nil, certificate, secKey),
              let protocolIdentity = sec_identity_create(identity) else { throw TalkError.credentialStorage }
        return protocolIdentity
    }

    static func verify(_ trust: SecTrust, expectedPublicKey: Data) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count == 1,
              let certificate = chain.first,
              let key = SecCertificateCopyKey(certificate),
              let publicKey = SecKeyCopyExternalRepresentation(key, nil) as Data?, publicKey == expectedPublicKey else {
            TransportDiagnostics.record("trust rejected stage=chain-or-pin")
            return false
        }
        // Pin first, then validate this self-signed certificate's signature and validity.
        // Never trust a first-seen certificate or consult a caller-supplied hostname.
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
            TransportDiagnostics.record("trust rejected stage=configuration")
            return false
        }
        var error: CFError?
        let accepted = SecTrustEvaluateWithError(trust, &error)
        if !accepted {
            let domain = error.map { CFErrorGetDomain($0) == kCFErrorDomainOSStatus ? "osstatus" : "other" } ?? "missing"
            TransportDiagnostics.record("trust rejected domain=\(domain) code=\(error.map { String(CFErrorGetCode($0)) } ?? "missing")")
        }
        return accepted
    }

    private static func sequence(_ contents: Data) -> Data { tag(0x30, contents) }
    private static func oid(_ bytes: [UInt8]) -> Data { tag(0x06, Data(bytes)) }
    private static func tag(_ value: UInt8, _ contents: Data) -> Data {
        var header = Data([value])
        if contents.count < 128 { header.append(UInt8(contents.count)) }
        else if contents.count <= 255 { header.append(contentsOf: [0x81, UInt8(contents.count)]) }
        else { header.append(contentsOf: [0x82, UInt8(contents.count >> 8), UInt8(contents.count & 255)]) }
        return header + contents
    }
}
