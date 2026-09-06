import Foundation

public struct PairingInvitation: Codable, Sendable {
    public let version: Int
    public let credential: PairingCredential
    public let port: UInt16
    public let providerBundleID: String
    public let expiresAt: Date

    public init(credential: PairingCredential, port: UInt16, providerBundleID: String, expiresAt: Date) {
        version = 1
        self.credential = credential
        self.port = port
        self.providerBundleID = providerBundleID
        self.expiresAt = expiresAt
    }

    public func code() throws -> String {
        "talk-pair-v1:" + (try JSONEncoder().encode(self)).base64EncodedString()
    }

    public static func parse(_ code: String, now: Date = Date()) throws -> Self {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "talk-pair-v1:"
        guard text.utf8.count <= 4096, text.hasPrefix(prefix),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.port > 0,
              value.providerBundleID.isEmpty == false,
              value.providerBundleID.utf8.count <= 255 else { throw TalkError.invalidInvitation }
        try value.credential.validate()
        guard value.expiresAt > now else { throw TalkError.invitationExpired }
        return value
    }
}
