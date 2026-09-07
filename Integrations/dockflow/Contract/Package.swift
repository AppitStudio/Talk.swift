// swift-tools-version: 6.2
import PackageDescription

// Copy this whole Contract directory into your app's LocalPackages directory.
// The public JSON is the source of truth; the plugin generates the typed API.
let package = Package(
    name: "DockFlowTalkContract",
    platforms: [.macOS("12.4")],
    products: [.library(name: "DockFlowTalkContract", targets: ["DockFlowTalkContract"])],
    dependencies: [
        .package(url: "https://github.com/AppitStudio/Talk.swift.git", exact: "0.1.0-beta.2")
    ],
    targets: [
        .target(name: "DockFlowTalkContract",
                dependencies: [.product(name: "Talk", package: "talk.swift")],
                exclude: ["Contract.talk.json"],
                plugins: [.plugin(name: "TalkClientPlugin", package: "talk.swift")])
    ],
    swiftLanguageModes: [.v6]
)
