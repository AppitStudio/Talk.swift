# Talk integration experience

The default for this checkout is a library with one Connect action. The new APIs
are unreleased and require both apps to adopt the same reviewed SDK revision.
Published beta.2 applications retain [legacy pairing](DISCOVERABLE-PAIRING.md).

## Open, choose, connect

Opening Talk Integrations immediately shows every integration the host implements.
Resolve installation status in the background without opening another app. Use
app icons and names, one useful sentence, and text status: Ready to connect,
Connected, Access saved, Not installed, or Update required. A Refresh control may
exist for recovery; it is never a prerequisite.

Selecting an entry reveals a short explanation and the actual permissions. Use
one primary Connect button. Open the other app in the background only after this
button. Authentication, key exchange, protected save, and connection are one
cancellable operation with a clear Connecting state. Do not show pairing codes,
countdowns, transport toggles, scope identifiers, or instructions to navigate the
other app's settings.

Recognized integrations with a pinned identity and explicit provider policy need
no second approval. A previously unrecognized authenticated app needs one simple
Allow / Don't Allow sheet listing its permissions. No code comparison is needed
because the SDK verifies the sender through macOS. Never silently approve merely
because another application is signed.

## Directions and supported features

A consumer's library lists developer-implemented features against documented
provider contracts. An installed Talk contract does not create a feature that the
host has not implemented. Keep unavailable supported entries visible with useful
Open / Update / Install guidance; no fake Connect buttons.

A provider may list known consumers and initiate the same directional grant from
its own library using `IntegrationConnectionRequest`. For example, ExtraDock's
DockFlow card can explain that DockFlow presets choose which docks appear. It
must not imply that ExtraDock gains control of DockFlow presets. Unknown incoming
consumers appear in access management after approval, without per-app code.

Both-role apps can retain **Apps I control** and **Apps with access**, but favor
the available library as the first view. Generic incoming access management must
remain reachable without a developer-only switch. Keep grants and storage for the
two roles separate.

## Permissions and management

Use concrete wording: See your docks; Show and hide your docks; Get updates when
docks change. Required permissions should say why they are needed. Read-only
access remains useful when the integration supports it. Optional permissions
must not be silently added at reconnect.

Changing permissions uses a fresh intentional connection and rotates only the
selected grant. Provider-initiated edits bind the originating request UUID,
selected scopes and replacement ID; cancellation invalidates that exact intent.
Unidentified legacy grants remain usable, but require removing the selected grant
and reconnecting to migrate permission ownership.

**Disconnect** closes a consumer session but preserves access. **Forget** removes
only the consumer's local copy. **Revoke Access** stops and removes the provider's
grant. Explain that distinction where the action is offered. Keep independent
grants and unrelated app settings intact.

## State and recovery

A persisted grant or ready provider listener means Access saved; it does not prove
a live client. Connected requires live-session evidence. Remote closure must
update the UI even for read-only sessions with no event subscription.

Unknown, failed-signature, old-version, duplicate-installation, and storage-failure
states need an actionable explanation. Preserve the selected card and its context
when Connect fails. Cancel real tasks and reject stale completions. A canceled
provider-library offer must not authorize a late returning request.

Setup can save on the provider before the consumer save fails. Report Access may
have been saved and point to that specific grant for inspection; do not retry
setup automatically. Freeze writes after uncertain protected-storage results
until explicit reload. Reserve possible-action-completion warnings for actual
mutations, and never replay a timed-out mutation.

## Native design and accessibility

Use the host's normal settings layout, native controls, keyboard navigation,
visible focus, and accessible labels. Combine status color with text. Support
long labels, scrolling at minimum window size, increased contrast and reduced
motion. Keep protocol details in optional diagnostics, not the primary flow.

## Acceptance

Exercise library discovery, both supported initiation directions, cold launch,
cancel, denial, read-only access, saved restart/reconnect, scope replacement,
revocation, duplicate copies, old-version guidance, and storage recovery. A build
or synthetic SDK test cannot establish actual-app success. Record the exact
signed builds used and clearly identify untested scenarios.

See [automatic connections](AUTOMATIC-CONNECTIONS.md) for implementation and
[beta readiness](BETA-READINESS.md) for remaining qualification.
