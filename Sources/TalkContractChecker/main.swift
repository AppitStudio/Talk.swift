import Foundation
import TalkContractSchema

// Separate semantic checker: neither export nor generation is a compatibility verdict.
do {
    guard CommandLine.arguments.count == 3 else { throw ContractDiagnostic("usage: TalkContractChecker client.talk.json provider.talk.json") }
    let client = try ContractSchema.load(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let provider = try ContractSchema.load(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let issues = try ContractCompatibility.diagnostics(client: client, provider: provider)
    guard issues.isEmpty else { throw ContractDiagnostic(issues.map(\.message).joined(separator: "\n")) }
    print("Compatible: provider supports all declared client capabilities")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
