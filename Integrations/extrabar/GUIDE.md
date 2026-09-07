<!-- talk-integration-guide:1 -->
# ExtraBar integration guide

```json
{
  "formatVersion": 1,
  "app": "extrabar",
  "displayName": "ExtraBar",
  "guideVersion": "1.0.0",
  "updated": "2026-09-07",
  "status": "beta",
  "roles": [
    "consumer"
  ],
  "sdk": {
    "repository": "https://github.com/AppitStudio/Talk.swift.git",
    "version": "0.1.0-beta.2"
  },
  "provider": null,
  "consumes": [
    {
      "app": "dockflow",
      "guide": "../dockflow/GUIDE.md",
      "contractID": "com.appit.dockflow.presets",
      "contractVersion": "1.0.0"
    }
  ]
}
```

## Purpose and roles

ExtraBar currently consumes DockFlow's public preset API to display a preset widget and request a switch from its launcher/menu bar UI. Its developer intentionally implements that feature against the known DockFlow contract.

ExtraBar currently exposes **no Talk provider contract**. Another app cannot use this guide to call ExtraBar actions. Do not invent an `ExtraBarAPI`, URL command or inbound scope. Publishing this consumer guide describes its supported connection and is not a promise of a callable API.

## Compatibility and prerequisites

Use ExtraBar and DockFlow builds containing the Talk integration. Generic provider routing is available in Talk `0.1.0-beta.2`. Use app builds containing the updated Talk Integrations settings and provider integration; no minimum shipping app version for those app changes has been assigned. Follow the app release notes before relying on that layout.

ExtraBar and the Talk SDK target macOS 12.4; ExtraBar uses Talk `0.1.0-beta.2` with Swift tools 6.2. The DockFlow provider requires macOS 13.5, so this DockFlow integration requires macOS 13.5 or later even though ExtraBar itself can target an earlier OS. Actual minimum-OS qualification remains open. Both signed apps own their own protected saved grants. DockFlow's ordinary licensing admission governs preset mutation. See the [DockFlow compatibility section](../dockflow/GUIDE.md#compatibility-and-prerequisites) and [SDK installation](../../Docs/INSTALLATION.md).

## Public contract

No provider schema is exported by ExtraBar. The metadata therefore has `provider: null` and lists `consumer` only.

Its outgoing library currently contains [DockFlow presets](../dockflow/GUIDE.md), contract `com.appit.dockflow.presets` version `1.0.0`. Use the [public DockFlow contract package](../dockflow/Contract/Package.swift) when building your own DockFlow feature; you do not need ExtraBar's source or its private contract copy. The registry's consumed-contract link is checked against the DockFlow provider guide.

## Actions, permissions, and side effects

ExtraBar requests DockFlow's preset read permission and supports optional apply and observe permissions. The authoritative actions, method signatures, scopes, DTO meanings, side effects and result codes are in the [DockFlow guide](../dockflow/GUIDE.md#actions-permissions-and-side-effects); duplicating them here would create another source of truth.

The consumer has no inbound actions or events of its own. Reading a list in ExtraBar is distinct from choosing Apply, which asks DockFlow to change the user's Dock. A read-only grant remains usable. An accepted apply result means Applying, not completed.

## Connection lifecycle

1. Open ExtraBar → Talk Integrations → Apps I control → DockFlow. The library is a list of implemented product integrations, not every app visible to LaunchServices.
2. Open DockFlow → Talk Integrations → Apps with access, choose permissions and Start Pairing. Return to ExtraBar, Discover and Connect.
3. Compare the entire verification code in both apps and explicitly approve in DockFlow. Deny, Cancel or expiry creates no successful consumer connection; a provider-only saved grant can remain after a later delivery/save failure.
4. ExtraBar saves the grant in its own protected store, connects, and reads a snapshot or subscribes if observe permission exists. The widget reads that session; permitted calls reuse saved consent after reconnect and app restart.
5. ExtraBar Disconnect ends the session but keeps the grant. Forget removes ExtraBar's local copy. DockFlow Revoke removes authority at the provider. Replacing permissions requires fresh consent, not a settings toggle that silently edits a grant.

Services and session tasks belong to the app, not the settings view. Changing tabs must not unexpectedly stop a running widget. A saved grant can exist while the provider is unavailable; show both facts.

## Typed implementation

This guide is a supported-consumer inventory, not a library for controlling ExtraBar. To build another consumer of DockFlow, use the independent [DockFlow recipe](../dockflow/Examples/DockFlowRecipe.swift) and [public contract](../dockflow/Contract/Sources/DockFlowTalkContract/Contract.talk.json). That recipe compiles without either app's source.

If ExtraBar later publishes actions, first define/export its real provider schema, handlers, scopes and semantics. Update this same guide/template to roles `provider` and `consumer`, add the contract artifact and actual inbound lifecycle evidence, and keep the two sets of connections independent. A future provider API must not be inferred from the existing widget's internal implementation.

## Errors and recovery

Keep a saved-but-disconnected DockFlow entry when the provider is stopped or unavailable. Resolve duplicates visibly. Permission denial disables the relevant feature until explicit permission replacement. An apply timeout/disconnect means uncertain outcome: refresh/reconcile current DockFlow state and never replay automatically.

On event-stream completion or overflow, mark data stale and resubscribe after reconnect. Protected-store failures need explicit recovery/reload; never reset every grant or fall back to UserDefaults. The [DockFlow recovery table](../dockflow/GUIDE.md#errors-and-recovery) supplies stable SDK errors and app results.

## Integration experience

Use a dedicated **Talk Integrations** tab with **Apps I control** and **Apps with access** as separate directions. DockFlow belongs in Apps I control. Its card explains the preset feature, whether the app is installed, setup state, current connection state and approved permissions.

Because this ExtraBar release is consumer-only, an incoming area must plainly explain that ExtraBar currently shares no actions (or omit it until relevant). Do not show Start Pairing or fake inbound capabilities. A future provider role may add generic incoming grant rows without changing the outgoing app library. Follow the [SDK integration UX specification](../../Docs/INTEGRATION-UX.md).

## Validation evidence

The prior local signed ExtraBar/DockFlow pair passed discovery, full-code consent, read-only snapshot, saved reconnect, restart/cold provider launch, provider revocation and cleanup on macOS 15.7.9 arm64. The grant was read-only; no real preset mutation was performed in that pass. See [beta readiness](../../Docs/BETA-READINESS.md).

This guide does not claim the new generalized settings UI passed native acceptance, that unrelated consumers have been qualified, or that ExtraBar exposes an API. The public guide checker validates its consumed-contract reference, and the shared outsider recipe is compiled without ExtraBar source. Actual signing/distribution, minimum-OS, mutation/events and security qualification remain separate evidence.

## Maintenance and support

Maintain the outgoing library only when ExtraBar implements an actual feature against the linked provider's public contract. Pin and check consumer-to-provider compatibility before adopting an API change. Add future provider entries with their canonical guide reference; do not advertise discovered apps as implemented integrations.

Use the [Talk repository](https://github.com/AppitStudio/Talk.swift) for SDK/public-guide issues with synthetic reproductions. Follow its [security policy](../../SECURITY.md) for private reports and its current licensing statement. A provider role requires a new real contract and updated evidence, not a renamed consumer guide.
