import Foundation
@_exported import TalkContractSchema

public struct ContractRequirement: Codable, Sendable, Equatable {
    public let schema: ContractSchema
    public let actions: Set<String>
    public let events: Set<String>
    public let minimumMinor: Int
    public init(schema: ContractSchema, actions: Set<String>? = nil, events: Set<String>? = nil, minimumMinor: Int = 0) {
        self.schema = schema
        self.actions = actions ?? Set(schema.actions.map(\.id))
        self.events = events ?? Set(schema.events.map(\.id))
        self.minimumMinor = minimumMinor
    }
    public func diagnostics(provider: ContractSchema) throws -> [ContractDiagnostic] {
        guard actions.count <= 128, events.count <= 128 else { throw TalkError.invalidMessage }
        return try ContractCompatibility.diagnostics(client: schema, provider: provider,
            requiredActions: actions, requiredEvents: events, minimumMinor: minimumMinor)
    }
}

/// Runtime value validation is independent of schema and compatibility validation.
public enum ContractValueValidator {
    public static func validate(_ value: JSONValue, type: String, schema: ContractSchema) throws {
        if type.hasSuffix("?") {
            if value == .null { return }
            return try validate(value, type: String(type.dropLast()), schema: schema)
        }
        if type.hasPrefix("[") {
            guard case .array(let values) = value else { throw TalkError.invalidMessage }
            for element in values { try validate(element, type: String(type.dropFirst().dropLast()), schema: schema) }
            return
        }
        switch (type, value) {
        case ("Void", .null), ("String", .string), ("Bool", .bool), ("Int64", .integer): return
        case ("UUID", .string(let string)) where UUID(uuidString: string) != nil: return
        default: break
        }
        guard let dto = schema.types.first(where: { $0.name == type }) else { throw TalkError.invalidMessage }
        if dto.kind == "enum" {
            guard case .string(let raw) = value, dto.cases?.contains(raw) == true else { throw TalkError.invalidMessage }
        } else {
            guard case .object(let fields) = value else { throw TalkError.invalidMessage }
            for field in dto.fields ?? [] {
                try validate(fields[field.name] ?? .null, type: field.type, schema: schema)
            }
        }
    }
}
