# Credential lifecycle

Talk uses only `CredentialStore`, backed by the macOS data-protection Keychain. The host must be Apple signed and provisioned for its signed application identifier. Every read/update/add/delete explicitly selects that app-specific group; the SDK does not choose the first shared group or synthesize a group from a claimed bundle/Team ID. Security enforces profile authorization.

New items are nonsynchronizing and use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Per-query authentication UI is disabled. Routine saved-grant reconnect requires no biometric/Talk approval, while locked or inaccessible storage fails visibly. The SDK does not alter process-wide Keychain interaction settings.

Discoverable pairing changes setup UI and key agreement, not the saved-grant format. Upgrading from manual invitations preserves existing records and reconnect behavior when app identifiers, storage services and access groups stay unchanged. Pairing mode is required only for a new exchange or permission replacement. See [discoverable pairing](DISCOVERABLE-PAIRING.md).

## Archive and mutations

A single version 2 archive holds up to 16 independently keyed integration records. One `IntegrationStore` actor must own each service in the host; do not race separate whole-archive writers. Duplicate IDs, malformed records, unknown archive versions, obsolete single-record data and oversized archives are rejected. There is no compatibility migration or search for old items.

Each service retains at most one unresolved Security operation, with four retained operations per process. Blocking calls run off cooperative executors. The caller has a ten-second deadline; timeout or cancellation does not cancel the underlying system mutation. An unresolved save/delete freezes further mutations until explicit reload. No retry or alternate storage is used.

Provider revocation stops the selected integration's listener/handlers before persistence. Failure leaves `revocationPending`; inspect actual storage after the operation settles. A fresh reload may restore an old grant if deletion never committed. Consumer forgetting only removes its own copy. Scope expansion requires explicit new consent and a fresh credential replacing that integration.

## Updates and recovery

Preserve the application identifier and app-specific Keychain group through legitimate updates. Fresh-process restarts, separate-path updates and in-place updates were tested with Apple Development signing, standard and sandboxed. Credential continuity was checked using a possession proof compared only in memory. These tests do not qualify certificate renewal, Developer ID/App Store delivery, unrelated teams or arbitrary concurrent duplicate installations.

A locked/unavailable store is a recovery condition, not an empty permission list. Report `credentialLocked`, `credentialConfiguration`, `credentialStorage` or `credentialOperationPending` accurately. Never widen entitlements, allow attacker access, write plaintext or report a timed-out revocation as complete.

## Removed implementation

The old file-based Keychain backend, process-wide no-UI shim, code-hash namespaces, single-record migration, synthetic certificate generator and associated storage probes are removed from the active codebase. No exported alias or opt-in path remains. The SDK has no live deployment requiring migration.

A historical different-signer probe decoded a saved synthetic credential from that old backend. Its cause remains unproven; later controlled denials did not erase it. Frozen source/logs and owning key helpers remain outside source under `LocalBuild` for investigation/recovery. Current production storage does not query those items. Retired binaries or old Keychain items are not made safe retroactively by removing source; keep them out of beta distribution.

See [beta readiness](BETA-READINESS.md) for the signed matrix, actual results and remaining qualification. Apple's [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) and [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) describe the backend and entitlement enforcement.
