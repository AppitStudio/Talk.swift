# Discoverable pairing: Start Pairing → Discover → Connect

Use this as the default for new integrations on Talk `0.1.0-beta.2`. Manual invitations remain an explicit alternative; the native Studio/Automator examples still demonstrate that alternative. Read the SDK’s `Docs/DISCOVERABLE-PAIRING.md` for protocol details. The skill starter supplies approval, grant-save and saved-client primitives; the host app must add the pairing service and visible consent UI described here.

## App-owned state and routing

| Role | Retained SDK objects | Incoming URL handling |
| --- | --- | --- |
| Provider | `TalkProvider`, `DiscoverablePairingHost`, one `IntegrationStore` | Forward to `pairingHost.receive(_:)` and reply to saved endpoint requests using `EndpointResolver.reply` with current endpoints. |
| Consumer | `PairingDiscovery`, `EndpointResolver`, one `IntegrationStore` | Forward to both `discovery.receive(_:)` and `resolver.receive(_:)`. |

For an open provider on Talk `0.1.0-beta.2` or later, also omit the optional allowlist in `EndpointResolver.reply`; setup and saved reconnect must use the same policy. Explicit lists remain supported, but never construct a purported trusted list from a request callback field. The SDK validates callback shape and the unique running receiver; paired TLS and scoped consent remain the authority.

Use the fixed `talk-spike-provider` and `talk-spike-consumer` schemes alongside the app’s existing schemes. Buffer a bounded number of cold-launch URLs until normal startup/storage restoration completes. App-owned services outlive individual settings views. Do not start pairing from launch, URL receipt, discovery, reconnect, or an automatic retry.

Keep distinct UI states for idle, discoverable, discovering, candidate selected, awaiting consent, saving and saved/connected. `isDiscoverable == false` can mean the single attempt was consumed while consent is still pending; it does not mean the host is ready to restart. Keep an active-mode/generation guard until teardown. Disable conflicting permission, replacement, reload and pairing actions across awaits.

The beta.2 host consumes its discovery session before listener/TLS setup and does not expose a structured setup-failure callback. A countdown alone therefore cannot prove it is still accepting attempts. Distinguish the setup deadline from readiness, keep Cancel usable, and describe an uncertain setup phase without claiming another client can connect. If an attempt times out before consent, use explicit Cancel → Start Pairing → fresh Discover → Connect; do not automatically reuse a candidate or infer that no grant was saved. A later successful retry does not establish the cause of the original timeout.

## Provider: Start Pairing and consent

1. On the user’s Start Pairing action, freeze the label, exact scopes and optional selected replacement credential ID. Stop any previous completed/cancelled host before starting another mode; serialize stop/start so concurrent UI actions cannot replace each other.
2. In Talk `0.1.0-beta.2`, call `start(providerBundleID:lifetime:approve:)` with the default generic routing policy. `0.1.0-beta.1` instead requires an explicit `allowedCallbackBundleIDs` set; that older closed-provider API cannot satisfy unknown-consumer discovery. Upgrade to `0.1.0-beta.2` or later before promising open integrations. Keep an explicit list only for a deliberately closed product policy; it is routing, not publisher authentication. The returned `Date` is the expiry to display; the default and maximum lifetime are 300 seconds. Show Cancel Pairing and a countdown. An optional shortcut may open the consumer’s own settings URL; that URL must not carry a secret or grant.
3. The closure receives `DiscoverablePairingHost.Request`. Display its full `verificationCode` alongside the frozen scopes. `consumerBundleID` is an untrusted routing label. Require a fresh, initially unchecked “The code matches in both apps” checkbox; disable approval and its keyboard shortcut until checked. Do not infer a match from the allowlist or auto-confirm it in the app.
4. Await the visible decision with cancellation-aware UI. Deny or window close throws `TalkError.permissionDenied`; consumer disconnect, provider Cancel, expiry or shutdown must dismiss consent and finish its waiting continuation. Before approval, check cancellation and the current mode generation.
5. Create a fresh `PairingCredential` and `PairingRecord` with the frozen scopes, provider bundle hint, label and `replacesID`. Call `TalkProvider.approve(record)` and return the same record only after save succeeds. The starter’s `approveAfterConsent` supplies this primitive. Keep the host alive through response delivery; do not stop it inside the successful approval closure.
6. Cancel calls `await pairingHost.stop()`. One valid connection attempt consumes the mode, even if denied or disconnected. Clear transient presentation on completion/cancel/expiry; another attempt requires another explicit Start Pairing action.

## Consumer: Discover and Connect

1. On Discover, choose an installed provider URL through an explicit installation policy. `ProviderDiscovery.installed()` returns installation/contract hints; it does not prove pairing mode or publisher identity. Do not pick an arbitrary duplicate. Probe the selected app with `discover(applicationURL:providerBundleID:callbackBundleID:)` and retain the returned `Candidate` only in memory.
2. Discovery does not enable provider pairing. An unavailable, older or non-pairing provider, or ambiguous callback receiver, can time out after ten seconds. Tell the user to open/update the provider, start pairing and discover again. Keep Discover separate from Connect.
3. On Connect, call `connect(to:callbackBundleID:verification:)` with that candidate. Display the full comparison code from the verification callback until completion or cancellation. Codes are for comparison, not text to paste back or passwords. Expired/stale candidates require fresh discovery and, when consumed, a new provider mode.
4. Own the actual `Task<PairingRecord, Error>` (or equivalent structured task). Cancel that task from Cancel Pairing and shutdown; cancelling a wrapper waiting on an unstructured child is insufficient. If wrapped, forward cancellation with `withTaskCancellationHandler`. Guard generations after awaits so cancelled work cannot save a stale grant or resurrect a session.
5. Validate the returned provider hint, required permissions and known scope set before saving through the existing `IntegrationStore`. The starter’s `saveReceivedGrant` demonstrates this boundary. Close the old transport before replacement and remove only superseded local records after successful save. Preserve bundle IDs, storage services/access groups and contract scopes across migration from manual pairing.
6. Connect using the saved record and existing `EndpointResolver`/typed client. Saving and connecting are separate outcomes: report a saved-but-disconnected grant accurately. Saved reconnect does not require pairing mode, key exchange or another consent prompt.

## Failure and acceptance boundaries

Pairing is not a distributed transaction. If the provider saved but the consumer failed to save, show the provider-only grant and explicit recovery/revocation. Cancellation cannot undo an already persisted approval. Do not reset user stores or repeatedly generate new grants to hide failures.

Use setup-specific error messages. A denial before approval means pairing was not approved, not that an existing grant needs editing. Discovery runs no action. A pairing timeout/disconnect may require checking the provider for a newly saved grant and revoking that partial result before retrying. Do not show “a preset action may already have completed” for a path that never sent a mutation. Keep the selected operation’s recovery text in one place rather than repeating a generic error beneath it.

Keep setup/durable credentials and private keys out of URLs, logs, clipboard and fixtures. Record comparison success, not code values. Public keys and names remain untrusted hints; matching full codes binds the selected exchange, not the publisher identity.

Run the discoverable-pairing cases in [validation](validation.md), including pairing-off discovery, matching codes and approval gating, denial/cancel, saved reconnect after both-app restart and cold provider launch, revocation, and cleanup of only the test grants. SDK probes and static bundle checks cannot replace the actual signed app UI and storage checks.
