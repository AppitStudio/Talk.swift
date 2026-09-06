import Foundation
import TalkContractSchema

do {
    guard CommandLine.arguments.count == 3 else { throw ContractDiagnostic("usage: TalkClientGenerator input.talk.json output.swift") }
    let contract = try ContractSchema.load(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    try Data(SwiftClientGenerator.generate(contract).utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
