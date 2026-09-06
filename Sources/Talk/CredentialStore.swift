import Foundation
import LocalAuthentication
import Security

/// Nonsynchronizing data-protection Keychain storage for a provisioned macOS app.
/// Uses only the host's signed application-identifier access group, explicitly
/// selected on every operation. It never queries or migrates legacy items and
/// never changes process-wide Keychain interaction policy.
///
/// The host must be Apple signed and provisioned for its application identifier.
/// Security enforces the entitlement; missing configuration fails closed.
public struct CredentialStore: Sendable, IntegrationPersistence {
    private let service: String

    public init(service: String) { self.service = service }

    public func loadRecords() async throws -> [PairingRecord] {
        let identity = try identity()
        let data = try await KeychainOperations.shared.perform(key: operationKey(identity)) {
            var query = Self.query(service: service, applicationIdentifier: identity)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            try Self.check(status)
            guard let data = result as? Data, data.count <= 131_072 else { throw TalkError.credentialStorage }
            return data
        }
        guard let data else { return [] }
        return try IntegrationArchive.decode(data)
    }

    public func saveRecords(_ records: [PairingRecord]) async throws {
        let identity = try identity()
        let data = try IntegrationArchive.encode(records)
        _ = try await KeychainOperations.shared.perform(key: operationKey(identity)) {
            let query = Self.query(service: service, applicationIdentifier: identity)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var addition = query
                addition[kSecValueData as String] = data
                addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                try Self.check(SecItemAdd(addition as CFDictionary, nil))
            } else { try Self.check(status) }
            return nil
        }
    }

    public func delete() async throws {
        let identity = try identity()
        _ = try await KeychainOperations.shared.perform(key: operationKey(identity)) {
            let status = SecItemDelete(Self.query(service: service, applicationIdentifier: identity) as CFDictionary)
            if status != errSecItemNotFound { try Self.check(status) }
            return nil
        }
    }

    private func identity() throws -> String {
        guard !service.isEmpty, service.utf8.count <= 1024, !service.contains("\0") else {
            throw TalkError.credentialConfiguration
        }
        var code: SecCode?, requirement: SecRequirement?
        // Check the actual running code, not a peer claim or bundle metadata.
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw TalkError.credentialConfiguration
        }
        var staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            throw TalkError.credentialConfiguration
        }
        return try Self.applicationIdentifier(codeIdentifier: identifier, entitlements: entitlements)
    }

    // App ID prefixes may differ from Team IDs for older developer accounts.
    // Do not synthesize an access group from a bundle ID or use the first shared
    // group. Security remains responsible for validating profile authorization.
    static func applicationIdentifier(codeIdentifier: String, entitlements: [String: Any]) throws -> String {
        guard !codeIdentifier.isEmpty,
              let identifier = entitlements["com.apple.application-identifier"] as? String,
              identifier.utf8.count <= 1024, !identifier.contains("*"), !identifier.contains("\0"),
              identifier.hasSuffix("." + codeIdentifier), identifier.count > codeIdentifier.count + 1 else {
            throw TalkError.credentialConfiguration
        }
        return identifier
    }

    static func query(service: String, applicationIdentifier: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "paired-integration",
                kSecAttrAccessGroup as String: applicationIdentifier,
                kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: context]
    }

    private func operationKey(_ identifier: String) -> String {
        "data-protection:" + String(identifier.utf8.count) + ":" + identifier + ":" + service
    }

    static func check(_ status: OSStatus) throws {
        if status == errSecMissingEntitlement { throw TalkError.credentialConfiguration }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw TalkError.credentialLocked }
        guard status == errSecSuccess else { throw TalkError.credentialStorage }
    }
}
