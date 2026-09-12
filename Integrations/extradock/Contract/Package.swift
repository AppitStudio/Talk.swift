// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ExtraDockTalkContract",
    platforms: [.macOS("12.4")],
    products: [.library(name: "ExtraDockTalkContract", targets: ["ExtraDockTalkContract"])],
    dependencies: [.package(url: "https://github.com/AppitStudio/Talk.swift.git", exact: "0.1.0-beta.2")],
    targets: [.target(name: "ExtraDockTalkContract",
        dependencies: [.product(name: "Talk", package: "talk.swift")],
        exclude: ["Contract.talk.json"],
        plugins: [.plugin(name: "TalkClientPlugin", package: "talk.swift")])],
    swiftLanguageModes: [.v6]
)
