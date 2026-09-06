import Foundation
import TalkContractSchema

public struct ProviderManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let contractID: String
    public let contractVersion: String
    public let actions: [String]

    public static func parse(_ data: Data) throws -> Self {
        let schema = try ContractSchema.load(data)
        return Self(schemaVersion: schema.schemaVersion, contractID: schema.contractID,
                    contractVersion: schema.contractVersion, actions: schema.actions.map(\.id))
    }
}
