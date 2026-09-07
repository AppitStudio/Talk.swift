# Provider and consumer lifecycle

Default to [discoverable pairing](pairing.md) for new app integrations. The checked-out SDK examples demonstrate manual pairing and reusable lifecycle wiring: `Examples/Studio/Sources/StudioModel.swift`, both app delegates, `Examples/Automator/Sources/AutomatorModel.swift` and `AutomatorSession.swift`. Adapt them; do not copy their bundle IDs, domain or signing configuration. The skill's starter assets are compilable integration primitives, not finished apps or an automatic consent UI.

## Provider startup and handlers

Own one stable `IntegrationStore` and `TalkProvider` for the app's provider role. Initialize with the generated schema, handler, and subscription action if events are needed. At app startup call `try await provider.restore()`; then inspect `provider.integrations()`. Individual listener activation can fail while restoration returns successfully: a row must be `.ready`, not merely present.

Register each generated action ID in the handler. Decode input, validate domain values, check cancellation before side effects, update actor-owned state, and return the declared output. For subscription return the initial snapshot. Publish only declared events with the generated event ID. The runtime handles per-call scope checking, schema shapes, snapshot/event ordering and bounded queues.

Maintain app-level session ID and monotonic revision in snapshots when events and responses can race. Snapshot reads and mutations should have a consistent actor boundary. Do not move expensive synchronous work onto the main actor just because its wrapper is async. Guard reentrant connect/pair/revoke operations with explicit state; actor isolation alone does not serialize work across awaits.

## Manual invitations (alternative)

1. The provider lets the user choose a label and scopes, freezes those values for this invitation, and creates/retains a **new** `PairingHost`. A started host cannot be reused. Call `start(providerBundleID:approve:)` and show `invitation.code()` through direct copy/secure UI. It lasts at most five minutes and is one-use. Retain it only in memory and clear presentation at expiry/cancel/consumption.
2. The consumer parses protected input with `PairingInvitation.parse`, clears the field, and calls `PairingClient.pair(using:)`. Keep and cancel this operation when the pairing UI is cancelled. Do not print the code, raw record, or invitation error input.
3. Inside the provider approval closure, show an explicit decision for the frozen label/scopes. Display names are unverified labels, not authenticated identities. Never preapprove just because a peer knows a code, matches an allowlist or advertises a contract.
4. Suspend consent with a cancellation-aware bounded stream (see `StudioModel.authorizeIntegration`). Consumer disconnect cancels this closure; dismiss pending UI and finish its continuation. Cancellation/rejection before approval must not create a grant.
5. After approval, check cancellation, create a fresh `PairingCredential()` and `PairingRecord(credential:providerBundleID:scopes:replacesID:label:)`, then `try await provider.approve(record)`. Return that same record from the closure only on success. Refresh rows/endpoints on both success and failure.
6. The consumer validates required/known scopes and expected provider routing hint, then `try await consumerStore.insert(record)` after startup `reload()`. Keep one session per saved record. Save success and connect success are distinct: a connection failure does not erase a saved grant.

Only the visible consent UI calls the starter's `approveAfterConsent`. Do not wire it to launch or invitation creation. Stop the pairing host and cancel its owner task on cancellation/expiry/teardown; do not stop it inside the approval closure before the durable record can be returned to the consumer.

Pairing is not a distributed transaction. The provider may save before consumer persistence/transport fails. Show the resulting provider row and let the user revoke that test grant and pair again. Do not repeatedly create grants or bypass an unresolved write to hide a partial result.

## Permission replacement and management

For the selected integration, start a fresh discoverable mode and consent flow (or a manual invitation if explicitly chosen) with new scopes and `replacesID` equal to the selected old credential ID. Generate a fresh credential. `provider.approve` stops the old listener, persists replacement and activates the new grant; on failure the old row may remain stopped pending recovery. Pre-approval rejection preserves the old grant. Other grants stay independent.

The consumer closes the old session before inserting the received replacement and then rebuilds that session. Never silently edit scopes on a stored record. Choose scopes from generated **action-to-scope mapping**, not action constant spelling.

Provide per-row status, scopes, connect/disconnect, provider revoke, and consumer forget controls. `provider.revoke(id)` removes the endpoint and cancels active sessions before durable removal; on persistence failure show `.revocationPending`, not durable success. Consumer forget closes the session and removes only its local record. It cannot prove provider revocation.

## Saved endpoint discovery and actual automation

Use one retained `EndpointResolver` and forward consumer URLs to it. Resolve one installation and a fresh port for each new transport (see the starter's `connectSaved`). Pass provider URLs to `EndpointResolver.reply` with live endpoints. For an open provider using Talk `0.1.0-beta.2` or later, use its default generic callback policy; the original `0.1.0-beta.1` requires an explicit list and needs an upgrade to beta.2 or later to accept unknown consumers. Match setup and reconnect policy; see [pairing](pairing.md). An explicit consumer allowlist is only a deliberate closed-product restriction, not publisher authentication. Queue a bounded number while restoration is in progress. Do not use display metadata as trust.

Create `TalkClient(port:credential:)`, wrap it in the generated client and call its `connect()` for authenticated negotiation. For read-only grants use the read method; only call subscribe if that scope is saved. Optional capability subsets must include everything the current workflow needs; scope possession does not make an incompatible method available.

Wire the user's actual automation trigger to the generated method. Prevent overlapping trigger execution when domain semantics require it. A new user action may establish a connection **before** sending once. After uncertain delivery do not retry that action; refresh/reconcile state and let the user decide a new action.

Keep one owned iterator over `transport.events` for every connected session, including read-only grants: the stream also finishes when the transport closes. This local observation sends no subscription action or polling request. Obtain the initial snapshot with subscribe only when the saved grant permits it; otherwise use the read method. Decode/apply event payloads only for the permitted event feed. Do not attach a second iterator just for closure. The starter's `runSession` demonstrates both paths.

Apply matching-session revisions monotonically; accept a new provider session only from the current connection. Use a generation token or equivalent to reject callbacks from replaced connections. Treat normal stream completion and errors as disconnection. Distinguish explicit user Disconnect from remote closure; both end the live session while saved access remains. Internal teardown during pairing/reload must not overwrite that operation’s guidance with a stale “Connected” message.

Cancel event/operation tasks and close transports on disconnect, replacement and teardown. Cancel in-flight connection work so it cannot later resurrect a closed session. Retain cancellation handles for unstructured tasks; a view disappearing must not destroy an app-level provider used by other scenes. Explicit app shutdown uses `provider.stop()` and the active pairing host’s `stop()` where the lifecycle permits asynchronous cleanup; process exit alone is not a test of graceful shutdown.

## Recovery

After protected write failure, freeze mutations. `IntegrationStore` does this internally; reflect it in the UI. A timeout does not cancel Security's underlying operation. Explicit `reload()` once it settles recovers consumer state; close old sessions before rebuilding. Provider `restore()` reloads the actual archive and restarts stored listeners, disconnecting existing sessions. Inspect restored rows, including potentially still-stored revoked grants; do not declare durable revocation until removal and reload are verified.

Maintain the sole protected backend. Use stable error codes for recovery messages; see [validation](validation.md). Never reset all user grants, change the access group, or repeatedly prompt/loop on failure to make an integration appear healthy.
