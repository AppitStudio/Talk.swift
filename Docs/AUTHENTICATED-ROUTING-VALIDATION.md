# Authenticated application routing validation

The code-free connection flow authenticates the sender of each setup URL using macOS Apple-event audit tokens and code signing. These checks concern the setup route, not Talk's TLS transport or protected credential store. They do not qualify a release on their own.

## Design and platform references

`AuthenticatedAppMessage.capture` must run synchronously inside the URL delegate. It accepts only the current `kInternetEventClass` / `kAEGetURL` event, requires its direct-object string to equal the supplied URL exactly, and reads `keySenderAuditTokenAttr`. There is no raw-URL, claimed bundle identifier, or PID-only authentication fallback.

Apple's SDK header `AEDataModel.h` describes `keySenderAuditTokenAttr` as read-only and containing the sender's `audit_token_t`. The public [Apple-event attribute reference](https://developer.apple.com/documentation/coreservices/apple_events/1542920-keyword_attribute_constants) exposes that attribute. In the local probes, LaunchServices forwarding preserved the originating app there; `keyActualSenderAuditToken` instead identified the system forwarding agent. The implementation uses the former.

The token is passed to [SecCodeCopyGuestWithAttributes](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)) with `kSecGuestAttributeDynamicCode` enabled. This uses kernel-backed signing data without requiring a sandboxed recipient to read another process's executable from an arbitrary directory. The SDK then performs dynamic validity checking against an Apple generic anchor, the exact signing identifier, and the exact certificate team. `kSecCSSigningInformation` is required when obtaining the team identifier. See [guest attribute keys](https://developer.apple.com/documentation/security/guest-attribute-dictionary-keys) and Apple's [code requirement language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html).

A developer-supplied `AppIdentity` pins the expected bundle and team before a consumer launches a provider. The passive installation check validates the app's on-disk signature and its bundle identifier. Both the running process and incoming response are checked again. A valid signature identifies an app; it does not authorize access to another app's data. Providers must apply their own exact integration policy or request visible consent for other authenticated apps.

`NSWorkspace` delivers setup URLs to the selected app path, with activation and running-application substitution disabled. Stable duplicate running installations are rejected. URL delivery remains a routing operation, not the trust boundary: each incoming message must independently authenticate the sender and match the pending request. No credential or pairing secret travels in a URL. The launch wait is cancellable and bounded, and waits for the running app to finish launching before sending the first request.

## Local evidence, 29 September 2026

The local host ran macOS 26.2 (25C56), arm64. Synthetic AppKit apps used an existing authorized Apple Development identity. The sandbox variants added only `com.apple.security.app-sandbox`; no Automation exception, shared Keychain group, daemon, account modification, new provisioning profile, or trust change was used. Probes contained fixed synthetic URLs and no Keychain data or integration credentials.

Scratch sources, signed app artifacts, bounded result reports, and source hashes are retained locally in `LocalBuild/authenticated-routing-20260929/` (ignored by Git). Those scripts contain the local signing configuration and are not public SDK tooling. Temporary installed bundles were unregistered and moved back to the evidence directory after each completed run. Synthetic processes terminated or were explicitly reaped by their owning harness.

The installed-app positive matrix passed all four sender/receiver sandbox combinations. Each case checked static identity, the selected running app, synchronous capture through the normal `application(_:open:)` delegate, original sender identity, and an authenticated response. Standard cold launch also passed.

Additional final-source controls passed:

- A correctly signed app completed the authenticated round trip.
- A sandboxed sender cold-launched a sandboxed receiver, waited for `isFinishedLaunching`, and completed the authenticated round trip.
- A wrong pinned team and a wrong pinned bundle identifier were denied.
- A different URL could not capture the current event's authenticated identity.
- An ad-hoc app with the copied bundle identifier launched and sent a setup URL, but the SDK rejected its identity and sent no response.
- The focused Swift Testing suite passed four tests covering requirement-input validation, absent current-event rejection, sender-token injection rejection, and invalid-token/unsigned-path denial.

## Failures retained and resulting changes

Direct Apple events addressed by PID returned `-600` from sandboxed senders. They were not adopted. The initial standard Security-framework guest lookup also failed within a sandbox; the kernel-backed dynamic-code option resolved that lookup while retaining the signature requirement.

The first Apple-signed probe denied all apps because the default signing-information flags omit the team identifier. The implementation was corrected to request `kSecCSSigningInformation`.

Sandboxed senders could not statically inspect synthetic apps stored under the development workspace's Documents directory. Moving only the disposable test installations under `/Applications` made the installed-app matrix pass. Apps placed outside sandbox-readable installation locations remain subject to the host's filesystem policy; the SDK fails closed when it cannot verify them.

One sandbox cold-start attempt did not receive a response within the scratch harness's deadline; a diagnostic rerun succeeded and showed that `NSWorkspace` had returned before `isFinishedLaunching` became true. The final route explicitly waits for that state before the first setup URL. This does not replace the host's own cold-start queue: capture the authenticated message immediately and retain the complete message while restoring stores and preparing handlers.

Failed negative-control harness attempts are also retained: one synthetic bundle identifier contained an invalid underscore, and one ad-hoc control carrying an unsupported team entitlement did not reach the intended SDK check. Neither is counted as an SDK security-denial pass. The final copied-bundle ad-hoc control reached the handler and was rejected there.

## Qualification limits

These probes validate local routing and signature checks, not a full real-app integration. The declared macOS 12.4 minimum was used for compilation; runtime behavior on macOS 12.4, other OS versions, other architectures, independent developer teams, App Store/Developer ID distribution, certificate renewal, and system sleep/wake remain separate qualification work. A compromised or deliberately cooperative authorized app is outside this identity boundary. Code-free connection must not silently fall back to unauthenticated URL claims when any check fails.
