// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Talk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Talk", targets: ["Talk"]),
        .library(name: "TalkContractSchema", targets: ["TalkContractSchema"]),
        .executable(name: "TalkContractChecker", targets: ["TalkContractChecker"]),
        .executable(name: "TalkSchemaExporter", targets: ["TalkSchemaExporter"]),
        .executable(name: "TalkClientGenerator", targets: ["TalkClientGenerator"]),
        .plugin(name: "TalkClientPlugin", targets: ["TalkClientPlugin"]),
        .library(name: "StudioContract", targets: ["StudioContract"]),
        .executable(name: "TalkStudio", targets: ["TalkStudio"]),
        .executable(name: "TalkAutomator", targets: ["TalkAutomator"])
    ],
    targets: [
        .target(name: "Talk", dependencies: ["TalkContractSchema"]),
        .target(name: "TalkContractSchema"),
        .executableTarget(name: "TalkLoadProbe", dependencies: ["Talk", "StudioContract"]),
        .executableTarget(name: "TalkReadinessProbe", dependencies: ["Talk"]),
        .executableTarget(name: "TalkContractChecker", dependencies: ["TalkContractSchema"]),
        .executableTarget(name: "TalkSchemaExporter", dependencies: ["TalkContractSchema"]),
        .executableTarget(name: "TalkClientGenerator", dependencies: ["TalkContractSchema"]),
        .plugin(name: "TalkClientPlugin", capability: .buildTool(), dependencies: ["TalkClientGenerator"]),
        .target(name: "StudioContract", dependencies: ["Talk"], path: "Examples/Shared/StudioContract", exclude: ["Contract.talk.json"], plugins: ["TalkClientPlugin"]),
        .executableTarget(name: "TalkStudio", dependencies: ["Talk", "StudioContract"], path: "Examples/Studio/Sources"),
        .executableTarget(name: "TalkAutomator", dependencies: ["Talk", "StudioContract"], path: "Examples/Automator/Sources"),
        .target(name: "CompatibilityOld", dependencies: ["Talk"], path: "Tests/Fixtures/CompatibilityOld", exclude: ["Contract.talk.json"], plugins: ["TalkClientPlugin"]),
        .target(name: "CompatibilityNew", dependencies: ["Talk"], path: "Tests/Fixtures/CompatibilityNew", exclude: ["Contract.talk.json"], plugins: ["TalkClientPlugin"]),
        .testTarget(name: "TalkTests", dependencies: ["Talk", "StudioContract", "CompatibilityOld", "CompatibilityNew"]),
        .testTarget(name: "TalkContractSchemaTests", dependencies: ["TalkContractSchema", "StudioContract"])
    ],
    swiftLanguageModes: [.v6]
)
