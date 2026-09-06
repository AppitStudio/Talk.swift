import Foundation
import Testing
import TalkContractSchema
import StudioContract

struct ContractSchemaTests {
    private var fixture: Data {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try Data(contentsOf: root.appending(path: "Examples/Shared/StudioContract/Contract.talk.json"))
        }
    }

    @Test func canonicalExportAndGeneratedDeclarationsAgree() throws {
        let schema = try ContractSchema.load(fixture)
        #expect(try ContractSchema.load(schema.exported()) == schema)
        #expect(try schema.exported() == ContractSchema.load(schema.exported()).exported())
        #expect(schema.contractID == StudioAPI.contractID)
        #expect(Dictionary(uniqueKeysWithValues: schema.actions.map { ($0.id, $0.scope) }) == StudioAPI.actions)
        #expect(schema.events.map(\.id) == [StudioAPI.changed])
        let generated = try SwiftClientGenerator.generate(schema)
        #expect(generated.contains("public func `selectScene`(_ input: `SelectScene`"))
        #expect(generated.contains("public enum `SceneKind`"))
    }

    @Test(arguments: ["Double", "Date", "Data", "[String:String]", "(String,Bool)", "any Codable", "String??", "Missing", "Int"])
    func rejectsUnsupportedDTOs(type: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        object["types"] = [["name": "Bad", "kind": "struct", "fields": [["name": "value", "type": type]]]]
        do {
            _ = try ContractSchema.load(JSONSerialization.data(withJSONObject: object))
            Issue.record("Unsupported type accepted")
        } catch let error as ContractDiagnostic { #expect(error.message.contains("Bad.value")) }
    }

    @Test(arguments: ["computedProperties", "generics", "customCodable"])
    func unknownDeclarationsAreDiagnosed(key: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        object[key] = true
        do { _ = try ContractSchema.load(JSONSerialization.data(withJSONObject: object)); Issue.record("Unsupported declaration accepted") }
        catch let error as ContractDiagnostic { #expect(error.message.contains(key)) }
    }

    @Test func rejectsCyclesDuplicateIDsAndFutureSchema() throws {
        var object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        object["schemaVersion"] = 2
        #expect(throws: ContractDiagnostic("schemaVersion: only version 1 is supported")) {
            try ContractSchema.load(JSONSerialization.data(withJSONObject: object))
        }
        object["schemaVersion"] = 1
        var types = try #require(object["types"] as? [[String: Any]])
        types.append(["name": "Recursive", "kind": "struct", "fields": [["name": "children", "type": "[Recursive]"]]])
        object["types"] = types
        #expect(throws: ContractDiagnostic("Recursive: recursive DTOs are unsupported")) {
            try ContractSchema.load(JSONSerialization.data(withJSONObject: object))
        }
        object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var actions = try #require(object["actions"] as? [[String: Any]])
        actions.append(actions[0]); object["actions"] = actions
        #expect(throws: ContractDiagnostic("wire IDs: duplicate declaration")) {
            try ContractSchema.load(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func nestedDTOAndEnumWireRoundTrip() throws {
        let snapshot = StudioSnapshot(sessionID: UUID(), revision: 7, selectedSceneID: "focus")
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(StudioSnapshot.self, from: data) == snapshot)
        #expect(snapshot.scenes.first?.kind == .focus)
        #expect(try JSONEncoder().encode(SelectScene(id: "focus")) == Data(#"{"id":"focus"}"#.utf8))
    }
}
