import Foundation
import TalkContractSchema

// Export only: no provider initialization, app launch, or Swift source parsing.
do {
    guard CommandLine.arguments.count == 3 else { throw ContractDiagnostic("usage: TalkSchemaExporter input.talk.json output.talk.json") }
    let contract = try ContractSchema.load(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    try contract.exported().write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
