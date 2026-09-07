# Installation and registration

## Package dependency

Set `TALK_SDK_ROOT` to the actual checkout in the invoking shell. Check its `Package.swift`: the current toolchain floor is Swift 6.2, with declared macOS 12.4 deployment support. Use the host's supported Xcode toolchain and Swift 6 concurrency checking for new integration code. Compare default actor isolation across targets; keep generated DTOs in a nonisolated module.

For Xcode, add `https://github.com/AppitStudio/Talk.swift.git` at exact beta version `0.1.0-beta.2` or a reviewed commit, or use the SDK directory as a local package. Link `Talk` to each participating app. Add a shared contract library to both apps. Preserve existing configurations and entitlements. The SDK's `StudioContract` is demo-specific; real integrations get their own contract.

The SDK's `Docs/INSTALLATION.md` contains a complete remote SwiftPM manifest using `package: "talk.swift"`. The published discoverable-pairing prerelease is `0.1.0-beta.2`. Keep the skill compatible with the resolved SDK API; documentation on main may include later corrections without changing the SDK tag.

For a local SwiftPM dependency, [the starter Package.swift](../assets/Package.swift) demonstrates the explicit local dependency alias `TalkSDK`, a shared target depending on `Talk`, and `TalkClientPlugin`. Adapt the dependency path to the host layout. Keep `Contract.talk.json` at the contract target root and exclude it from ordinary sources. A tiny ordinary Swift file ensures SwiftPM recognizes a source target before plugin generation. Do not hand-define DTOs also emitted by the generator.

Either attach the plugin to the shared **Swift package target**, or explicitly run the exporter/generator and compile its output in that module. Do not compile plugin and manually generated copies together. The plugin generates Swift only; it does not directly configure an Xcode application target or embed app resources.

## Signing and sandbox

Saved grants require an Apple-signed, correctly provisioned running app. Ad-hoc/unsigned builds can compile but cannot persist grants. A `swift run` process is not a substitute for a provisioned `.app` test.

Enable Keychain Sharing in each app target. Check the **signed artifact**:

- `com.apple.application-identifier` is the authorized App ID prefix plus that app's bundle ID.
- `keychain-access-groups` includes that exact application identifier. Preserve unrelated existing groups; Talk explicitly selects its app-specific group.
- Obtain the prefix from signing/provisioning; do not synthesize it from Team ID (older accounts may differ).
- Each app uses its own group. Do not share a Keychain group to enable pairing.
- For this preview, enable `com.apple.security.network.client` and `com.apple.security.network.server` in sandboxed participants, as the signed examples do. Provider listeners require incoming networking; pairing/connections and the SDK networking setup must work in the actual consumer/provider targets.

Preserve bundle ID, app-specific group and Keychain service across updates. Storage uses nonsynchronizing, unlocked-device-only data-protection items. Surface locked/unavailable storage; never add a plaintext fallback or the removed backend.

Use existing authorized local signing. Developer ID, App Store, unrelated teams and certificate renewal are separate qualification lanes; development checks do not qualify them.

For an installed app, inspect its existing signing lane and normal startup requirements before replacing it for runtime tests. A successful Release build can still lack host-specific licensing/product configuration. Reuse only authorized configuration through private excluded files and redact logs; do not change licensing or Keychain policy to pass a Talk test. If startup blocks before Talk, diagnose that layer separately. A development certificate is not an interchangeable substitute for the installed signing lane; use a matching authorized certificate and profile, then verify the final nested bundle signatures and entitlements. Retain a recoverable original installation until the update runs correctly.

When two app workspaces are open, a shared local package override can produce “Missing package product” in the second workspace. Prefer consistent remote pins in both apps and their contract packages; use a temporary local override in one workspace when developing the SDK. Do not silently rewrite the user’s chosen dependency setup.

## Provider metadata

Merge into Info.plist, preserving other URL types:

```xml
<key>TalkContract</key><string>Contract.talk.json</string>
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleURLName</key><string>com.example.provider.talk</string>
  <key>CFBundleURLSchemes</key><array><string>talk-spike-provider</string></array>
</dict></array>
```

Export JSON to `Contents/Resources/Contract.talk.json` before final signing. Discovery accepts exactly that filename; a nested package resource bundle is insufficient. Put export/copy phases before signing and verify the final artifact for stale resources.

## Consumer routing and LaunchServices

Declare `talk-spike-consumer` in the consumer's `CFBundleURLTypes`. An app with both roles declares both schemes. These **scheme strings are currently hardcoded** in `EndpointResolver`/`ProviderDiscovery`: customize bundle/contract IDs, but do not rename schemes without a coordinated SDK change.

Route incoming URLs through the existing delegate/SwiftUI lifecycle, preserving other handlers. Consumer URLs go to both a long-lived `PairingDiscovery.receive(_:)` and `EndpointResolver.receive(_:)`. Provider URLs go to `DiscoverablePairingHost.receive(_:)` and `EndpointResolver.reply(...)` using current `TalkProvider.endpoints()` and an explicit supported-consumer bundle allowlist. This allowlist is routing policy, not publisher verification.

Launch each finished app once at its intended local installation to register it with LaunchServices, then inspect `ProviderDiscovery.installed()`. Preserve unavailable candidates for diagnosis. No daemon or cloud service is needed.

At reconnect call `NSWorkspace.shared.urlsForApplications(withBundleIdentifier:)`, `ProviderDiscovery.uniqueInstallation(...)`, then `EndpointResolver.resolve(record:applicationURL:callbackBundleID:)`. Do not select the first duplicate or retain an old listener port. Cold launch URLs can arrive before restoration; buffer a bounded number (the demo uses four) until startup completes. Callback delivery requires exactly one running consumer process with the allowed ID. Resolve duplicates using intended test copies; do not delete arbitrary apps or globally rebuild LaunchServices.

Run [the preflight helper](../scripts/validate-app.py) on the final bundles; commands and its limits are in [validation](validation.md).
