<!-- talk-integration-guide:1 -->
# ExtraDock integration guide

```json
{
  "formatVersion": 1,
  "app": "extradock",
  "displayName": "ExtraDock",
  "guideVersion": "1.0.0",
  "updated": "2026-09-12",
  "status": "beta",
  "roles": [
    "provider"
  ],
  "sdk": {
    "repository": "https://github.com/AppitStudio/Talk.swift.git",
    "version": "0.1.0-beta.2"
  },
  "provider": {
    "bundleID": "com.appitstudio.ExtraDock",
    "contract": "Contract/Sources/ExtraDockTalkContract/Contract.talk.json",
    "contractID": "com.appit.extradock.docks",
    "contractVersion": "1.0.0",
    "sha256": "d09381c2f74d3c8aa58b0ef3538139225e7e624d093a2c9a574ecd0c89fa1e7d",
    "module": "ExtraDockTalkContract"
  },
  "consumes": []
}
```

## Purpose and roles

ExtraDock adds extra docks to macOS. A paired app can list those docks with their current visibility and a preview of their contents, show or hide individual docks, hand a dock back to its configured automatic behavior, and observe changes. A workspace switcher, launcher, focus tool or automation app can build its own feature against this documented contract without ExtraDock's source, private shared models, App Group or product token.

Two apps publish this contract with the same wire IDs and scopes: **ExtraDock 5** (bundle ID `com.appitstudio.ExtraDock`, the metadata bundle ID above) and **ExtraDock 4** (bundle ID `dignicy.extraDock`). Each is an independent provider with its own pairing, grants and Keychain; a snapshot's `generation` field reports which one answered. A consumer that supports both keeps one saved grant per bundle ID and chooses a target explicitly. ExtraDock is the provider for this contract; your app is the consumer. DockFlow is one consumer and has no special API status. Neither ExtraDock generation needs a new handler or settings section per consumer.

## Compatibility and prerequisites

- Swift tools 6.2 and Swift 6. The Talk SDK and this public contract package target macOS 12.4. The provider apps set the effective minimum: ExtraDock 5 requires macOS 26 or later; ExtraDock 4 requires macOS 12.4 or later (its Talk-enabled builds raised the earlier 12.0 minimum). The SDK's actual macOS 12.4 runtime remains unverified; see [beta readiness](../../Docs/BETA-READINESS.md).
- The public package pins Talk `0.1.0-beta.2`, which both providers use at their pairing and saved-reconnect call sites with the generic callback default, so unrelated consumers are not blocked by a bundle-ID allowlist.
- **No shipping ExtraDock build exposes this contract yet.** At guide time the provider implementations exist in the ExtraDock 4 and ExtraDock 5 repositories in launch preparation; the first releases carrying them will be later than ExtraDock 4 `4.3.16` and ExtraDock 5 `5.0.8`. Confirm the provider's release notes before relying on a shipping app build, and treat a missing `TalkContract` entry in an installed app's `Info.plist` as "this build cannot pair".
- Install an ExtraDock build exposing `com.appit.extradock.docks` version `1.0.0` and create test docks in its own UI. Dock commands need ExtraDock's normal licensed startup; consumers never receive its license credentials. ExtraDock 5 exposes only enabled docks; a disabled dock never appears in a snapshot.
- Give your consumer its own bundle ID, Apple signing/provisioning and app-specific data-protection Keychain entitlement. Register `talk-spike-consumer`, route setup and endpoint URLs, and configure sandbox network permissions where needed. Follow [installation](../../Docs/INSTALLATION.md); ad-hoc command-line compilation does not establish a usable protected app.
- User approval occurs in ExtraDock. App names, bundle IDs and advertised contracts are routing/metadata hints, not verified publisher identity. Support one unambiguous installed/running target per generation; ask users to resolve duplicate installations rather than picking one arbitrarily. Both generations can be installed and running at the same time; that is two targets, not an ambiguity.

## Public contract

The [canonical JSON](Contract/Sources/ExtraDockTalkContract/Contract.talk.json) is the complete public wire contract. Its SHA-256 in the metadata pins the exact bytes; it is a drift check, not a digital signature. The [standalone package](Contract/Package.swift) runs `TalkClientPlugin` to generate `ExtraDockDocksAPI`, `ExtraDockDocksClient` and all DTOs; [`Module.swift`](Contract/Sources/ExtraDockTalkContract/Module.swift) adds only public routing hints and the documented bounds. No app implementation dependency exists. Copy the whole `Contract` directory into your app's local packages and retain the metadata/hash with your dependency pin.

| Type / field | Meaning |
| --- | --- |
| `ExtraDockSummary.id` | Stable dock UUID to pass back in visibility changes; never derive it from a name. ExtraDock 5 preserves the UUIDs of docks imported from ExtraDock 4. |
| `name` | User-chosen dock name; an unnamed dock is reported as `Unnamed Dock`. Names are user data. |
| `isVisible` | Resolved visibility at snapshot time. ExtraDock 5 reports the outcome of its visibility resolver (manual overrides, fullscreen hiding and autohide); ExtraDock 4 reports its user-controlled manual visibility flag. |
| `isEnabled` | Always `true` in version 1: ExtraDock 5 omits disabled docks and ExtraDock 4 has no disabled state. Reserved so a future minor can list disabled docks. |
| `position` | Screen edge the dock is pinned to (`left`, `right`, `bottom`, `top`) or absent for a floating dock. |
| `itemCount`, `items` | `itemCount` is the real number of dock elements. `items` is a preview of at most the first 8 elements (`application`, `file`, `folder`, `widget`, `system`), with optional `bundleID`, `path` (dropped when longer than 512 characters) and `iconSymbolName` for icon rendering. Do not treat `items` as the full contents. |
| `ExtraDocksSnapshot.sessionID`, `revision` | Provider-process session and monotonic revision. Accept revisions only within one session; a new `sessionID` means the provider restarted and its live state was rebuilt. |
| `generation`, `appVersion` | Which ExtraDock answered (`extraDock4` or `extraDock5`) and its marketing version string. Informational; do not use them as trust. |
| `docks` | At most 24 docks in version 1, in the provider's own order. No pagination exists; do not claim an exhaustive list above that bound. |
| `DockVisibilityChange` | One dock ID and an action: `show`, `hide`, `toggle` or `automatic`. |
| `SetDockVisibilityRequest.changes` | 1 to 64 changes, processed in order; duplicates are applied twice in order. Zero or more than 64 changes fail before any side effect. |
| `DockVisibilityOutcome` | Per-change result: `status` (`applied`, `notFound`, `disabled`, `unavailable`, `rejected`), `isVisible` after the command when known, and an optional display `message`. Use `status` for program logic; message text is not a stable code. |
| `SetDockVisibilityResult.revision` | The provider revision after the request; the next snapshot or event carries at least this revision. |

Frames remain bounded to 64 KiB including envelope. The dock and preview caps keep ordinary snapshots well under that limit; treat an oversize response as a failure, never as an empty dock list. This contract exposes no dock editing, item paths beyond the preview, screen assignment, ExtraDock settings or arbitrary command execution.

## Actions, permissions, and side effects

| Action | Generated method | Required scope | Side effect / meaning |
| --- | --- | --- | --- |
| `extradock.docks.read` | `snapshot()` | `extradock.docks.read` | Read the bounded dock list with visibility and previews. No mutation. Required for this integration's basic feature and always granted. |
| `extradock.docks.visibility` | `setVisibility(SetDockVisibilityRequest)` | `extradock.docks.control` | Change dock visibility. Changes what the user sees on screen and, in ExtraDock 4, persists the manual visibility flag. Optional. |
| `extradock.docks.observe` | `subscribe()` | `extradock.docks.observe` | Obtain an initial snapshot and authorize the live dock feed. No mutation. Optional. |

Event `extradock.docks.changed` carries `ExtraDocksSnapshot` and requires the observe subscription. It can expose the same dock metadata as a read. Events are coalesced (about 250 ms), ordered within a connection, and have no durable replay. Both providers publish after their own visibility commands and when docks are added, removed, renamed, reconfigured or change visibility for any other reason (hotkeys, ExtraDock's own UI, fullscreen, autohide). After a gap, reconnect and resubscribe for a fresh snapshot.

Action semantics differ slightly by generation because their visibility models differ:

| Action | ExtraDock 5 | ExtraDock 4 |
| --- | --- | --- |
| `show` | Pins a sticky manual-show override (beats fullscreen hiding and autohide, loses to a later manual hide). | Sets the manual visibility flag to visible. |
| `hide` | Pins a sticky manual-hide override (beats everything). | Sets the manual visibility flag to hidden. |
| `toggle` | Hides a currently visible dock, shows a currently hidden one. | Flips the manual visibility flag. |
| `automatic` | Clears the manual override so the dock follows its configured fullscreen/autohide policy. | Same as `show`; ExtraDock 4 has no separate automatic policy input. |

Use `automatic` rather than `show` for "this dock belongs to the current workspace" so autohide docks are not pinned on screen. That is what DockFlow presets send for visible docks, with `hide` for the rest.

Outcomes: `notFound` means no dock has that ID; `disabled` (ExtraDock 5) means the dock exists but is disabled and has no runtime presence; `unavailable` means the dock temporarily cannot be commanded (ExtraDock 5 while its screens reconcile, ExtraDock 4 while the user is dragging that dock); `rejected` covers any other provider refusal, including ExtraDock 5's closed license admission. ExtraDock 5 returns the resolved visibility after each command. ExtraDock 4 applies the command through its main-thread settings service after replying, so `isVisible` in its outcome is the requested target, not a resolved observation; reconcile with the next snapshot or event. Version 1 has no completion receipt or exactly-once guarantee. Do not replay a request after timeout, disconnect or cancellation.

Read-only pairing must work. Show visibility control and live updates as optional permissions and disable the associated features when absent. Generated `ExtraDockDocksAPI.actions[actionID]` gives the scope; the control action ID (`extradock.docks.visibility`) and its scope (`extradock.docks.control`) are deliberately different strings.

## Connection lifecycle

1. Own one consumer `IntegrationStore(persistence: CredentialStore(service: ...))` with a stable service specific to your app's consumer role. Reload it at startup. Keep app-level pairing, resolver, session and event task ownership; closing Settings must not silently disable automation.
2. In your app's ExtraDock library entry, guide the user to ExtraDock → Settings → Integrations → Talk (ExtraDock 5) or Talk Integration (ExtraDock 4) → Connect an App → Start Pairing. ExtraDock freezes the selected permissions for one attempt, at most five minutes. In your app choose Discover for the intended generation, then Connect. Forward incoming setup URLs to `PairingDiscovery` and endpoint replies to `EndpointResolver`.
3. Show the full verification code in your app and ExtraDock. The user compares both codes and explicitly approves scopes in ExtraDock's consent panel. Cancel, denial and expiry end that attempt. A new attempt needs a new explicit Start Pairing action. Labels do not establish publisher identity.
4. Validate the returned provider hint is one of the two ExtraDock bundle IDs you targeted, the read scope exists, and granted scopes are a subset of the pinned contract. Save the `PairingRecord` through the protected consumer store, keyed by provider bundle ID. Save success and connection success are separate states; a failed consumer save can leave a provider-only grant needing explicit cleanup in ExtraDock.
5. Resolve a fresh endpoint from the saved record and chosen installation, connect the generated client for authenticated contract negotiation, then read or subscribe according to saved scopes. Subsequent permitted automation reuses saved consent. Pairing mode is unnecessary for reconnect, restart or cold provider launch. Note that `EndpointResolver.resolve` launches ExtraDock when it is not running; decide whether background refreshes may do that or only an explicit user Connect.
6. Close/cancel on Disconnect while keeping the saved grant. Forget closes the connection and removes only your app's saved copy; it does not revoke ExtraDock's grant. ExtraDock's Revoke Access stops that grant's sessions and persists removal. Changing permissions requires fresh consent and a fresh credential replacing that grant.

Use the [portable pairing reference](../../Skills/talk-integrations/references/pairing.md) and [lifecycle reference](../../Skills/talk-integrations/references/lifecycle.md) for exact SDK API wiring, URL buffering, cancellation, storage recovery and replacement ordering.

## Typed implementation

The [compile-checked consumer recipe](Examples/ExtraDockRecipe.swift) imports only `Talk` and the public `ExtraDockTalkContract` package. It includes saved reconnect for either generation, scope-based required capabilities, a single bounded visibility request, a preset-style desired-state helper, initial subscription and typed event decoding. Its functions are primitives for your app-owned coordinator; supply the matching saved record/client, own/cancel tasks, maintain generation/revision guards and add real discovery/consent UI from the lifecycle references.

Add the copied package's `ExtraDockTalkContract` library to your app, alongside Talk. No ExtraDock module, App Group, copied generated Swift or private repository URL is needed. Generated Swift comes from the public JSON during the build; do not hand-edit it. If your build cannot use SwiftPM plugins, use `TalkClientGenerator` to emit the same types and verify regeneration before release.

For a read-only feature call `snapshot()` after `connectExtraDock`. Wire your own deliberate trigger to `setExtraDockVisibility` only when the saved control permission exists, send one complete desired state per user action (`extraDockDesiredState(visible:hidden:)`), present per-dock outcomes and refresh state after uncertain delivery. Run the reproducible external build from the SDK checkout:

```sh
python3 Scripts/validate-public-integrations.py
```

This compiles an isolated consumer from the public schema and exact recipe, with the public SDK source as a local dependency override. It never reads ExtraDock or DockFlow source, signs/launches apps, pairs, or changes a dock. [Authoring guidance](../../Docs/INTEGRATION-GUIDE-AUTHORING.md) describes provider export and compatibility checks.

## Errors and recovery

| Signal | Consumer behavior |
| --- | --- |
| `pairingRequired` | Offer explicit setup for the missing generation; do not start provider pairing automatically. |
| `permissionDenied` | Explain the missing permission or denied request; let the user intentionally replace permissions in ExtraDock. Do not repeatedly prompt. |
| `ambiguousProvider`, `unavailable` | Keep the saved grant; resolve installation/running-copy ambiguity for that generation or open/update ExtraDock, then retry connection. |
| `invitationExpired` | Clear the transient candidate/code; repeat explicit Start Pairing in ExtraDock and discovery. |
| `timedOut`, `disconnected` after a visibility request | Outcome unknown; some docks may already have changed. Reconnect/read current state without replaying the request. An endpoint timeout after revocation is not proof of a successful revoke. |
| `eventOverflow` or normal event-stream completion | Mark disconnected/stale, close the session and obtain a fresh subscription snapshot on reconnect. |
| Contract incompatibility / `unsupportedVersion`, `unknownAction` | Offer an app update or disable that feature. Never invent a fallback action or bypass negotiation. |
| `invalidMessage` from `setVisibility` | Your request had zero or more than 64 changes; fix the caller instead of retrying. |
| `busy` | Stop overlapping work; explain the temporary limit. A delayed new user action is different from automatic replay. |
| `credentialConfiguration`, `credentialLocked`, `credentialStorage`, `credentialOperationPending` | Follow protected-store recovery; freeze writes until explicit reload/recovery. Do not use plaintext or change groups/identity to hide the failure. |
| `invalidFrame`, `invalidMessage` on a response | Close the session and report an incompatible/invalid response. Keep user data out of logs. |

Per-dock `notFound`, `disabled`, `unavailable` and `rejected` outcomes are normal results, not transport errors: show them per dock, refresh the dock list, and let the user decide. Snapshot/event data contains user-chosen dock names and file/app paths. Keep payloads and credentials out of telemetry and diagnostics; record only stable error codes, counts and synthetic validation observations.

## Integration experience

Use a dedicated **Talk Integrations** settings tab. In your consumer app, **Apps I control** contains the developer-defined ExtraDock library card with the feature it unlocks, one availability/access row per generation (Not found, Installed, Installed · running, Access saved, Connected), granted permissions, Discover → Connect for pairing, and Connect, Disconnect and Forget Connection for a saved grant. This library lists apps whose API your app actually implements; arbitrary discovery must not fabricate a working feature.

In ExtraDock, **Apps with access** (Settings → Integrations → Talk) lists generic independent grants regardless of the consumer's name, with the user's label, permissions, saved/listener state, Change Permissions and Revoke Access. Labels remain identified as user-entered/unverified. Neither generation needs a new app release or a consumer-specific panel for each incoming app.

If your app also provides a Talk contract, keep the two directions independent: a connection in one direction does not authorize the reverse direction. Separate Connected, Saved but disconnected, Pairing/consent pending and Recovery required. Read-only access is useful; Disconnect, Forget and Revoke have different effects. Follow the [SDK integration UX specification](../../Docs/INTEGRATION-UX.md).

## Validation evidence

| Check | Evidence / limit |
| --- | --- |
| Public contract provenance | Copied from the ExtraDock 5 canonical contract package on 2026-09-12 and compared byte-for-byte with the ExtraDock 4 and DockFlow pinned copies. Contract `1.0.0`; hash above. `TalkContractChecker` reports the DockFlow consumer copy compatible with both provider exports. No private app source is needed to generate/use it. |
| Public package and recipe | `Scripts/validate-public-integrations.py` generates/types/builds an isolated consumer from this package and recipe using only public artifacts. This is compile evidence, not installed-app evidence. |
| Provider bundles | Locally built ExtraDock 4 (Debug), ExtraDock 5 (Debug and Release) and DockFlow (Debug) bundles passed the skill's read-only preflight on macOS 26.2 arm64 with Apple Development signing: bundle identity, `talk-spike-provider` scheme, Apple-anchored signature, app-specific Keychain group, embedded `Contract.talk.json` matching this hash, and client-to-provider compatibility. |
| Provider unit tests | Snapshot mapping, action-to-command mapping and bounds are covered by unit tests in both provider repositories and the DockFlow consumer's transport routing tests. |
| Signed real-app runtime | **NOT RUN.** Discovery, code comparison, consent, saved reconnect, live visibility changes, event delivery, cold launch, revocation and forgetting have not yet been exercised between signed ExtraDock and DockFlow builds. The first ExtraDock beta carrying the provider is intended for that pass. |
| Platform/distribution | The SDK/consumer package targets macOS 12.4; ExtraDock 5 requires macOS 26 and ExtraDock 4 requires macOS 12.4. Declared targets and local Apple Development evidence do not qualify every OS, CPU, team, distribution/update route or security boundary. Talk remains beta. |

Before shipping, run actual-app denial/cancellation, read-only use, optional permissions, ordinary automation, reconnect after restart, revocation, uncertain mutation recovery and cleanup of only the test grant, against each generation you support. Record PASS/FAIL/NOT RUN independently. Do not replace product validation with the guide checker.

## Maintenance and support

The ExtraDock 5 repository owns the wire schema (`Packages/ExtraDockTalkContract`); ExtraDock 4 and DockFlow pin byte-identical copies, and this public package mirrors the same JSON. Consumers pin a reviewed guide version and contract hash. Changes to action IDs, scopes, mutation classification or DTOs require an explicit compatibility review across both providers; never silently replace the pinned JSON from discovery metadata.

Run `TalkContractChecker` with the old consumer contract first and the new provider export second, for each provider generation. Update schema, metadata, guide semantics and recipe in the same reviewed change, then regenerate and recompile. Increment `guideVersion` for guide/recipe changes; increment `contractVersion` only for actual API changes. These are independent of Talk SDK and ExtraDock app versions.

For SDK/public guide issues use the [Talk repository](https://github.com/AppitStudio/Talk.swift). Use private vulnerability reporting for security concerns. Follow [contributing](../../CONTRIBUTING.md) and [security guidance](../../SECURITY.md); include synthetic reproduction steps, versions and stable errors, never a pairing record or a user's dock inventory. This public guide, contract package and example are covered by the repository's [MIT License](../../LICENSE). ExtraDock's separate application license is unchanged.
