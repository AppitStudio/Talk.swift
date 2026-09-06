import Foundation
import PackagePlugin

@main
struct TalkClientPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let input = target.directoryURL.appending(path: "Contract.talk.json")
        let output = context.pluginWorkDirectoryURL.appending(path: "TalkContract.generated.swift")
        return [.buildCommand(displayName: "Validate and generate \(target.name) Talk contract",
                              executable: try context.tool(named: "TalkClientGenerator").url,
                              arguments: [input.path, output.path], inputFiles: [input], outputFiles: [output])]
    }
}
