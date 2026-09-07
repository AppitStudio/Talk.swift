# Security model

Talk authenticates explicitly paired principals by possession of a high-entropy credential. It does not verify a peer's publisher from its claimed app name, bundle ID, PID or public key. Discovery, callback nonces and endpoint hints are untrusted routing data. TLS authenticates the connection independently of those hints.

## Transport and authorization

Network.framework provides TLS 1.3 mutual authentication over numeric IPv4 loopback. HKDF derives separate client/server P-256 keys; peer public keys are pinned to the paired credential. Tickets/resumption are disabled. There is no TLS downgrade, plaintext mode, external listener, daemon or cloud dependency. A holder of the shared credential can derive both role keys; do not treat roles as separate principals.

The default discoverable flow uses an explicit, expiring provider mode and ephemeral X25519 key agreement over untrusted public URL hints. Compare the full verification code in both apps before approving scopes; setup TLS alone cannot authenticate the discovery hints. The mode admits one valid exchange, lasts at most five minutes and never automatically reopens. See the [protocol and trust boundary](DISCOVERABLE-PAIRING.md#protocol-and-trust-boundary), including resource limits and denial-of-service boundaries.

Manual pairing remains an alternative: a one-use invitation, valid for at most five minutes at the provider, carries a temporary credential separate from the durable grant. Possession permits an attempt to pair; transfer it directly to the intended app and never log it. Both flows require explicit scoped consent before the provider returns a separately keyed durable record. Disconnect cancels pending consent. Scope expansion creates a new consented credential replacing the selected grant.

Every call is checked against persistent scopes, negotiated capabilities and declared input types before dispatch. Results/events are validated before delivery. Provider handlers remain responsible for domain rules and cancellation checks before side effects. A timeout/disconnect cannot prove rollback and never triggers an automatic mutation retry.

## Resource limits

Encoded frames are at most 64 KiB. JSON nesting is bounded. Each client allows 16 pending calls/writes. Each server allows eight peers and 16 calls per peer; 128 handlers are retained globally, including cancelled noncooperative handlers until they exit. Queues retain at most 64 messages/events. Request IDs are remembered for the bounded 4,096-request session.

The default request deadline is ten seconds, handler watchdog thirty seconds and socket idle deadline five minutes. Timers use monotonic uptime and pause during sleep; real sleep/wake remains a qualification lane. Overflow closes the affected session. Resubscribe for a fresh snapshot; there is no durable event replay or exactly-once guarantee.

## Protected storage

The only backend is app-specific data-protection `CredentialStore`. Apple signing and authorized provisioning are required. Every operation explicitly selects the signed application-identifier group. Items are nonsynchronizing and newly created items are `WhenUnlockedThisDeviceOnly`. Per-query no-UI policy does not change the host's global Keychain behavior. There is no migration, namespace fallback, shared group selection or plaintext storage.

The bounded IntegrationStore archive supports up to 16 independent grants. One store must own each service; independent processes/writers must not race whole archives. Unresolved mutations freeze changes until explicit recovery. Stop the provider grant first, persist removal, then confirm durable absence after reload. Consumer forgetting is a separate operation.

The retired file-based backend had an unexplained historical cross-signer disclosure and has been removed with its shim, migration and local certificate tooling. Removing source does not explain that historical event or protect retired binary/state copies. Old evidence and key owners remain outside distributed source.

## Qualification boundaries

Apple Development standard/sandbox storage tests pass for restart, changed-binary updates, direct unauthorized read/write/delete, independent app groups and owning cleanup. The tested apps belong to one developer team. A same-team app explicitly provisioned for an owner's group is authorized by that group; the SDK does not override Apple's entitlement boundary. Debuggable/compromised hosts or deliberately shared credentials are outside isolation claims.

Unrelated-team, distribution/renewal, other OS/hardware, sleep/wake and independent review remain open. See [beta readiness](BETA-READINESS.md) and [SECURITY.md](../SECURITY.md). Never include pairing offers, secrets, private signing/profile material, host state or real application data in public reports.
