import Foundation

public enum TalkError: String, Error, Codable, Sendable, LocalizedError {
    case ambiguousProvider
    case credentialLocked, credentialOperationPending, credentialConfiguration
    case invalidFrame, invalidMessage, invalidInvitation, invitationExpired
    case disconnected, timedOut, busy, permissionDenied, pairingRequired
    case unsupportedVersion, unknownAction, eventOverflow, unavailable, credentialStorage

    public var errorDescription: String? {
        switch self {
        case .ambiguousProvider: "Multiple provider installations were found. Keep one registered installation before reconnecting."
        case .credentialLocked: "Keychain access is locked or requires user recovery in Keychain Access."
        case .credentialConfiguration: "The app's signing, entitlements or protected storage configuration is invalid."
        case .credentialOperationPending: "A Keychain operation is unresolved. Do not repeat pairing or assume revocation completed; reload after it finishes."
        case .invalidFrame: "The peer sent an invalid or oversized frame."
        case .invalidMessage: "The peer sent an invalid message."
        case .invalidInvitation: "This pairing code is invalid."
        case .invitationExpired: "This pairing code expired. Create a new one in the provider."
        case .disconnected: "The connection closed. A pending action may already have completed."
        case .timedOut: "The operation timed out. A pending action may already have completed."
        case .busy: "The connection has reached its work limit."
        case .permissionDenied: "This integration does not have permission."
        case .pairingRequired: "Pair the apps before connecting."
        case .unsupportedVersion: "The peer uses an unsupported Talk protocol version."
        case .unknownAction: "The provider does not support this action."
        case .eventOverflow: "Events were missed. Reconnect to obtain a fresh snapshot."
        case .unavailable: "The provider is unavailable."
        case .credentialStorage: "Credentials could not be accessed securely in Keychain."
        }
    }
}
