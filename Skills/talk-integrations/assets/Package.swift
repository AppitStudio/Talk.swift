// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ExampleIntegration",
    platforms: [.macOS("12.4")],
    products: [
        .library(name: "IntegrationContract", targets: ["IntegrationContract"]),
        .library(name: "IntegrationWiring", targets: ["IntegrationWiring"])
    ],
    dependencies: [.package(name: "TalkSDK", path: "../Talk.swift")],
    targets: [
        .target(name: "IntegrationContract",
                dependencies: [.product(name: "Talk", package: "TalkSDK")],
                exclude: ["Contract.talk.json"],
                plugins: [.plugin(name: "TalkClientPlugin", package: "TalkSDK")]),
        .target(name: "IntegrationWiring",
                dependencies: ["IntegrationContract", .product(name: "Talk", package: "TalkSDK")])
    ],
    swiftLanguageModes: [.v6]
)
