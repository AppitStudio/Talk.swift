import Foundation
import Testing
import CompatibilityOld
import CompatibilityNew
@testable import Talk

struct ContractCompatibilityTests {
    @Test(.timeLimit(.minutes(1)))
    func actualGeneratedOldClientNewProviderAndNewClientOldProvider() async throws {
        let old = OldFixtureAPI.schema, new = NewFixtureAPI.schema
        for newProvider in [true, false] {
            let schema = newProvider ? new : old
            let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: ["test.read", "test.write"])
            let calls = CompatibilityCounter()
            let server = TalkServer(record: record, actions: Dictionary(uniqueKeysWithValues: schema.actions.map { ($0.id, $0.scope) }), contract: schema) { action, payload in
                await calls.increment()
                if action == "test.write" {
                    guard case .object(let object) = payload, let value = object["value"] else { throw TalkError.invalidMessage }
                    return .object(["value": value])
                }
                return .object(["value": .string("synthetic"), "note": .string("extra output ignored by old client")])
            }
            let transport = try TalkClient(port: try await server.start(), credential: record.credential)
            do {
                if newProvider {
                    let client = OldFixtureClient(transport: transport)
                    try await client.connect()
                    #expect(try await client.read().value == "synthetic")
                    #expect(try await client.write(CompatibilityOld.Options(value: "old")).value == "old")
                } else {
                    let client = NewFixtureClient(transport: transport, requiredActions: Set(old.actions.map(\.id)), requiredEvents: [])
                    try await client.connect()
                    #expect(try await client.read().value == "synthetic")
                    #expect(try await client.write(CompatibilityNew.Options(value: "new", note: nil)).value == "new")
                    await #expect(throws: TalkError.unsupportedVersion) { try await client.extra() }
                }
                #expect(await calls.value == 2)
            } catch { await transport.close(); await server.stop(); throw error }
            await transport.close(); await server.stop()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unsupportedHandshakeAndMalformedRuntimeValuesNeverDispatch() async throws {
        let old = OldFixtureAPI.schema
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: ["test.read", "test.write"])
        let calls = CompatibilityCounter()
        let server = TalkServer(record: record, actions: OldFixtureAPI.actions, contract: old) { _, _ in
            await calls.increment(); return .object(["value": .string("safe")])
        }
        let port = try await server.start()
        let unsupported = NewFixtureClient(transport: try TalkClient(port: port, credential: record.credential))
        await #expect(throws: ContractDiagnostic.self) { try await unsupported.connect() }
        #expect(await calls.value == 0)
        let raw = try TalkClient(port: port, credential: record.credential)
        try await raw.connect()
        await #expect(throws: TalkError.unsupportedVersion) { try await raw.request(action: "test.write", payload: .object(["value": .string("unnegotiated")])) }
        try await raw.prepare(OldFixtureAPI.requirement)
        await #expect(throws: TalkError.invalidMessage) { try await raw.request(action: "test.write", payload: .object(["value": .integer(1)])) }
        #expect(await calls.value == 0)
        await raw.close(); await unsupported.transport.close(); await server.stop()
    }

    @Test func directionalDiagnosticsCoverFieldsEnumsScopesAndVersions() throws {
        let old = OldFixtureAPI.schema, new = NewFixtureAPI.schema
        #expect(try ContractCompatibility.diagnostics(client: old, provider: new).isEmpty)
        #expect(try ContractCompatibility.diagnostics(client: new, provider: old).contains { $0.message.contains("test.extra") })
        #expect(try ContractCompatibility.diagnostics(client: new, provider: old, requiredActions: Set(old.actions.map(\.id)), minimumMinor: 1).contains { $0.message.contains("minor") })
        func changed(_ edit: (inout [String: Any]) -> Void) throws -> ContractSchema {
            var object = try #require(JSONSerialization.jsonObject(with: old.exported()) as? [String: Any])
            edit(&object)
            return try ContractSchema.load(JSONSerialization.data(withJSONObject: object))
        }
        let required = try changed { object in
            var types = object["types"] as! [[String: Any]]
            types[0]["fields"] = [["name": "value", "type": "String"], ["name": "required", "type": "Bool"]]
            object["types"] = types
        }
        #expect(try ContractCompatibility.diagnostics(client: old, provider: required).contains { $0.message.contains("input.required") })
        let optionalOutput = try changed { object in
            var types = object["types"] as! [[String: Any]]
            types[1]["fields"] = [["name": "value", "type": "String?"]]; object["types"] = types
        }
        #expect(try ContractCompatibility.diagnostics(client: old, provider: optionalOutput).contains { $0.message.contains("output.value") })
        let scope = try changed { object in
            var actions = object["actions"] as! [[String: Any]]
            actions[0]["scope"] = "test.other"; object["actions"] = actions
        }
        #expect(try ContractCompatibility.diagnostics(client: old, provider: scope).contains { $0.message.contains("scope") })
        let major = try changed { $0["contractVersion"] = "2.0.0" }
        #expect(try ContractCompatibility.diagnostics(client: old, provider: major).contains { $0.message.contains("major") })
        let enumOld = try changed { object in
            var types = object["types"] as! [[String: Any]]
            types.append(["name":"Choice", "kind":"enum", "cases":["a"]])
            types[1]["fields"] = [["name":"value", "type":"Choice"]]; object["types"] = types
        }
        var enumObject = try #require(JSONSerialization.jsonObject(with: enumOld.exported()) as? [String: Any])
        var types = try #require(enumObject["types"] as? [[String: Any]])
        types[2]["cases"] = ["a", "b"]; enumObject["types"] = types
        let enumNew = try ContractSchema.load(JSONSerialization.data(withJSONObject: enumObject))
        #expect(try ContractCompatibility.diagnostics(client: enumOld, provider: enumNew).contains { $0.message.contains("enum cases: b") })
        #expect(try ContractCompatibility.diagnostics(client: enumNew, provider: enumOld).isEmpty)
    }
}

private actor CompatibilityCounter {
    var value = 0
    func increment() { value += 1 }
}
