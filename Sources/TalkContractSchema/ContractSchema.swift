import Foundation

public struct ContractDiagnostic: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Data-only, versioned contract. Export and generation never launch provider code.
public struct ContractSchema: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let contractID: String
    public let contractVersion: String
    public let name: String
    public let types: [DTO]
    public let actions: [Action]
    public let events: [Event]

    public struct DTO: Codable, Sendable, Equatable {
        public let name: String
        public let kind: String
        public let fields: [Field]?
        public let cases: [String]?
    }
    public struct Field: Codable, Sendable, Equatable {
        public let name: String
        public let type: String
    }
    public struct Action: Codable, Sendable, Equatable {
        public let id: String
        public let symbol: String
        public let method: String
        public let scope: String
        public let input: String
        public let output: String
        public let mutation: Bool
    }
    public struct Event: Codable, Sendable, Equatable {
        public let id: String
        public let symbol: String
        public let payload: String
    }

    public static func load(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw ContractDiagnostic("contract: exceeds 65536 bytes") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw ContractDiagnostic("contract: invalid JSON") }
        try checkKeys(object, required: ["schemaVersion", "contractID", "contractVersion", "name", "types", "actions", "events"], optional: [], path: "contract")
        if let root = object as? [String: Any] {
            for (index, type) in (root["types"] as? [Any] ?? []).enumerated() {
                try checkKeys(type, required: ["name", "kind"], optional: ["fields", "cases"], path: "types[\(index)]")
                if let type = type as? [String: Any] {
                    for (fieldIndex, field) in (type["fields"] as? [Any] ?? []).enumerated() {
                        try checkKeys(field, required: ["name", "type"], optional: [], path: "types[\(index)].fields[\(fieldIndex)]")
                    }
                }
            }
            for (index, action) in (root["actions"] as? [Any] ?? []).enumerated() {
                try checkKeys(action, required: ["id", "symbol", "method", "scope", "input", "output", "mutation"], optional: [], path: "actions[\(index)]")
            }
            for (index, event) in (root["events"] as? [Any] ?? []).enumerated() {
                try checkKeys(event, required: ["id", "symbol", "payload"], optional: [], path: "events[\(index)]")
            }
        }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ContractDiagnostic("contract: missing or incorrectly typed declaration (\(error))") }
        try result.validate()
        return result
    }

    public func exported() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self) + Data([10])
        // Pretty-printing can expand an accepted compact input beyond the
        // manifest reader's limit. Never emit an artifact we cannot reload.
        guard data.count <= 65_536 else { throw ContractDiagnostic("contract: canonical export exceeds 65536 bytes") }
        return data
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ContractDiagnostic("schemaVersion: only version 1 is supported") }
        guard contractVersion.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else {
            throw ContractDiagnostic("contractVersion: expected major.minor.patch without prerelease suffix")
        }
        try identifier(name, path: "name")
        try wireID(contractID, path: "contractID")
        guard types.count <= 128, !actions.isEmpty, actions.count <= 128, events.count <= 128 else { throw ContractDiagnostic("contract: declaration limit exceeded or no actions") }
        try unique(types.map(\.name), path: "types")
        try unique(actions.map(\.id) + events.map(\.id), path: "wire IDs")
        try unique(actions.map(\.symbol) + events.map(\.symbol), path: "symbols")
        try unique(actions.map(\.method), path: "methods")
        let names = Set(types.map(\.name))
        let reserved: Set<String> = ["String", "Bool", "Int", "Int64", "UUID", "Void", "Optional", "Array", "Codable", "Sendable", "Equatable", "CaseIterable", "TalkClient", "TalkMessage", "TalkError", "JSONValue", "Foundation", "Talk", "Event", name + "API", name + "Client"]
        for type in types {
            try identifier(type.name, path: "types.\(type.name)")
            guard !reserved.contains(type.name) else { throw ContractDiagnostic("types.\(type.name): reserved Swift/runtime type") }
            switch type.kind {
            case "struct":
                guard let fields = type.fields, type.cases == nil, fields.count <= 64 else { throw ContractDiagnostic("\(type.name): struct needs at most 64 fields and no cases") }
                try unique(fields.map(\.name), path: type.name)
                for field in fields {
                    try identifier(field.name, path: "\(type.name).\(field.name)")
                    guard !["encode", "CodingKeys"].contains(field.name) else { throw ContractDiagnostic("\(type.name).\(field.name): reserved Codable member") }
                    _ = try checkedType(field.type, names: names, path: "\(type.name).\(field.name)")
                }
            case "enum":
                guard let cases = type.cases, !cases.isEmpty, cases.count <= 64, type.fields == nil else { throw ContractDiagnostic("\(type.name): enum needs 1...64 string cases and no fields") }
                try unique(cases, path: type.name)
                for value in cases {
                    try identifier(value, path: type.name)
                    guard !["rawValue", "allCases", "encode"].contains(value) else { throw ContractDiagnostic("\(type.name).\(value): reserved enum member") }
                }
            default: throw ContractDiagnostic("\(type.name): unsupported DTO kind; use struct or string enum")
            }
        }
        for action in actions {
            try wireID(action.id, path: "action.id")
            guard !action.id.hasPrefix("talk.") else { throw ContractDiagnostic("action.id: talk namespace is reserved") }
            try wireID(action.scope, path: "\(action.id).scope")
            try identifier(action.symbol, path: "\(action.id).symbol")
            try identifier(action.method, path: "\(action.id).method")
            guard !["transport", "decodeEvent", "Event", "connect"].contains(action.method), !["scopes", "actions", "contractID", "contractVersion", "schema", "requirement"].contains(action.symbol) else { throw ContractDiagnostic("\(action.id): reserved generated member") }
            if action.input != "Void" { _ = try checkedType(action.input, names: names, path: "\(action.id).input") }
            if action.output != "Void" { _ = try checkedType(action.output, names: names, path: "\(action.id).output") }
        }
        for event in events {
            try wireID(event.id, path: "event.id")
            try identifier(event.symbol, path: "\(event.id).symbol")
            guard !["scopes", "actions", "contractID", "contractVersion", "schema", "requirement"].contains(event.symbol) else { throw ContractDiagnostic("\(event.id): reserved generated member") }
            _ = try checkedType(event.payload, names: names, path: "\(event.id).payload")
        }
        // Reject recursive value types, including cycles through arrays/optionals.
        let graph = try Dictionary(uniqueKeysWithValues: types.map { type in
            (type.name, try (type.fields ?? []).compactMap { try checkedType($0.type, names: names, path: type.name) })
        })
        var completed: Set<String> = []
        func visit(_ node: String, stack: Set<String>) throws {
            guard !stack.contains(node) else { throw ContractDiagnostic("\(node): recursive DTOs are unsupported") }
            if completed.contains(node) { return }
            guard stack.count < 32 else { throw ContractDiagnostic("\(node): DTO nesting exceeds 32") }
            for next in graph[node] ?? [] { try visit(next, stack: stack.union([node])) }
            completed.insert(node)
        }
        for name in names { try visit(name, stack: []) }
    }

    private static func checkKeys(_ object: Any, required: Set<String>, optional: Set<String>, path: String) throws {
        guard let object = object as? [String: Any] else { throw ContractDiagnostic("\(path): expected object") }
        let keys = Set(object.keys)
        guard required.isSubset(of: keys) else { throw ContractDiagnostic("\(path): missing \(required.subtracting(keys).sorted().joined(separator: ", "))") }
        guard keys.isSubset(of: required.union(optional)) else { throw ContractDiagnostic("\(path): unsupported declarations: \(keys.subtracting(required.union(optional)).sorted().joined(separator: ", "))") }
    }

    private func unique(_ values: [String], path: String) throws {
        guard Set(values).count == values.count else { throw ContractDiagnostic("\(path): duplicate declaration") }
    }
    private func identifier(_ value: String, path: String) throws {
        guard value.utf8.count <= 64, value.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              !["self", "Self", "Type", "Protocol", "init", "deinit"].contains(value) else { throw ContractDiagnostic("\(path): unsupported Swift identifier") }
    }
    private func wireID(_ value: String, path: String) throws {
        guard value.utf8.count <= 128, value.range(of: #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$"#, options: .regularExpression) != nil else { throw ContractDiagnostic("\(path): expected stable dotted lowercase ID") }
    }
    private func checkedType(_ value: String, names: Set<String>, path: String, depth: Int = 0) throws -> String? {
        guard depth <= 8, value.utf8.count <= 128 else { throw ContractDiagnostic("\(path): type nesting exceeds limit") }
        if value.hasSuffix("?") {
            let inner = String(value.dropLast())
            guard !inner.hasSuffix("?") else { throw ContractDiagnostic("\(path): nested optionals unsupported") }
            return try checkedType(inner, names: names, path: path, depth: depth + 1)
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            return try checkedType(String(value.dropFirst().dropLast()), names: names, path: path, depth: depth + 1)
        }
        if ["String", "Bool", "Int64", "UUID"].contains(value) { return nil }
        guard names.contains(value) else { throw ContractDiagnostic("\(path): unsupported DTO type '\(value)'; use String, Bool, Int64, UUID, declared DTO, array, or optional") }
        return value
    }
}
