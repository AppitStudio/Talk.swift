# Integration library and automatic connections

This checkout adds authenticated local setup. It is **not included in the published
`0.1.0-beta.2` tag**. Both apps must adopt a reviewed SDK revision containing these
APIs and advertise `TalkConnectionVersion = 1` in Info.plist. Existing grants and
the older pairing APIs remain compatible.

The default experience is:

1. Open **Talk Integrations**. Supported apps appear immediately, with installation
   and update status, without launching anything or granting access.
2. Select an integration. Show a short description and its actual permissions.
3. Press **Connect**. Talk opens the selected app in the background, verifies the
   signed sender of each setup message, exchanges keys, and saves the approved
   grant through the apps' existing protected stores.

There is no Start Pairing mode, manual Discover action, invitation field, or code
comparison. An integration with explicit trust in its pinned counterpart can use
the initiating app's Connect action as consent. Other authenticated apps require
one scoped **Allow** decision in the provider. A valid signature by itself never
authorizes access.

## Discovery and developer policy

Each app defines a library of integrations it actually implements. A contract in
another installed app does not manufacture a feature in the consumer.

```swift
let identity = AppIdentity(bundleID: "com.example.Provider", teamID: "ABCDE12345")
let installation = IntegrationDiscovery.installation(for: identity, role: .provider)
```

Inspect on panel appearance and relevant workspace changes. The SDK reports
`available`, `notInstalled`, `updateRequired`, `ambiguousInstallation`, or
`unverified`, plus the installation URL when unambiguous. Discovery never launches
the app. The sole running copy is preferred, otherwise one installation directly in
`/Applications` or `~/Applications`, otherwise one registered copy. Multiple
running or canonical copies require resolution. Never silently switch away from
a selected copy whose version or signature fails validation. The signature check during Connect is repeated, so metadata is never
the trust boundary. Older installed apps should say **Update required**.

Pin the exact bundle identifier **and** signing Team ID from an official provider
integration. Never learn an allowlist from unauthenticated discovery metadata, URL
query parameters, a display name, or the first caller. A same-team check alone is
not a grant policy. The provider must limit recognized peers to their documented
scopes. Unrecognized peers need visible consent or denial.

## Capture the authenticated sender at URL delivery

Declare the existing `talk-spike-provider` and/or `talk-spike-consumer` schemes.
In `application(_:open:)`, capture the message synchronously:

```swift
for url in urls {
    let message = AuthenticatedAppMessage.capture(url)
    // Forward or queue `message` here. Do not capture after Task/await.
    if let message { connectionHost.receive(message) }
    // Saved EndpointResolver routing still consumes the ordinary URL.
}
```

`capture` verifies that the current Apple event is a GURL event whose direct object
equals that exact URL, extracts the original sender's read-only audit token, and
validates the running code's Apple-issued signature and signing identity. It fails
closed if any element is unavailable. Do not use a claimed PID or bundle ID as a
fallback. SwiftUI `.onOpenURL` work scheduled after event dispatch is too late;
bridge through the app delegate and retain the authenticated value in a bounded
cold-start queue.

LaunchServices forwards setup hints without stealing focus and preserves the
original `keySenderAuditTokenAttr`. `keyActualSenderAuditToken` identifies the
forwarding system agent and must not be substituted. Dynamic code lookup uses
`kSecGuestAttributeDynamicCode` so sandboxed receivers do not need arbitrary
filesystem access merely to authenticate the sender. Installation preflight still
needs read access to the installed app bundle.

## Provider lifecycle

After restoring the existing `TalkProvider` and its `IntegrationStore`, retain an
`IntegrationConnectionHost(providerBundleID:approve:)`. Forward captured setup
messages to `receive`. It remains available for Connect without a UI mode; it
creates an ephemeral listener only after a valid signed request. Stop it on app
shutdown and before replacing the service.

The approval callback receives:

- `consumer`: OS-verified identity, process, and installation.
- `scopes`: bounded requested scopes; require the contract's mandatory read scope
  and reject unknown or excessive scopes.
- `replacesID`: optional grant being replaced.
- `originRequestID`: optional provider-library intent to correlate with a still
  active Connect or Change Permissions action.

Apply your explicit peer policy or await visible scoped consent. Then check
cancellation, create a fresh credential, and call `TalkProvider.approve` with a
`PairingRecord` containing exactly the approved scopes and
`consumerIdentity: request.consumer.identity`. Return the same record. No secret
or durable grant belongs in a URL, log, screenshot, clipboard, or UserDefaults.

The SDK rejects a returned scope expansion, mismatched identity, wrong provider,
or wrong replacement. These return checks do not undo a provider's own side
effects; validate policy **before** persisting the grant.

Replacement requires the old grant's `consumerIdentity` to match exactly, and
rotates the credential. The SDK checks ownership before stopping the old listener.
Legacy grants with no authenticated identity continue to reconnect, but cannot
be silently claimed by a new identity; revoke that selected grant and connect
again if its permissions need migration. Unrelated grants are untouched.

## Consumer lifecycle

Retain `IntegrationConnection` alongside the existing endpoint resolver. Forward
captured messages to `receive`. The single Connect button calls:

```swift
let record = try await connection.connect(
    applicationURL: selectedInstallation,
    provider: expectedIdentity,
    consumerBundleID: ownBundleID,
    scopes: requestedScopes)
// Check required read scope and contract compatibility, then:
try await consumerStore.insert(record)
```

Own and cancel the actual task. After saving, resolve the saved endpoint and
connect the existing typed client. Keep stable credential services and Keychain
groups. Existing grants skip setup and use ordinary authenticated reconnect.
Do not resend a mutation when connection results are uncertain.

The Connect exchange authenticates the selected provider's response against the
expected identity, process, and installation. Ephemeral X25519 keys, fresh nonces,
scopes, replacement, and originating intent are bound into the key derivation.
Only public hints travel in URLs; the durable credential travels over the
one-use paired TLS connection. At most four setup sessions and 32 attempts per
120-second window are admitted per host. Completed attempt IDs cannot be replayed
within that window. Normal saved sessions use the existing resource limits.

## Connect from the provider's library

A provider can show a supported consumer entry without implying reverse access.
Its Connect button calls `IntegrationConnectionRequest.send(applicationURL:
consumer:providerBundleID:scopes:replacing:requestID:)`. Create and retain the
request UUID before sending; it returns that same UUID.

The consumer parses `IntegrationConnectionRequest.parse(message)`, checks its
pinned provider and contract, and invokes the same Connect operation, forwarding
the request's `scopes`, `replacesID`, and `id` as `originRequestID`. For replacement,
it must match the selected saved record. The provider accepts the echoed origin
only while that exact local intent is pending, with matching scopes/replacement.
Cancellation or expiry clears that intent, so a late response cannot grant access.
A normal consumer-initiated Connect has no origin UUID.

## Recovery and validation

Show Connecting, Connected only after the relevant live session succeeds, and
Access saved when only the grant/listener is known. A provider listener does not
prove an active consumer. Offer Retry for transient failures, Open/Update for old
apps, and Resolve duplicate copies when needed. Protected writes retain their
existing freeze-and-explicit-reload behavior.

Setup is not a distributed transaction. A provider may save before the consumer
saves; report that uncertainty and let users inspect/remove the specific grant.
Do not automatically repeat setup to hide partial persistence.

Test actual signed apps: both initiation directions, cold launch, cancellation,
denial, unexpected sender/team, duplicate copies, scope replacement, saved
reconnect/restart, revoked grants, and protected storage failures. SDK unit tests
and synthetic routing probes do not establish real-app or distribution readiness.
See [beta readiness](BETA-READINESS.md).

Primary API references: [sender audit token](https://developer.apple.com/documentation/coreservices/keysenderaudittokenattr),
[code lookup](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)),
and [audit-token code attribute](https://developer.apple.com/documentation/security/ksecguestattributeaudit).
