# Native and security qualification — 6 September 2026

The current deployment minimum is macOS 12.4. Both architecture builds are checked, but actual Monterey runtime qualification remains open. Native matrix results below were recorded on macOS 15.7.9; they do not establish behavior on 12.4.

The native example matrix below was completed before the macOS 12.4 scene update on the tested host. Security qualification has additional local evidence, but remains open for unrelated-team, distribution, certificate-change, and independent review. Real-app and broader platform qualification remain separate work. This source is published as a development preview.

Host: macOS 15.7.9 arm64, Swift 6.2.3 / Xcode 26.2. This is a bounded implementation/validation pass, not an independent security audit or a claim that all vulnerabilities are absent.

## Native example matrix

Tested the four provisioned release example bundles using the fresh `dev.talk.examples.paired` identities. Tests operated the actual apps through native controls, with disposable scene data. Pairing codes were copied directly into the consumer's secure field, never read or recorded.

| Provider | Consumer | Pair, read, mutation, event | Manual reconnect | Both apps quit; consumer cold-launches provider | Revoke, restart, attempt old grant | Cleanup, protected reload, final restart |
| --- | --- | --- | --- | --- | --- | --- |
| Standard | Standard | Pass | Pass | Pass | Pass | Empty |
| Sandboxed | Sandboxed | Pass | Pass | Pass | Pass | Empty |
| Standard | Sandboxed | Pass | Pass | Pass | Pass | Empty |
| Sandboxed | Standard | Pass | Pass | Pass | Pass | Empty |

For each combination, the consumer changed Studio to Focus using the saved permission. A manual provider change to Away reached the consumer as a live event. Quit/reopen restored the grant without another consent dialog; the consumer's Connect action launched a previously stopped provider. Revocation closed the active session. After both processes restarted, attempting the old saved grant did not connect; endpoint resolution ended with the bounded timeout and the provider had no integrations and zero authorized calls. That timeout is an observation, not a claimed authenticated `permissionDenied` response.

Additional standard-app consent checks passed:

- Deny returned a permission error; explicit protected reload showed no grant in either app.
- Read-only consent displayed only `studio.scenes.read`. The focus trigger caused no scene-selection call, and manual provider changes did not deliver events. Reload/reconnect retained the narrow scope and fetched a fresh read snapshot. Direct server rejection of out-of-scope calls/events is separately covered by the automated suite.
- Changing the permission-selection controls did not change the existing read-only grant. Replace permissions required a new code and explicit consent listing the expanded scopes. Approval replaced the single integration and allowed a subsequent scene mutation.
- Every disposable grant was revoked at its provider and forgotten at its consumer. All four protected stores were explicitly reloaded empty; a final quit/reopen of all four apps confirmed empty state and zero provider calls.

The four bundle signatures were reverified and their exact file digests retained locally. No SDK or example runtime source changed during this validation pass.

## Expanded storage checks

The production storage probe passed **98 checks**, twice with fresh disposable identities, including the final signing-team verifier. This extends the earlier 74-check matrix with copied-code-identifier/ad-hoc host checks and inspection of actual stored item attributes.

- Both standard and sandboxed owners create, load, update and delete through the production backend. Raw owner reads succeed before attacks; the same record/key possession proof survives restart, distinct binaries and in-place/separate-path updates.
- Unprovisioned SDK load/save/delete fail closed, including an ad-hoc app copying the owner's exact bundle/code identifier.
- An unrestricted copied-ID attacker, an independently entitled same-team app, and the baseline unprovisioned attacker directly query/update/delete the owner group, bypassing SDK guards. Exact-group operations return `-34018` with no data; default-group reads return `-25300`. Owner reloads confirm the record is intact after each operation.
- Raw attribute reads confirm the item's actual group, nonsynchronizing state and `WhenUnlockedThisDeviceOnly` protection without returning the credential in that check.
- Owner and separately entitled app can independently use the same public service. All four owner/other archives are deleted and observed empty, including from the updated build.
- Signing verification checks the configured certificate, identifier, Apple anchor and actual code TeamIdentifier against the profile. Team comparisons do not infer a Team ID from the App ID prefix.

New harness options preserve evidence scope:

```sh
python3 Scripts/validate-production-credentials.py --fresh-identifiers --config LocalBuild/authorized-signing.private.json
```

`--fresh-identifiers` appends a per-run/per-variant suffix to the private configuration's identifiers. Profiles must authorize those identifiers. It is suitable for the authorized wildcard development setup; do not use it with explicit distribution App IDs unless their profiles cover the generated IDs. Omit it to test explicitly configured identities. Every update within a run retains its owner's identifier and group.

An optional `update` configuration object uses the same `certificate`, `profile`, `identifier` fields as `owner`, with another authorized certificate/profile and the same application identifier/group. A successful different-certificate run records `changedCertificateContinuityQualified`. It does not claim a certificate-renewal delivery route passed merely because two certificates differ.

For unrelated-team testing, `other` must be provisioned by a genuinely different team and must also authorize the owner's bundle identifier under that team's own prefix. The harness then adds a copied-identifier, different-team app. It marks `crossTeamQualified` only after both variants and cleanup pass. Private configurations, profiles and identity selectors stay outside source.

`distributionDeliveryQualified` remains false: local packaging uses no timestamp service, notarization, upload, App Store processing or actual updater. The probe alone cannot qualify those delivery mechanisms.

## Preserved inconclusive runs

A sandboxed ad-hoc copied-ID probe exceeded its watchdog before SDK main. A controlled read-only process sample showed `_libsecinit_appsandbox` waiting on synchronous XPC and no probe main frame. Reusing the affected owner identifier then also stalled before its sandboxed load. Standard-variant checks and cleanup passed in those runs; no sandbox save was reached.

These are unresolved sandbox identity-collision/availability observations. They do not establish credential disclosure, a successful denial, or the OS root cause. No container, ACL, trust setting, entitlement enforcement or system protection was changed. The successful matrix used fresh disposable owner identities and an unrestricted copied-ID attacker. It does not erase or qualify the stalled sandboxed-copy case.

## Focused implementation review

Reviewed the active credential query/identity checks, bounded archive and pending-operation recovery, provider approval/revocation, one-use pairing/consent cancellation, server scope checks and dispatch after suspension, pinned TLS configuration and example consent integration. Existing race, wrong-key, scope-denial, parser/resource and recovery tests support these boundaries. A fresh scratch build passed **63 tests in 19 suites**, with the same two opt-in workload skips. No runtime fix was identified by this focused pass.

The trust boundary remains explicit: another app provisioned for the owner's Keychain group is authorized by macOS, including a same-team app deliberately granted that group. Names and bundle IDs are routing labels, not proof of publisher identity. A compromised/debuggable host or deliberately shared credential is outside the isolation claim.

Apple's [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) describes entitlement-based data-protection Keychain access. [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) describes restricted-entitlement authorization and the App Store's re-signing step. These support the test design; they do not replace signed runtime evidence. The runtime relies on Security enforcement, not the tooling's debug parsing of provisioning profiles.

## Remaining qualification and acceptance criteria

| Lane | Missing input | Required result |
| --- | --- | --- |
| Unrelated team | Authorized test profiles/identity from another developer team, including the copied bundle ID | Positive owner reads plus raw read/write/delete denials, independent storage and cleanup in both variants |
| Developer ID | Profiles for disposable test IDs and authorization for that distribution identity; intended updater | Stored scopes/key continuity across delivered updates; unrelated-app denials; exact signatures and actual delivery validation |
| Mac App Store | A separate authorized distribution/TestFlight/App Store test workflow | Repeat on Apple's processed delivered builds and actual updates; local Apple Distribution signing is insufficient |
| Certificate change/renewal | Two authorized certificates and profiles for the same application group, plus the intended renewal/update route | Same credential/scopes after change, raw negative controls, cleanup; distinguish certificate change from delivered renewal |
| Sandbox copied-ID availability | A controlled investigation environment and reproducible old/new identity sequence | Explain or bound the pre-main hang without modifying protections; retain every failed/inconclusive run |
| Independent review | A reviewer independent of this implementation pass | Written scope/findings covering pairing, storage, authorization, protocol and uncertainty; reproduce findings, fix and retest before closure |

The measured signing matrix used one developer team. Distribution delivery and unrelated-team lanes remain unverified. Private profiles, identity selectors, and local run artifacts are excluded from this repository; the reproducible tooling and sanitized results above describe the public evidence scope. Broader OS, hardware, and firewall qualification remains open.
