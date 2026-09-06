# Historical local hardening evidence

This is a summary of earlier experiments, not instructions for an obsolete storage backend. The original detailed notes, old source and scripts were retained outside source during removal. Use [current beta readiness](BETA-READINESS.md) and [credential lifecycle](CREDENTIAL-LIFECYCLE.md) for the supported implementation.

## Retired storage investigation

An earlier different-signer raw query decoded a synthetic pairing credential from the file-based Keychain backend. Later carefully controlled noninteractive standard/sandbox probes denied access with `errSecAuthFailed`, with positive owner controls and cleanup. Their requester-policy constraint did not establish permanent denial of an arbitrary interactive app, and the historical disclosure's cause remains unexplained.

Disposable encrypted file-based Keychain tests also exercised locked read/add/update denial, unchanged owner data after unlock, pending-operation freezing and explicit recovery. These results were specific to the retired backend. Its code, C shim, migration, code-hash namespace logic and supporting probes are now removed. No old test is presented as evidence for production data-protection storage; that backend has its own Apple-signed matrix.

No login Keychain was locked, no attacker access was approved, no private key was exported and no trust/ACL relaxation was used. Retained key-owning helpers stay outside distributed source for exact-item recovery.

## Runtime hardening retained in current source

- Cancelled sleep allocations were observed to remain until the original deadline. A controlled microprobe justified cancellable dispatch timers with prompt release, once-only resumption and cancellation races covered by tests.
- Actual descriptor checks reject FIFO/special-file metadata reads; unavailable candidates remain visible. This does not promise an absolute deadline for slow regular filesystems.
- Concurrent provider/client tests cover scoped denial, revocation, cancelled pending consent, ordered subscription/event delivery, overflow and retained noncooperative-handler limits.
- A slow-consumer validation race was fixed by waiting for a read-only response ordered behind the last event before checking the bounded queue. It was a test synchronization defect, not a larger event buffer.
- Measured pre-TLS POSIX48 failures led to a focused outgoing loopback-source-binding mitigation. See [readiness evidence](READINESS-VALIDATION.md) and [separate-process evidence](PROCESS-VALIDATION.md) for the limits; successful repeats do not identify the OS mechanism or erase failed controls.

Real login-keychain recovery, sleep/wake, broader OS/hardware and system pressure remain distinct qualification lanes. Historical artifacts are local evidence, not public source or a release guarantee.
