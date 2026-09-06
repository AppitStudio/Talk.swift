import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Compiled alongside actual SDK storage sources. Synthetic services only.
// No credential, entitlement dictionary, certificate or personal identifier output.
@main
struct ProductionCredentials {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, args[1].hasPrefix("dev.talk.synthetic.production."),
              (args[2] == "adhoc" || args[2].range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil) else { exit(2) }
        let operation = args[0], service = args[1], certificate = args[2], bundle = args[3], group = args[4]
        var verified = false
        do {
            try verify(certificate: certificate, bundle: bundle)
            verified = true
            let store = CredentialStore(service: service)
            switch operation {
            case "save", "update":
                let scopes: Set<String> = operation == "save" ? ["synthetic.read"] : ["synthetic.read", "synthetic.write"]
                let record = try PairingRecord(credential: PairingCredential(), providerBundleID: "dev.talk.synthetic.peer", scopes: scopes, label: service)
                try await store.saveRecords([record])
                report(["result": "saved", "continuityProof": proof(record)])
            case "load", "load-updated":
                let records = try await store.loadRecords()
                let scopes: Set<String> = operation == "load" ? ["synthetic.read"] : ["synthetic.read", "synthetic.write"]
                guard records.count == 1, records[0].label == service, records[0].scopes == scopes else {
                    report(["result": records.isEmpty ? "empty" : "invalidRecord"]); return
                }
                try records[0].validate()
                report(["result": "loaded", "continuityProof": proof(records[0])])
            case "delete":
                try await store.delete()
                report(["result": "deleted"])
            case "raw-attributes", "raw-read", "raw-read-default", "raw-update", "raw-delete":
                // Do not disable process interaction in the attacker. For the
                // explicit group read, also omit per-query UI suppression.
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: "paired-integration",
                    kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
                if operation != "raw-read-default" { query[kSecAttrAccessGroup as String] = group }
                var output: CFTypeRef?
                let status: OSStatus
                if operation == "raw-attributes" {
                    query[kSecReturnAttributes as String] = true
                    query[kSecMatchLimit as String] = kSecMatchLimitOne
                    status = SecItemCopyMatching(query as CFDictionary, &output)
                    let attributes = output as? [String: Any]
                    let protected = attributes?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
                        && attributes?[kSecAttrSynchronizable as String] as? Bool == false
                        && attributes?[kSecAttrAccessGroup as String] as? String == group
                        && attributes?[kSecValueData as String] == nil
                    report(["result": "attributes", "osStatus": Int(status), "itemProtectionVerified": protected])
                    return
                } else if operation.hasPrefix("raw-read") {
                    query[kSecReturnData as String] = true
                    query[kSecMatchLimit as String] = kSecMatchLimitOne
                    status = SecItemCopyMatching(query as CFDictionary, &output)
                } else if operation == "raw-update" {
                    status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("synthetic-tamper".utf8)] as CFDictionary)
                } else { status = SecItemDelete(query as CFDictionary) }
                // Any data disclosure fails, regardless of whether it decodes.
                report(["result": "raw", "osStatus": Int(status), "dataReturned": output != nil])
            default: exit(2)
            }
        } catch {
            report(["result": (error as? TalkError)?.rawValue ?? "failed"], verified: verified)
            exit(1)
        }
    }

    // A per-run possession proof crosses only the anonymous parent pipe. The
    // harness compares it in memory and strips it before writing any evidence.
    private static func proof(_ record: PairingRecord) -> String {
        let message = Data(record.credential.id.uuidString.utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: record.credential.secret))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func verify(certificate: String, bundle: String) throws {
        guard bundle.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw TalkError.credentialConfiguration
        }
        var code: SecCode?, requirement: SecRequirement?
        let text = (certificate == "adhoc" ? "" : "certificate leaf = H\"" + certificate + "\" and ") + "identifier \"" + bundle + "\""
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw TalkError.credentialConfiguration }
    }

    private static func report(_ fields: [String: Any], verified: Bool = true) {
        var value = fields
        value["signerVerified"] = verified
        #if TALK_PROBE_UPDATE
        value["build"] = 2
        #else
        value["build"] = 1
        #endif
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
