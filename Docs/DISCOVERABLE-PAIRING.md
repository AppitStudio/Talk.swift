# Discoverable pairing

Discoverable pairing was introduced in **0.1.0-beta.1**; use **0.1.0-beta.2** for the generic callback default. Users can pair two local apps without copying a secret:

1. In the provider, select permissions and click **Start Pairing**.
2. In the consumer, **Discover** the provider, then click **Connect**.
3. Compare the entire verification code displayed in both apps. The provider's consent UI must require explicit confirmation that the codes match before granting the selected scopes.
4. Save the received grant in each app's own `IntegrationStore`. Subsequent allowed automation uses that grant without pairing mode or another prompt.

Talk remains beta. Validate the complete flow in your actual signed apps and use synthetic or noncritical data during evaluation. Automatic publisher verification is not provided.

## Provider wiring

Retain a `DiscoverablePairingHost` in a main-actor app service. Only the user's Start Pairing action calls `start(providerBundleID:allowedCallbackBundleIDs:lifetime:approve:)`. The default lifetime is 300 seconds, which is also the maximum. Freeze the chosen scopes, label and optional replacement ID for that mode.

`0.1.0-beta.2` makes `allowedCallbackBundleIDs` optional, defaulting to `nil`: any syntactically valid callback with exactly one running receiver may receive public setup hints. Omit it for a provider that should accept future compatible consumers without code changes. Omit it on `EndpointResolver.reply` as well so their saved connections can reconnect. The earlier `0.1.0-beta.1` requires an explicit list; upgrade both call sites to `0.1.0-beta.2` or later for a generic provider. An explicitly supplied nonempty set still limits routing and is bounded to 64 valid identifiers. It is not an identity check or an authorization grant.

Use the [Talk Integrations UX](INTEGRATION-UX.md) to separate a consumer's developer-authored App Library from a provider's generic incoming access. Do not infer an outgoing feature from a discovered app, or enable reverse-direction access when pairing.

The approval closure receives a `DiscoverablePairingHost.Request` with an untrusted `consumerBundleID` routing label and a `verificationCode`. Present that code in the provider's visible consent UI. Disable approval until the user explicitly confirms it matches the consumer. On approval, check task cancellation and the current mode generation, create a fresh `PairingCredential` and `PairingRecord` with exactly the frozen scopes, call `TalkProvider.approve`, and return that record. Denial throws `TalkError.permissionDenied`.

Route incoming `talk-spike-provider` URLs to `pairingHost.receive(_:)` as well as the existing `EndpointResolver.reply` handling for saved connections. Calling `receive` never enables pairing. `isDiscoverable` becomes false after expiry, stop, or one valid connection attempt, before any asynchronous listener startup. The mode cannot be silently reused after failure or denial; stop it and require another user action to start again.

Retain the host through consent and response delivery. Call `await pairingHost.stop()` on Cancel, shutdown, or before a new mode. It invalidates discovery immediately, cancels startup and pending consent, and closes the setup socket. Do not stop it inside a successful approval closure: that would close the socket before the record is delivered. The underlying setup listener closes after its single attempt; an outer expiry timer also bounds its lifetime.

## Consumer wiring

Retain a `PairingDiscovery` and route `talk-spike-consumer` URLs to its `receive(_:)`, alongside the existing endpoint resolver.

For Discover, select an application URL using your explicit installation policy and call `discover(applicationURL:providerBundleID:callbackBundleID:)`. `ProviderDiscovery.installed()` can supply installed candidates and untrusted contract metadata; probe the selected candidates, with bounded concurrency, to determine whether pairing mode is enabled. Discovery does not start pairing mode in the provider. A provider that is closed, running older code, not pairing, or has an ambiguous callback receiver will not answer; the default timeout is ten seconds. Show an actionable message to update/open the provider and enable pairing there.

For the user's Connect action, pass that candidate to `connect(to:callbackBundleID:verification:)`. Its verification callback provides the comparison code before the key-exchange request is sent. Keep it visible until consent completes or pairing is cancelled. Own and cancel the actual connection task, including forwarding parent cancellation if you wrap it in another task. A second simultaneous Connect on one discovery instance fails with `busy`.

Validate the returned record's provider hint, scopes and required permissions before saving it with the consumer's store. Close any old transport when replacing a grant. Keep current storage services, access groups, bundle IDs and scopes across this upgrade: existing records and reconnect APIs are unchanged.

## Integrating into an existing app pair

Use the [portable skill’s pairing workflow](../Skills/talk-integrations/references/pairing.md) for concrete state, URL, consent and cancellation wiring. Replace the manual invitation field/copy controls with Start Pairing, Discover, Connect and comparison UI; keep saved credentials, storage services and ordinary reconnect unchanged. Existing grants do not need to be exchanged again. Permission changes still require fresh visible consent and a new credential replacing the selected grant.

Signing and host startup remain prerequisites. Verify normal licensed startup, the signed application identifier/access group and matching provisioning before testing pairing. Reuse only authorized private build configuration; a Release build alone does not guarantee it contains the host’s required configuration. Diagnose a startup or storage failure at that layer without weakening protection.

## Protocol and trust boundary

The SDK uses existing LaunchServices URL routing, not Bonjour, shared storage, clipboard, plaintext sockets, an external listener, or a daemon. The provider and consumer must declare the existing `talk-spike-provider` and `talk-spike-consumer` schemes. Replies require a valid callback bundle ID and exactly one running consumer process; an optional explicit allowlist further restricts routing. Neither that policy nor the OS's routing proves the peer's publisher.

Discovery advertises an ephemeral X25519 public key, random mode ID and expiration. Connect supplies a new consumer public key and random request ID. CryptoKit performs X25519 agreement and HKDF-SHA256 with a length-delimited transcript binding both public keys, roles, mode/request IDs and bundle routing labels. Separate HKDF labels derive the 256-bit setup credential and a 48-bit, twelve-hex-digit verification code. The consumer fixes the advertised provider key before generating its private key/request nonce; the provider permits one valid exchange per user-started mode. Never shorten, replace, auto-accept or treat the visible code as a password.

Public URLs carry only public keys, identifiers, expiration and a loopback port. Private keys, the derived setup secret and durable credentials never appear in URLs. The derived setup credential enters the existing pinned, mutually authenticated TLS 1.3 loopback pairing flow. The durable grant uses an independently generated credential and is released only after provider approval. Setup TLS proves agreement on the exchanged keys; **the user's comparison of the entire code binds that exchange to the intended apps**. Skipping comparison loses protection against active substitution of discovery keys. A claimed app name, bundle ID or public key remains unverified publisher identity even when the codes match.

A local adversary can interfere with discovery, exhaust reply limits, or consume a pairing attempt, causing denial of service. Do not silently retry or expand the pairing window. URLs are bounded to 2 KiB, discovery retains at most four outstanding callbacks per instance, and each provider mode sends at most 32 discovery replies and attempts at most eight syntactically valid key agreements. Explicit cancellation, dates and the mode generation reject stale setup work. System-level routing/flooding and real sleep/wake still need broader qualification.

Pairing is not a distributed transaction: the provider may save before a consumer disconnects or fails to save. Revoke that provider-only grant and resolve any uncertain storage write before retrying. Cancelling cannot undo a grant already approved and persisted.

## Validation

`swift test` covers public hint validation, key/transcript binding, explicit mode gating, consent allow/deny, cancellation from each side, stale/expired modes, one-attempt use, and callback restrictions using actual loopback TLS with injected URL delivery.

`/usr/bin/python3 Scripts/validate-discoverable-pairing.py` builds disposable AppKit processes and runs real LaunchServices routing and encrypted pairing in all four standard/sandbox combinations. Verification codes pass only through anonymous test-control pipes; evidence stores match results, never codes or credentials. This does not test Keychain persistence, UI consent, or a production app's lifecycle. Validate those separately in the signed apps. The SDK's native Studio/Automator examples continue demonstrating manual invitation pairing, which remains available.

### Actual app validation

DockFlow and ExtraBar completed 21 targeted native checks on macOS 15.7.9 arm64 with locally Developer ID-signed builds: mode-off discovery rejection, explicit mode/scope freeze, full-code comparison and approval gating, denial/cancellation, a read-only saved grant and typed snapshot, saved reconnect, both-app restart, cold provider launch, revocation and cleanup. Both apps restarted with the test grant removed and pairing mode off. See [qualification](QUALIFICATION.md#discoverable-pairing-in-real-apps--7-september-2026) for the scope and preserved failures.

This pass did not exercise real preset mutations/live events, actual-app expiry/duplicate/fault injection, notarized delivery, certificate renewal, unrelated teams or other OS/hardware. Keep those distinct from the successful pairing checks.
