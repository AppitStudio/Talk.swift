<!-- talk-integration-guide:1 -->
# DockFlow integration guide

```json
{
  "formatVersion": 1,
  "app": "dockflow",
  "displayName": "DockFlow",
  "guideVersion": "1.0.0",
  "updated": "2026-09-07",
  "status": "beta",
  "roles": [
    "provider"
  ],
  "sdk": {
    "repository": "https://github.com/AppitStudio/Talk.swift.git",
    "version": "0.1.0-beta.2"
  },
  "provider": {
    "bundleID": "com.appit.DockFlow",
    "contract": "Contract/Sources/DockFlowTalkContract/Contract.talk.json",
    "contractID": "com.appit.dockflow.presets",
    "contractVersion": "1.0.0",
    "sha256": "d38910cce7211ea36a4b88bd73604c37f48ce4315b178878804c578c12311c17",
    "module": "DockFlowTalkContract"
  },
  "consumes": []
}
```

## Purpose and roles

DockFlow lets a paired app list available Dock presets, read the active preset, request a preset switch, and observe changes. A launcher, menu bar app, or automation tool can build its own feature against this documented contract. Its developer needs no DockFlow source, private shared models, product token, or access to DockFlow's repository.

DockFlow is the provider for this contract. Your app is the consumer. ExtraBar is one consumer example; it has no special API status. DockFlow does not need a new handler or a new UI section for each consumer. Supporting an additional provider in your own outgoing app library does require implementing that provider's documented features.

## Compatibility and prerequisites

- Swift tools 6.2 and Swift 6. The Talk SDK and public consumer contract package target macOS 12.4, but the DockFlow provider app requires macOS 13.5. A working DockFlow integration therefore requires macOS 13.5 or later. The SDK’s actual macOS 12.4 runtime remains unverified; see [beta readiness](../../Docs/BETA-READINESS.md).
- The public consumer package pins Talk `0.1.0-beta.2`. This SDK version introduces generalized callback routing for pairing and saved reconnect. Use a DockFlow build integrating that provider update; no minimum shipping DockFlow version for that app update has been assigned yet. Earlier ExtraBar-only DockFlow builds cannot be assumed to accept unrelated consumers. Confirm the provider's release notes before shipping your integration.
- Install a DockFlow build exposing `com.appit.dockflow.presets` version `1.0.0`, and create test presets in its own UI. Applying presets requires DockFlow's normal license admission. Consumers never receive its license credentials.
- Give your consumer its own bundle ID, Apple signing/provisioning and app-specific data-protection Keychain entitlement. Register `talk-spike-consumer`, route setup and endpoint URLs, and configure sandbox network permissions where needed. Follow [installation](../../Docs/INSTALLATION.md); ad-hoc command-line compilation does not establish a usable protected app.
- User approval occurs in DockFlow. App names, bundle IDs and advertised contracts are routing/metadata hints, not verified publisher identity. Support one unambiguous installed/running target; ask users to resolve duplicates rather than picking one arbitrarily.

## Public contract

The [canonical JSON](Contract/Sources/DockFlowTalkContract/Contract.talk.json) is the complete public wire contract. Its SHA-256 in the metadata pins the exact bytes; it is a drift check, not a digital signature. The [standalone package](Contract/Package.swift) runs `TalkClientPlugin` to generate `DockFlowPresetsAPI`, `DockFlowPresetsClient` and all DTOs. No app implementation dependency exists. Copy the whole `Contract` directory into your app's local packages and retain the metadata/hash with your dependency pin.

| Type / field | Meaning |
| --- | --- |
| `DockFlowPreset.id` | Stable preset UUID to pass back when applying; never invent or derive it from a name. |
| `name`, `order`, `appCount` | User-visible name, provider ordering, number of configured apps. Names are user data. |
| `extraDockOnly` | Provider's ExtraDock-only preset flag. The Talk apply action still delegates to DockFlow's existing apply behavior; this flag is not a separate command. |
| `DockFlowPresetsSnapshot.sessionID`, `revision` | Provider-process session and monotonic revision. Accept revisions only within the current connection/session; do not compare revision numbers across restarts. |
| `activePresetID` | Optional last-applied preset ID; it may be absent or no longer occur in the returned list. |
| `applyInProgress` | Provider has admitted a switch and is still applying it. |
| `presets` | At most 200 entries in the current implementation. No pagination or truncation indicator exists in version 1; do not claim an exhaustive list above that bound. |
| `ApplyPresetRequest.id` | UUID from the latest available snapshot. |
| `ApplyPresetResult` | Structured outcome, optional display message and current snapshot. Use `outcome` for program logic; message text is not a stable code. |

Frames remain bounded to 64 KiB including envelope. A 200-item count cap does not guarantee every set of unusually large names fits; treat oversize responses as failures, never as an empty library. This contract exposes no preset editing, app paths, DockFlow database access or arbitrary command execution.

## Actions, permissions, and side effects

| Action | Generated method | Required scope | Side effect / meaning |
| --- | --- | --- | --- |
| `dockflow.presets.read` | `snapshot()` | `dockflow.presets.read` | Read preset metadata and active state. No mutation. Required for this integration's basic feature. |
| `dockflow.presets.apply` | `applyPreset(ApplyPresetRequest)` | `dockflow.presets.apply` | Request a switch to an existing preset using DockFlow's normal Dock mutation behavior. Changes the user's Dock configuration. Optional. |
| `dockflow.presets.observe` | `subscribe()` | `dockflow.presets.observe` | Obtain an initial snapshot and authorize the live preset feed. No mutation. Optional. |

Event `dockflow.presets.changed` carries `DockFlowPresetsSnapshot` and requires the observe subscription. It can expose the same preset metadata as a read. Events are coalesced (currently about 250 ms), ordered within a connection, and have no durable replay. After a gap, reconnect and resubscribe for a fresh snapshot.

Read-only pairing must work. Show Apply and Live Updates as optional permissions, and disable associated features when absent. Generated `API.actions[actionID]` gives the scope; action identifiers are not generically interchangeable with scopes even though these spellings match.

An apply result of `accepted` means the request was admitted and background work was dispatched; it does **not** prove completion. Display Applying, then reconcile through snapshots/events. `cooldown` means another apply or the normal cooldown prevented admission; `notFound` means the preset disappeared; `rejected` currently includes normal license admission failure. Version 1 has no completion receipt or exactly-once guarantee. Do not replay a request after timeout, disconnect or cancellation.

## Connection lifecycle

1. Own one consumer `IntegrationStore(persistence: CredentialStore(service: ...))` with a stable service specific to your app's consumer role. Reload it at startup. Keep app-level pairing, resolver, session and event task ownership; closing Settings must not silently disable automation.
2. In your app's DockFlow library entry, guide the user to DockFlow → Talk Integrations → Apps with access → Start Pairing. DockFlow freezes the selected permissions for one attempt, at most five minutes. In your app choose Discover, then Connect. Forward incoming setup URLs to `PairingDiscovery` and endpoint replies to `EndpointResolver`.
3. Show the full verification code in your app and DockFlow. The user compares both codes and explicitly approves scopes in DockFlow. Cancel, denial and expiry end that attempt. A new attempt needs a new explicit Start Pairing action. Labels do not establish publisher identity.
4. Validate the returned provider hint is `com.appit.DockFlow`, the read scope exists, and granted scopes are a subset of the pinned contract. Save the `PairingRecord` through the protected consumer store. Save success and connection success are separate states; a failed consumer save can leave a provider-only grant needing explicit cleanup.
5. Resolve a fresh endpoint from the saved record and chosen installation, connect the generated client for authenticated contract negotiation, then read or subscribe according to saved scopes. Subsequent permitted automation reuses saved consent. Pairing mode is unnecessary for reconnect, restart or cold provider launch.
6. Close/cancel on Disconnect while keeping the saved grant. Forget closes the connection and removes only your app's saved copy; it does not revoke DockFlow's grant. DockFlow's Revoke stops access and persists removal. Changing permissions requires fresh consent and a fresh credential replacing that grant.

Use the [portable pairing reference](../../Skills/talk-integrations/references/pairing.md) and [lifecycle reference](../../Skills/talk-integrations/references/lifecycle.md) for exact SDK API wiring, URL buffering, cancellation, storage recovery and replacement ordering.

## Typed implementation

The [compile-checked consumer recipe](Examples/DockFlowRecipe.swift) imports only `Talk` and the public `DockFlowTalkContract` package. It includes saved reconnect, scope-based required capabilities, a single apply call, initial subscription and typed event decoding. Its functions are primitives for your app-owned coordinator; supply the matching saved record/client, own/cancel tasks, maintain generation/revision guards and add real discovery/consent UI from the lifecycle references.

Add the copied package's `DockFlowTalkContract` library to your app, alongside Talk. No `DockFlowCore`, private model, copied generated Swift or private repository URL is needed. Generated Swift comes from the public JSON during the build; do not hand-edit it. If your build cannot use SwiftPM plugins, use `TalkClientGenerator` to emit the same types and verify regeneration before release.

For a read-only feature call `snapshot()` after `connectDockFlow`. Wire your own deliberate widget/shortcut/automation trigger to `applyDockFlowPreset` only when the saved apply permission exists. Present structured outcomes and refresh state after uncertain delivery. Run the reproducible external build from the SDK checkout:

```sh
python3 Scripts/validate-public-integrations.py
```

This compiles an isolated consumer from the public schema and exact recipe, with the public SDK source as a local dependency override. It never reads DockFlow or ExtraBar source, signs/launches apps, pairs, or changes the Dock. [Authoring guidance](../../Docs/INTEGRATION-GUIDE-AUTHORING.md) describes provider export and compatibility checks.

## Errors and recovery

| Signal | Consumer behavior |
| --- | --- |
| `pairingRequired` | Offer explicit setup; do not start provider pairing automatically. |
| `permissionDenied` | Explain the missing permission or denied request; let the user intentionally replace permissions. Do not repeatedly prompt. |
| `ambiguousProvider`, `unavailable` | Keep the saved grant; resolve installation/running-copy ambiguity or open/update DockFlow, then retry connection. |
| `invitationExpired` | Clear the transient candidate/code; repeat explicit Start Pairing and discovery. |
| `timedOut`, `disconnected` after a mutation | Outcome unknown. Reconnect/read current state without replaying the mutation. An endpoint timeout after revocation is not proof of a successful revoke. |
| `eventOverflow` or normal event-stream completion | Mark disconnected/stale, close the session and obtain a fresh subscription snapshot on reconnect. |
| Contract incompatibility / `unsupportedVersion`, `unknownAction` | Offer an app update or disable that feature. Never invent a fallback action or bypass negotiation. |
| `busy` | Stop overlapping work; explain the temporary limit. A delayed new user action is different from automatic mutation replay. |
| `credentialConfiguration`, `credentialLocked`, `credentialStorage`, `credentialOperationPending` | Follow protected-store recovery; freeze writes until explicit reload/recovery. Do not use plaintext or change groups/identity to hide the failure. |
| `invalidFrame`, `invalidMessage` | Close the session and report an incompatible/invalid response. Keep user data out of logs. |

Snapshot/event data contains user-chosen preset names and IDs. Keep payloads and credentials out of telemetry and diagnostics; record only stable error codes and synthetic validation observations.

## Integration experience

Use a dedicated **Talk Integrations** settings tab. In your consumer app, **Apps I control** contains the developer-defined DockFlow library card with the feature it unlocks, installation/setup state, saved connection state and granted permissions. This library lists apps whose API your app actually implements; arbitrary discovery must not fabricate a working feature.

In DockFlow, **Apps with access** lists generic independent grants, regardless of the consumer's name. Show the user's label, permissions, saved/listener state, permission replacement and Revoke. Labels should remain identified as user-entered/unverified where trust matters. Do not require a new DockFlow app release or consumer-specific panel for each incoming app.

If either app later supports both roles, the two lists stay independent. A connection in one direction does not authorize the reverse direction. Separate Connected, Saved but disconnected, Pairing/consent pending and Recovery required. Read-only access is useful; Disconnect, Forget and Revoke have different effects. Follow the [SDK integration UX specification](../../Docs/INTEGRATION-UX.md).

## Validation evidence

| Check | Evidence / limit |
| --- | --- |
| Public contract provenance | Copied from the provider's canonical export and compared with ExtraBar's pinned copy on 2026-09-07. Contract `1.0.0`; hash above. No private app source is needed to generate/use it. |
| Public package and recipe | `Scripts/validate-public-integrations.py` generates/types/builds an isolated consumer using only public artifacts; local validation recorded in the SDK handoff. This is compile evidence, not installed-app evidence. |
| Existing app pair | The prior local signed DockFlow/ExtraBar pair passed discovery, full-code consent, read-only snapshot, reconnect/restart/cold launch, revocation and test-grant cleanup on macOS 15.7.9 arm64. See [beta readiness](../../Docs/BETA-READINESS.md). |
| Unrelated consumer | Generalized routing is available in Talk `0.1.0-beta.2`; no unrelated signed consumer end-to-end pass is claimed by this guide. Qualify your actual consumer with its own signing, consent and lifecycle. |
| Applying and event delivery | The real-app validation above used read-only access; it did not mutate real presets. Contract compilation does not establish successful live Dock changes or complete event behavior. |
| Platform/distribution | The SDK/consumer package targets macOS 12.4; DockFlow requires macOS 13.5, which sets the minimum for this app pair. Declared targets and local Developer ID evidence do not qualify every OS, CPU, team, distribution/update route or security boundary. Talk remains beta. |

Before shipping, run actual-app denial/cancellation, read-only use, optional permissions, ordinary automation, reconnect after restart, revocation, uncertain mutation recovery and cleanup of only the test grant. Record PASS/FAIL/NOT RUN independently. Do not replace product validation with the guide checker.

## Maintenance and support

The provider owns the wire schema and action semantics. Consumers pin a reviewed guide version and contract hash. Changes to action IDs, scopes, mutation classification or DTOs require an explicit compatibility review; never silently replace the pinned JSON from discovery metadata.

Run `TalkContractChecker` with the old consumer contract first and the new provider export second. Update schema, metadata, guide semantics and recipe in the same reviewed change, then regenerate and recompile. Increment `guideVersion` for guide/recipe changes; increment `contractVersion` only for actual API changes. These are independent of Talk SDK and DockFlow app versions.

For SDK/public guide issues use the [Talk repository](https://github.com/AppitStudio/Talk.swift). Use private vulnerability reporting for security concerns. Follow [contributing](../../CONTRIBUTING.md) and [security guidance](../../SECURITY.md); include synthetic reproduction steps, versions and stable errors, never a pairing record or user preset dump. Public availability does not itself grant a license; respect the repository's current licensing statement.
