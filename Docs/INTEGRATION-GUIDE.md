# Integrating Talk into a macOS app

This guide follows the runnable Studio and Automator examples. It uses explicit pairing, synthetic data, macOS 13 APIs and Swift 6.2. Validate your actual platform/signing environment separately; see [qualification](QUALIFICATION.md) for measured Apple Development results and the remaining signing/platform qualification lanes. No daemon, cloud service, account, publisher authentication or automatic mutation retry is provided.

Start with the [installation guide](INSTALLATION.md) for Xcode/SwiftPM dependencies, signing, and app capabilities.

For an agent workflow covering installation, app registration and actual-app acceptance tests, use the [Talk integrations skill](../Skills/talk-integrations/SKILL.md).

## Define and generate the contract

Start with `Examples/Shared/StudioContract/Contract.talk.json`. Declare stable wire IDs, concrete scopes, mutation classification, named DTOs, and event payloads. The supported types and wire encoding are in CONTRACTS.md. Keep handlers out of this data module. Swift member names are source API, independent of wire IDs.

Run from the project root:

```sh
swift build
mkdir -p LocalBuild/GuideValidation
swift run TalkSchemaExporter Examples/Shared/StudioContract/Contract.talk.json LocalBuild/GuideValidation/Contract.talk.json
swift run TalkClientGenerator LocalBuild/GuideValidation/Contract.talk.json LocalBuild/GuideValidation/Studio.generated.swift
swift run TalkContractChecker Tests/Fixtures/CompatibilityOld/Contract.talk.json Tests/Fixtures/CompatibilityNew/Contract.talk.json
python3 Scripts/validate-integration-guide.py
```

The checker compares **client first, provider second**. Reversing the two fixture arguments intentionally fails because the new client requires `test.extra`. The library checker and generated-client initializer also accept a required capability subset and minimum minor version.

For SwiftPM, follow `StudioContract` in Package.swift: depend on `Talk`, exclude `Contract.talk.json` from ordinary sources, and attach `TalkClientPlugin`. The plugin generates DTOs and a typed client into its declared output directory. Export JSON separately and embed it in app resources **before** signing, as `Scripts/build-examples.py` does.

## Bind provider handlers

`CredentialStore` targets the data-protection Keychain and explicitly selects the host's signed `com.apple.application-identifier` access group for every operation. Enable Keychain Sharing in the macOS app target, retain the app-specific group, and use a matching Apple signature and provisioning profile. The SDK never selects the first shared group, synthesizes a Team ID, falls back to the legacy backend, or changes process-wide prompt settings. Missing signing/entitlements fail with `credentialConfiguration`. Each communicating app keeps its own credential copy in its own group; do not share a Keychain group between provider and consumer just to make pairing work.

Items are nonsynchronizing and use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Locked access fails visibly. No biometric prompt is required for routine reconnect. Preserve the application identifier/access group across legitimate updates and run [the signing qualification matrix](BETA-READINESS.md) in your environment. Apple Development, Developer ID and App Store are distinct validation lanes.

Both example apps use this same production backend. The earlier file-based implementation and its migration paths have been removed. Build the examples with an explicitly authorized matching Apple signature/profile; ad-hoc builds cannot persist grants.

Own one IntegrationStore per Keychain service for the life of your app. TalkProvider supports up to 16 integration records, each with its own TLS listener and key. Construct the provider and restore its saved grants at startup. A missing, inaccessible or invalid Keychain item must be surfaced; never substitute plaintext storage.

The following complete snippet is typechecked by the guide validator against the generated example API:

```swift
import Foundation
import Talk
import StudioContract

@MainActor
final class GuideProvider {
    private var snapshot = StudioSnapshot(sessionID: UUID(), revision: 0, selectedSceneID: "available")
    private lazy var store = IntegrationStore(persistence: CredentialStore(service: "dev.talk.synthetic.guide.pairing"))
    private(set) lazy var provider = TalkProvider(store: store, contract: StudioAPI.schema,
                                                 subscriptionAction: StudioAPI.observe) { [weak self] action, payload in
        guard let self else { throw TalkError.unavailable }
        return try await self.handle(action, payload)
    }

    // Invoke at app startup after signing/provisioning the application.
    func start() async throws {
        try await provider.restore()
    }

    private func handle(_ action: String, _ payload: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        switch action {
        case StudioAPI.read, StudioAPI.observe:
            return try .encoding(snapshot)
        case StudioAPI.select:
            let input = try payload.decode(SelectScene.self)
            guard Scene.examples.contains(where: { $0.id == input.id }) else { throw TalkError.invalidMessage }
            try Task.checkCancellation() // immediately before the side effect
            snapshot = StudioSnapshot(sessionID: snapshot.sessionID, revision: snapshot.revision + 1, selectedSceneID: input.id)
            let result = snapshot
            await provider.publish(action: StudioAPI.changed, payload: try .encoding(result))
            return try .encoding(result)
        default: throw TalkError.unknownAction
        }
    }
}
```

TalkServer validates the contract/action mapping at start, checks the negotiated capability set and persistent scope on **every** call/subscription, then validates the input shape before the handler. Output and event shapes are checked independently. Domain validation and cooperative cancellation belong in the handler. Cancellation cannot undo a committed side effect.

## Pair and obtain scoped consent

StudioModel demonstrates the full consent flow. `PairingHost.start(providerBundleID:approve:)` creates a five-minute, one-use invitation. Only its approval closure may create a durable PairingRecord after visible provider consent. The record contains a fresh `PairingCredential`, the endpoint bundle hint, and exactly the approved scopes; call `provider.approve(record)` and return the record from the closure. Keep the host alive until completion/expiry, and stop it on cancellation. PairingHost cancels its approval closure if the consumer disconnects.

Transfer the code directly into Automator's SecureField. Do not print it, put it in a URL, take a screenshot of it, or persist the invitation. `PairingClient.pair(using:)` returns a separately keyed durable record; save it with the consumer's IntegrationStore. Never infer a verified publisher from the displayed name, bundle ID or claimed Team ID. Persistent consent authenticates possession of the paired key.

Studio's new-connection permission toggles choose read-only, read/observe, read/select, or all three. For expansion, choose the intended row's **Replace permissions**, transfer the new code, and approve the displayed new scope set. The new record's `replacesID` rotates that integration's key; the old listener and subscriptions stop. Rejection before approval leaves the old grant intact. A persistence failure can leave the selected old integration stopped, with recovery required. Other connections remain available. Never silently add scopes to a stored record.

Pairing is not a distributed transaction: the provider may save a grant before the consumer disconnects or fails to save it. Inspect/revoke that provider-only row and pair again. An unresolved storage write must finish and be reloaded before another change.

## Resolve, connect, call and subscribe

AutomatorSession owns one client and one event task per saved provider grant. At reconnect, resolve exactly one registered installation using `ProviderDiscovery.uniqueInstallation`; duplicate/stale candidates fail visibly. `EndpointResolver.resolve` launches the exact app URL and obtains a fresh public endpoint. Its callback is only a hint: TLS authenticates the paired key. Pass incoming app URLs to `EndpointResolver.receive`; the provider replies using the matching entry in `TalkProvider.endpoints()` and a deliberately narrow callback bundle allowlist. See both AppDelegate files and StudioModel.handleURL. Callback delivery requires exactly one running process with the allowed bundle ID; multiple processes are ambiguous even when their app paths match. Bundle IDs remain routing hints, never OS-verified peer identity.

Declare the received URL schemes in each app's `CFBundleURLTypes`: `talk-spike-provider` for the provider and `talk-spike-consumer` for the consumer. The signed example builder includes them. An explicit application URL alone did not suffice for the sandboxed sender in the disposable routing probe when the receiver advertised an unrelated scheme; correcting its declaration restored delivery. Opt-in diagnostics (`TALK_TRANSPORT_DIAGNOSTICS=1`) retain a bounded numeric callback-delivery error code without URL or credential data. See [separate-process validation](PROCESS-VALIDATION.md) for the actual duplicate-copy matrix and its limits.

```swift
import Foundation
import Talk
import StudioContract

func runGuideClient(port: UInt16, record: PairingRecord) async throws {
    let transport = try TalkClient(port: port, credential: record.credential)
    let client = StudioClient(transport: transport)
    do {
        try await client.connect() // TLS, then authenticated compatibility/capability check
        let initial = try await client.subscribe() // requires observe scope
        _ = initial
        _ = try await client.selectScene(SelectScene(id: "focus")) // requires select scope
        for try await message in transport.events {
            try Task.checkCancellation()
            switch try client.decodeEvent(message) {
            case .changed(let snapshot):
                _ = snapshot // update your actor/UI, rejecting older session revisions
            }
        }
    } catch {
        await transport.close()
        throw error
    }
    await transport.close()
}
```

Own and cancel this long-lived event task when disconnecting. Read-only connections call `snapshot()` instead of `subscribe()`. Events are bounded live delivery: no replay, and overflow closes the session with `eventOverflow`. Reconnect with a new transport and subscribe for a fresh snapshot. For Studio, compare both `sessionID` and `revision` so a late older event does not overwrite a newer snapshot.

By default the generated client requires all actions/events in its build-time schema. A newer client may deliberately select old capabilities using `requiredActions` and `requiredEvents` in its initializer; methods outside that negotiated set are rejected. `minimumMinor` defaults to zero to allow structurally compatible subsets on older providers. Set it explicitly when application semantics require a newer minor. Major mismatches always fail. The compatibility fixtures run actual independently generated clients in both directions.

## Lifecycle and errors

| Result | Application response |
| --- | --- |
| `permissionDenied` | Inspect this integration's scopes. Ask for additional consent via replacement pairing. |
| `ContractDiagnostic` / `unsupportedVersion` | Show the incompatibility; choose a supported capability subset or update/re-pair as appropriate. No unsupported handler has run. |
| `disconnected`, `timedOut`, cancellation after sending | Mutation outcome may be unknown. Reconcile application state; **never automatically retry**. |
| `eventOverflow` | Reconnect and resubscribe for a fresh snapshot; acknowledge the gap. |
| `busy` | The bounded work limit is reached. Do not blindly repeat mutations. |
| `credentialOperationPending` | Freeze changes. Reload actual storage after the system operation finishes. Never claim durable revocation yet. |
| `credentialConfiguration` | Correct the host signature, application identifier and provisioning. Do not switch to legacy storage to suppress the error. |
| `credentialLocked` / `credentialStorage` | Report protected-storage recovery needs. Do not weaken ACLs or fall back to plaintext. |
| `ambiguousProvider` / `unavailable` | Resolve the installation problem explicitly; do not silently pick a duplicate. |
| `invalidMessage` / `unknownAction` | Treat as contract/domain misuse or an invalid peer; no automatic replay. |

Use `provider.revoke(id)` for one integration. It invalidates the endpoint and cancels its active handlers/events before saving removal. A `.revocationPending` row stays visible if persistence fails. Explicit `restore()` reloads the actual archive and restarts stored grants; it disconnects existing sessions, so use it as a recovery operation. Consumer **Forget pairing** only removes the local copy; it does not prove provider revocation.

Only the bounded version 2 archive is accepted. Old single-record data is rejected; no migration or old namespace search occurs. Preserve the app-specific group across updates and validate the actual signing/distribution lane; the latest results are in CREDENTIAL-LIFECYCLE.md and BETA-READINESS.md.

## Validate the runnable apps

```sh
swift test --disable-xctest
python3 Scripts/validate-contract-pipeline.py
python3 Scripts/validate-production-credentials.py
python3 Scripts/build-examples.py --signing-config LocalBuild/example-signing.private.json
```

Quit all four examples before packaging. Open both variants once to register them. Pair each consumer with both providers; verify individual permissions, simultaneous subscriptions, repeated calls, disconnect/reconnect, cold provider launch from the consumer, and selected revocation while another connection remains usable. Test permission expansion through the replacement code/consent flow. Revoke/forget synthetic grants before another rebuild.

No system sleep is forced during validation because it would interrupt unrelated work. Socket disconnect/reconnect tests are not proof of real sleep/wake. Consult [qualification](QUALIFICATION.md) for exact OS, architecture, signing, resource observations, failed gates and untested scenarios.

Deadline timers use monotonic uptime and pause during system sleep. Expired invitation Date checks still reject new requests, while pending consent cancellation and listener cleanup can be delayed after waking. This clock behavior and the disposable locked-storage/native installation/load evidence are detailed in [local hardening validation](LOCAL-HARDENING.md). A timeout or disconnect never proves a mutation was rolled back.

Discovery reads Info.plist and the contract through descriptors that reject FIFOs and other special files. Both resources are limited to 64 KiB; symlinked Info.plist is unavailable, and contract paths must remain inside the resolved Resources directory. Unreadable or unsupported metadata keeps the installation visible as an unavailable candidate. These checks prevent special-file blocking; they do not promise an absolute I/O deadline for regular files on slow or remote filesystems.
