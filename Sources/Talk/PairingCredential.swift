import Foundation
import Security

/// Possession is the principal in this spike. It is not an OS-verified app identity.
public struct PairingCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let secret: Data
    public var description: String { "PairingCredential(<redacted>)" }
    public var debugDescription: String { description }

    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TalkError.credentialStorage
        }
        id = UUID()
        secret = Data(bytes)
    }

    public func validate() throws {
        guard secret.count == 32 else { throw TalkError.invalidInvitation }
    }
}
