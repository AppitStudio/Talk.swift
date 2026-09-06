import Foundation
import Testing
import TalkContractSchema

struct ExportBoundaryTests {
    @Test(arguments: [40, 80])
    func canonicalExportFitsTheManifestReadLimit(typeCount: Int) throws {
        let types: [[String: Any]] = (0..<typeCount).map { index in
            ["name": "Box\(index)", "kind": "struct", "fields": (0..<10).map { field in
                ["name": "value\(field)", "type": "String"]
            }]
        }
        let fixture: [String: Any] = [
            "schemaVersion": 1, "contractID": "dev.talk.synthetic.boundary", "contractVersion": "1.0.0", "name": "Boundary",
            "types": types, "events": [], "actions": [["id": "boundary.read", "symbol": "read", "method": "read",
                "scope": "boundary.read", "input": "Void", "output": "Box0", "mutation": false]]
        ]
        let compact = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        try #require(compact.count < 65_536)
        let schema = try ContractSchema.load(compact)
        if typeCount == 80 {
            #expect(throws: ContractDiagnostic("contract: canonical export exceeds 65536 bytes")) { try schema.exported() }
        } else {
            let exported = try schema.exported()
            #expect(exported.count <= 65_536)
            #expect(try ContractSchema.load(exported) == schema)
        }
    }
}
