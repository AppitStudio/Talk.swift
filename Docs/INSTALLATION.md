# Install Talk.swift

Talk is a macOS Swift package. Both apps need the SDK; a provider exposes a contract, and a consumer uses a generated client for that contract. One app can do both.

> **Beta — use with caution.** More testing and validation are required. Start with synthetic or noncritical data and test the complete flow in your actual signed apps. Installing or successfully compiling the package does not establish production readiness.

## Requirements

| Requirement | Current scope |
| --- | --- |
| Swift | 6.2 or later; Swift 6 language mode |
| Toolchain tested | Xcode 26.2 / Swift 6.2.3 |
| Declared deployment target | macOS 12.4 or later |
| Native environment tested | macOS 15.7.9, Apple silicon |
| Persistent pairing | Apple-signed, correctly provisioned macOS apps with app-specific Keychain access |
| Dependencies | Apple frameworks; no third-party runtime packages |

The deployment target is the oldest OS that can run your app, not the OS required to build it. Keep a Swift 6.2+ build toolchain on a supported newer Mac; Xcode 26.2 requires macOS 15.6 or later. See [Apple’s Xcode requirements](https://developer.apple.com/xcode/system-requirements/). Actual macOS 12.4 runtime validation remains pending. The bundled Xcode 26.2 test harness raises test targets to macOS 14; this does not raise the SDK or example-app minimum. Use the example apps and standalone probes for runtime checks on Monterey.

The current beta version is `0.1.0-beta.1`; there is no stable release. Pin this exact prerelease for discoverable pairing, or use `main` to evaluate ongoing changes. Commit your application's resolved dependency state. See [qualification](BETA-READINESS.md) for what remains unverified, including distribution delivery and other OS/hardware combinations.

## Xcode app targets

1. Add `https://github.com/AppitStudio/Talk.swift.git` through Xcode's package dependency interface.
2. Choose exact version `0.1.0-beta.1` (or a reviewed commit).
3. Link the **Talk** library product to each participating application target.
4. Add `import Talk` where you implement the integration.
5. Create a separate shared Swift package target for your generated contract and client. Link that library into the apps that use it.

`StudioContract`, `TalkStudio`, and `TalkAutomator` are examples. Do not use their scene-specific contract as your production API.

## SwiftPM contract module

This complete `Package.swift` creates a reusable contract module with build-time generation:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyAppIntegration",
    platforms: [.macOS("12.4")],
    products: [
        .library(name: "IntegrationContract", targets: ["IntegrationContract"])
    ],
    dependencies: [
        .package(url: "https://github.com/AppitStudio/Talk.swift.git", exact: "0.1.0-beta.1")
    ],
    targets: [
        .target(
            name: "IntegrationContract",
            dependencies: [.product(name: "Talk", package: "talk.swift")],
            exclude: ["Contract.talk.json"],
            plugins: [.plugin(name: "TalkClientPlugin", package: "talk.swift")]
        )
    ],
    swiftLanguageModes: [.v6]
)
```

Put your schema at `Sources/IntegrationContract/Contract.talk.json`. Include a small ordinary Swift source file in that target so SwiftPM recognizes it before code generation. The [starter assets](../Skills/talk-integrations/assets) provide a working schema, source marker, and provider/consumer wiring you can adapt. Their manifest uses a local `TalkSDK` dependency alias; the example above uses the remote package identity `talk.swift`.

`TalkClientPlugin` generates Swift DTOs and a typed client. It does **not** embed the JSON contract in an app, add app entitlements, or wire app lifecycle. Export the provider's canonical JSON and copy it into `Contents/Resources/Contract.talk.json` before final app signing. See [contracts](CONTRACTS.md) and [integration](INTEGRATION-GUIDE.md).

## Local development

```sh
git clone https://github.com/AppitStudio/Talk.swift.git
cd Talk.swift
swift build
swift test --disable-xctest
```

For Xcode, add the checkout as a local package. In a sibling Swift package you can use `.package(name: "TalkSDK", path: "../Talk.swift")`; reference its products and plugin using `package: "TalkSDK"`. The supplied skill starter demonstrates this layout. Keep local paths out of shared remote package manifests.

## Signing and capabilities

Compilation does not require access to a developer account. Persistent pairing through `CredentialStore` does require an Apple-signed app whose provisioning authorizes its signed application identifier and app-specific Keychain access group.

- Enable Keychain Sharing for each app target and retain its own application-identifier group.
- Confirm the signed `com.apple.application-identifier` appears in `keychain-access-groups`. Use the actual provisioning App ID prefix; it is not always the Team ID.
- Provider and consumer each store their own credential copy. They do not need a shared Keychain group.
- For sandboxed participants, enable incoming and outgoing network connections (`com.apple.security.network.server` and `com.apple.security.network.client`), as in the examples.
- Preserve the application identifier, app-specific group, and storage service across legitimate updates.

Unsigned or ad-hoc hosts fail persistence with `credentialConfiguration`. Do not work around this with plaintext storage or broader access groups. Apple Development tests do not establish Developer ID or Mac App Store delivery support; validate your intended distribution route separately.

## Register and connect the apps

The provider embeds the canonical contract and declares `TalkContract` in Info.plist. Declare `talk-spike-provider` as the provider URL scheme and `talk-spike-consumer` as the consumer scheme. These strings are part of the current SDK routing implementation; do not rename them independently. Apps with both roles declare both.

Wire incoming URLs into `EndpointResolver`, keep the provider's callback bundle allowlist explicit, and launch each signed app once at its intended installation. There is no online registration or central service. Discovery uses LaunchServices and preserves unavailable candidates; duplicate installations require resolution before reconnect.

Continue with the [integration guide](INTEGRATION-GUIDE.md), [runnable examples](EXAMPLES.md), or [LLM-assisted workflow](LLM-INTEGRATION.md).
