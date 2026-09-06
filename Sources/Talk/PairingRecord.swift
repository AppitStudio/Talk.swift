import Foundation

public struct PairingRecord: Codable, Sendable, Equatable {
    public let credential: PairingCredential
    public let providerBundleID: String
    public let label: String?
    public let replacesID: UUID?
    public let scopes: Set<String>

    public init(credential: PairingCredential, providerBundleID: String, scopes: Set<String>, replacesID: UUID? = nil, label: String? = nil) {
        self.credential = credential
        self.providerBundleID = providerBundleID
        self.scopes = scopes
        self.replacesID = replacesID
        self.label = label
    }

    public func validate() throws {
        try credential.validate()
        guard replacesID != credential.id else { throw TalkError.invalidMessage }
        guard (label?.utf8.count ?? 0) <= 128 else { throw TalkError.invalidMessage }
        guard !providerBundleID.isEmpty, providerBundleID.utf8.count <= 255,
              !scopes.isEmpty, scopes.count <= 64,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw TalkError.invalidMessage }
    }

    public func permits(_ scope: String) -> Bool { scopes.contains(scope) }
}
