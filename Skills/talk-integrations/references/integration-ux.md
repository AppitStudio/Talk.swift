# Integration settings and direction

For a settings/consent UX task, read the SDK's `Docs/INTEGRATION-UX.md`. Use a dedicated **Talk Integrations** destination and distinguish the directions in user terms:

- **Apps I control:** the developer-defined outgoing app library. Each entry exists because this app implements a useful feature against that provider's documented contract. Discovery answers whether that provider is installed/available for setup; it does not create a supported feature for an arbitrary app.
- **Apps with access:** generic incoming grants for this app's published actions. Render independent rows from persisted grants/status and describe scopes from the provider contract. Unknown consumers do not need consumer-specific provider code or UI. Use the generic callback default in Talk `0.1.0-beta.2` or later; explicit fixed product lists are a deliberate restriction, not the default SDK model.

An app can support both directions. Preserve separate stores, ownership and permissions; a grant from A to B does not grant B control of A. A consumer-only app must not offer fake inbound pairing. Empty states explain the feature and a concrete next step without inventing future API support.

The app’s outgoing App Library and the SDK’s public `Integrations/` directory serve different purposes. The directory lists only apps supplying contracts. A consumer such as ExtraBar implements a library entry for DockFlow and uses DockFlow’s public guide; it does not publish its own directory entry until it supplies an API.

Distinguish installed, supported, pairing/consent pending, saved, connected, disconnected/stale and recovery required. A saved listener is not proof of an active client connection. Describe permission side effects in plain language; read-only access should be useful. Compare the full code before explicit approval. User labels and bundle names are unverified hints, not trusted publisher badges.

Connect/disconnect change a session; Forget removes the consumer's local copy; Revoke removes the provider grant. Permission expansion uses fresh consent and credential replacement. Keep mutation outcome uncertainty and unresolved protected writes visible. App-owned automation must outlive the settings view, and rows for independent grants must not overwrite each other's state.

Observe remote transport closure even when the grant is read-only; gate subscription and payload handling by scope, not closure observation. Update both headline and detail when explicitly disconnecting, losing a connection, or failing to reconnect. Explain errors in the operation’s context: discovery, consent, connection and mutation have different recovery steps. Reserve possible-action-completion warnings for a mutation that might have been delivered. A saved grant can remain after a failed connection or uncertain pairing save; avoid duplicated errors or claiming revocation from a timeout alone.

Use native controls, keyboard/focus support, VoiceOver labels, text with status indicators and reduced motion. Keep raw scopes, wire IDs and transport details in optional developer diagnostics unless they help the user decide. Test both-direction layouts and actual denial/recovery flows, not only the successful paired state.
