import Foundation

public struct PairingRecord: Codable, Sendable, Equatable {
    public let credential: PairingCredential
    public let providerBundleID: String
    public let label: String?
    public let replacesID: UUID?
    public let scopes: Set<String>
    /// Present for authenticated local setup. Older saved grants decode with
    /// nil and keep their existing key-based reconnect behavior.
    public let consumerIdentity: AppIdentity?

    public init(credential: PairingCredential, providerBundleID: String, scopes: Set<String>, replacesID: UUID? = nil, label: String? = nil, consumerIdentity: AppIdentity? = nil) {
        self.credential = credential
        self.providerBundleID = providerBundleID
        self.scopes = scopes
        self.replacesID = replacesID
        self.label = label
        self.consumerIdentity = consumerIdentity
    }

    public func validate() throws {
        try credential.validate()
        guard replacesID != credential.id else { throw TalkError.invalidMessage }
        guard (label?.utf8.count ?? 0) <= 128 else { throw TalkError.invalidMessage }
        if let identity = consumerIdentity {
            guard PairingRouting.validBundleID(identity.bundleID), !identity.teamID.isEmpty,
                  identity.teamID.utf8.count <= 64,
                  identity.teamID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) else {
                throw TalkError.invalidMessage
            }
        }
        guard !providerBundleID.isEmpty, providerBundleID.utf8.count <= 255,
              !scopes.isEmpty, scopes.count <= 64,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw TalkError.invalidMessage }
    }

    public func permits(_ scope: String) -> Bool { scopes.contains(scope) }
}
