# Beta readiness — 6 September 2026

**Status: public development preview, not a stable release.** The native example matrix and expanded Apple Development storage checks passed on the tested Mac. Real-app integration, unrelated-team/distribution/certificate-change qualification, independent review, and broader platform testing remain incomplete. Source publication does not mark those gates complete. See [current qualification](QUALIFICATION.md) for the measured scope and preserved inconclusive results.

## macOS 12.4 deployment

The SDK, generated clients, example apps and standalone probes now target macOS 12.4. The diagnostic buffer uses an NSLock-protected container, discovery uses compatible URL APIs, and example scenes use WindowGroup with the New Window command removed. Probe elapsed timing uses Darwin’s monotonic raw clock; waits use the nanosecond Task.sleep API. No storage migration, protocol change or OS-specific fallback was added.

The full package compiles for arm64 and x86_64 with Xcode 26.2. Native execution evidence remains macOS 15.7.9 on Apple silicon. Actual macOS 12.4 execution and native Intel testing are still pending. Xcode’s bundled test harness targets macOS 14 independently of the package runtime minimum.

## Sole supported storage path

`CredentialStore` now exclusively uses the macOS data-protection Keychain. It verifies the running host's Apple signature, obtains the signed application identifier and explicitly selects that access group for every read, update, add and delete. It does not choose a shared group from entitlement ordering. Items are nonsynchronizing and created with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Per-query interaction is disabled; process-wide prompt policy is untouched. Existing retained-operation limits and unresolved-write recovery remain.

The file-based implementation has been removed completely from active source, together with its C shim, code-hash namespace policy, single-record migration, synthetic certificate tool and associated probes. Both examples use `CredentialStore`. There is no opt-in legacy path or compatibility alias. The current archive rejects obsolete single-record payloads.

The historical decoded disclosure in that removed backend remains unexplained; controlled noninteractive denials never established its cause. Frozen old source/logs/key owners remain outside source. They are not distributed, queried or migrated by the new SDK.

Apple recommends the data-protection backend and describes its entitlement-based access model in [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains). Restricted Keychain entitlements require profile authorization as described in [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles). App-group selection and the default-group hazard are documented under [kSecAttrAccessGroup](https://developer.apple.com/documentation/security/ksecattraccessgroup). Documentation supports the design; signed runtime tests establish the tested behavior.

## Current evidence

Host: macOS 15.7.9, Apple silicon, Swift 6.2.3 / Xcode 26.2.

| Check | Result and scope |
| --- | --- |
| Complete current Swift Testing suite | 65 tests / 20 suites passed; two existing opt-in workloads skipped. |
| Production unprovisioned hosts | Six checks passed: load/save/delete fail with `credentialConfiguration`, standard and sandboxed, actual ad-hoc processes. |
| Production group selection | Regression tests reject missing/wildcard/mismatched identifiers and select the app group even when a shared group is first. |
| Release compilation | Full arm64 and x86_64 builds passed; all 14 executable products declare macOS 12.4 in their Mach-O load commands. |
| macOS 12.4-targeted process probes | All four standard/sandbox combinations passed role reversal, calls, reconnect and wrong-key rejection; eight callback-routing scenarios and a short AddressSanitizer parser run passed on the current host. |
| Exact guide blocks and commands | Typecheck/export/generation/directional compatibility validation passed with the new production API. |
| Native examples | Before the macOS 12.4 scene update, all four standard/sandbox combinations passed pairing, calls/events, reconnect, restart/cold launch and durable revocation. Additional native denial/read-only/replacement checks passed. All four apps restarted empty after protected reload/cleanup. |
| Apple Development production matrix | 98 checks passed again with macOS 12.4-targeted probes on the current host, following the earlier two fresh-ID passes. Adds unrestricted copied-ID attacks and actual stored attribute checks to restart/update continuity, raw denial, independent storage and owning cleanup. |
| Sandboxed copied-ID/identity reuse | Inconclusive pre-main OS initialization stalls retained; fresh-ID successful matrix does not clear this availability case. |
| Developer ID / App Store / certificate renewal | Unverified. |
| Unrelated real Team ID | Unverified; available matching profiles belong to one team. |
| Other Macs and OS versions | Unverified for this candidate. Previous Rosetta runs do not qualify native Intel. |
| Independent security review | Required; not performed by this implementation pass. |
| Source review | The public source set includes the SDK, tools, tests, examples, guides, and integration skill. Local evidence, signing material, and internal work notes are excluded. Run `Scripts/audit-public-source.py` to check the maintained allowlist; this is not an independent security audit. |

Earlier transport/resource evidence is retained in [readiness validation](READINESS-VALIDATION.md). It covers 6.17 million calls, bounded pressure, idle, sanitizer mutations and concurrency checks within its recorded limits. Those results do not validate the new storage backend or every environment.

## Reproducible signing qualification

Run without using a signing identity to compile the actual SDK storage sources and verify unprovisioned failure only:

```sh
python3 Scripts/validate-production-credentials.py
```

For an explicitly authorized local Apple signing environment, supply a private JSON configuration outside source. Each `owner` / `other` object specifies `certificate` (existing SHA-1 identity selector), `profile` (existing provisioning profile path), and `identifier` (profile-authorized app identifier without its prefix). Prefer disposable identifiers under a wildcard development profile. The tool does not create certificates, enroll accounts, install profiles, upload, notarize, change trust or edit ACLs.

```sh
python3 Scripts/validate-production-credentials.py --fresh-identifiers --config LocalBuild/authorized-signing.private.json
```

The tool compiles the actual current SDK storage sources and retains two different owner builds and tests fresh-process restart, separate-path and in-place update, record update/reload, exact-group raw read positive control, unauthorized raw read/update/delete, default-group isolation, independent same-service storage and owning deletion observed by the updated build. Attacker raw calls do not disable process interaction and bypass the SDK identity guard. Unexpected status, missing owner control, data return or timeout fails the run. Evidence stays in a unique `LocalBuild/ProductionCredentialValidation` directory; secrets remain in memory/Keychain and are not emitted.

Fresh identifiers require a profile authorizing the appended disposable IDs; omit that flag for explicit App IDs. Optional different-team and different-certificate configuration requirements are in [current qualification](QUALIFICATION.md). Same-team independently provisioned app isolation cannot stand in for an unrelated team or a same-team app explicitly granted the owner's group. An App ID prefix is not always a Team ID. Run distribution lanes with their actual profiles, signatures and update mechanisms. Testing Apple Development does not qualify Developer ID, App Store or certificate renewal.

## External beta test matrix

Use synthetic application data until the production signing lane passes and the integration has been reviewed. Each tester records a source digest, macOS build, architecture, distribution/signing lane and sandbox combination, plus pass/fail and sanitized stable errors.

1. Verify single installation and correct metadata/callback declarations. Pair once with narrowly chosen scopes; verify allowed calls and denied scopes before every side effect.
2. Quit/reopen both apps, launch the provider from the consumer, and verify the same saved grant works without another Talk prompt. Install a legitimate update through the intended distribution lane and repeat.
3. Test another app with the same public service name, a copied bundle ID under a different signer, and unrelated Team ID. Require positive owner controls before and after denied raw reads/writes/deletes. Never approve attacker access.
4. Revoke one integration while others are active. Confirm live cancellation and durable absence after fresh restart. Exercise locked storage only in an approved test environment; confirm pending operations cannot be replayed or reported as completed.
5. Exercise actual sleep/wake during calls and pending consent, user switching, minimum macOS 12.4 and every supported OS, native Intel, moved/duplicate installs and arbitrary sandbox locations. Record uncertain mutations and reconcile state before issuing another action.
6. Test firewall/network filters and system pressure on a dedicated machine. Current transport is numeric IPv4 loopback; no IPv6 support is claimed. Do not change a tester's unrelated host settings silently.
7. Run the existing process-transport, callback-routing, load and parser harnesses. Keep failures and their exact source/build evidence; a later successful recovery does not erase them.

## Publication gates

Before declaring a stable or distribution-qualified release: qualify the intended distribution and unrelated-team lanes, review the storage and documented threat model independently, and establish a supported release/version policy. Source publication is a development preview; private reporting is described in [SECURITY.md](../SECURITY.md). Any deliberately deferred platform support must be explicitly limited in the beta's support statement.

`python3 Scripts/audit-public-source.py --stage` creates a local review copy from an allowlist. It excludes build output, profiles, certificates, local state and host-specific agent instructions. It runs bounded source-pattern checks and writes a digest manifest. It never initializes Git or publishes. A staged copy is reviewable evidence, not release approval.
