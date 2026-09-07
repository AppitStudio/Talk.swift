# Talk Integrations UX

Use one **Talk Integrations** destination in the app's existing settings navigation. Inside it, separate **Apps I control** from **Apps with access**. These are two independent directions of permission, even when the same two apps participate in both.

This is the recommended host-app interface, not a SwiftUI component shipped by Talk. The SDK supplies discovery, pairing, grants and transport; the host supplies its app library, capability descriptions and native views. Use the same model in integration guides and coding-agent implementations.

## Two directions, two sources of truth

| Area | User question | Source of rows | Primary actions |
| --- | --- | --- | --- |
| Apps I control | What can this app do in other apps? | Developer-authored integrations with known typed contracts; saved consumer grants | Browse the App Library, set up, connect, inspect permissions, forget |
| Apps with access | Which apps may use this app's actions? | Generic saved provider grants, including clients unknown to the developer | Connect an app, inspect permissions, replace permissions, revoke |

**The App Library is a curated feature list.** Adding a provider requires the consumer developer to implement its contract and connect it to an actual feature. Discovery only finds installations and pairing availability for supported entries; it cannot create a new integration or make an arbitrary API safe to call. A provider being installed does not imply it is paired, compatible, available for pairing, or connected.

**Incoming access is generic.** A provider defines its contract and binds handlers once. Any compatible consumer can request access during explicit pairing mode. Do not hardcode ExtraBar, or any other consumer, in provider consent copy, permission cards or callback routing just because it was the first integration. A user-defined connection label describes a grant, not a verified app identity. Each grant is separately revocable.

For generic providers, omit `allowedCallbackBundleIDs` in `DiscoverablePairingHost.start` and `EndpointResolver.reply`. This default is available in `0.1.0-beta.2`; the earlier `0.1.0-beta.1` requires an explicit list. Upgrade both call sites together to `0.1.0-beta.2` or later. An optional explicit list can constrain a deliberately closed provider, but remains routing policy rather than authentication. Do not construct a purported trusted allowlist from a request's callback field.

## Recommended screen

```text
Talk Integrations
  Apps I control | Apps with access

Apps I control                         Apps with access
  App Library                            Connect an app
    DockFlow                               Choose permissions → Start Pairing
    Work with DockFlow presets             Compare code → Approve
    Availability + Set Up
  Saved Connections                      Saved Access
    DockFlow                               My automation app
    Connected / Not connected              Access saved
    Granted capabilities                   Allowed capabilities
    Connect · Forget                       Change Permissions · Revoke Access
```

This illustrates the two alternative panes, not a mandatory two-column layout. Default to the app's useful direction; retain stable labels and selection while refreshing. Put connection management in settings and keep the actual automation trigger in the feature that uses it. Deep links from feature errors should open the relevant direction and app entry.

A dual-role app may show the same peer in both panes with different permissions. Pairing one direction must never enable the reverse direction. Keep role-specific stores, tasks, statuses and destructive actions independent. Do not invent provider actions or a consumer library to populate an empty pane.

For the current examples:

- **ExtraBar:** Apps I control contains DockFlow in its developer-authored App Library. Its widget feature uses DockFlow's real typed contract. Apps with access explains that ExtraBar currently exposes no Talk actions.
- **DockFlow:** Apps with access manages arbitrary approved consumers of its published contract. Apps I control has an honest empty state until DockFlow implements an outgoing integration.

## Keep authorization, availability and connection separate

| Evidence | Accurate wording | Meaning |
| --- | --- | --- |
| Developer authored a supported integration | In App Library | The host implements this provider's API |
| An installation was found | Installed | Untrusted discovery found a candidate |
| No usable installation | Not found / Unavailable | Explain the next useful action; retain the library entry |
| Multiple installations or callback processes | Multiple copies found | Ask the user to resolve ambiguity; never silently choose one |
| Provider explicitly enabled setup | Ready to pair | Temporary pairing availability, not saved access |
| A grant persisted successfully | Access saved | Permission remains across restarts; no live session implied |
| Authenticated consumer connection active | Connected | A live connection exists for this direction |
| Saved grant with no live session | Not connected | Connect using saved consent; do not prompt to pair again |
| Protected write outcome unresolved | Changes paused | Explicitly reload/recover before another write; do not show success |
| Required scopes absent | Permission needed | Explain the feature and use fresh provider consent for replacement |

Use a small text status with an optional icon. Color, arrows or green dots alone cannot convey direction or state. Do not map provider `IntegrationStatus.ready` to “Online”: it describes a usable saved record. Do not show “Verified app” based on a name, icon, bundle ID, callback or contract match.

## Setup and consent

1. From the outgoing App Library, **Set Up** explains which provider to open and which capability the feature needs. Do not trigger actions while browsing.
2. In the provider's Apps with access pane, **Connect an app** exposes narrow permission choices and an optional descriptive connection label. **Start Pairing** is an explicit user action. Freeze those choices for the attempt.
3. Show the pairing expiry and **Cancel Pairing**. Discovering or opening settings must never turn pairing on. Pairing mode accepts one valid attempt and lasts at most five minutes.
4. The consumer chooses **Discover**, then **Connect** on the intended supported installation. Show the entire verification code in both apps, readable and selectable for accessibility. Do not put it in logs, telemetry or screenshots retained as evidence.
5. The provider presents a separate consent view: what the other app is asking to do, what can change, and the full comparison code. Require the user to confirm the complete code matches before enabling **Approve**. **Deny** remains obvious and usable. A code comparison binds the setup session; it is not publisher verification.
6. Report **Access saved** only when persistence succeeds. Subsequent allowed automation reconnects using the saved grant with pairing mode off and no new approval prompt. Dismissal, cancellation, denial and expiry must clear owned setup state.

Use plain descriptions such as “Read presets” and “Apply presets.” Keep raw scope IDs and contract versions in a secondary technical disclosure when useful; the consent decision should be understandable without them. Group permissions by purpose only when every member remains clear. Read access may expose user data; do not imply it is automatically harmless.

Never display a newly requested name as OS-verified identity. Prefer a neutral heading such as “Allow this app to use DockFlow?” with the routing label in a secondary disclosure and clear code-comparison instructions. Preserve the same honesty in saved connection labels.

## Connection management and recovery

- **Connect** uses the saved grant. Closing a live consumer session does not remove permission. Do not call that action Revoke.
- **Forget Connection** removes the consumer's saved copy. Explain that removing access in the provider is a separate action; forgetting cannot revoke the provider's credential.
- **Revoke Access** is a provider action for one grant. Stop that grant's active sessions and persist removal. Report uncertainty honestly if protected storage fails.
- **Change Permissions** starts fresh consent and rotates the credential. Do not silently edit scopes or grant more privileges when reconnecting.
- Keep reconnect single-attempt or explicitly user-owned. A failed mutation may already have happened: show an uncertain result, refresh relevant state and let the user decide what to do next. Never automatically replay the action.
- Following an event interruption, obtain a new snapshot before resuming live state. Do not claim events that happened offline were replayed.
- Keep pairing and connection state in an app-owned service rather than a transient settings view. Cancel view-owned discovery work on dismissal; do not accidentally destroy persistent authorization or a legitimate feature-owned session when switching panes.

Explain the consequence in the confirmation for revocation or forgetting, name the selected grant, and keep other grants untouched. Routine refreshes, reads and saved reconnect do not need an extra confirmation.

## Native design and accessibility

Use the host's existing settings/sidebar pattern and native tab or segmented controls for the two related panes. Group controls so an action affects only its own direction. Provide concise descriptive labels, keyboard access, visible focus and predictable selection. This applies Apple's guidance on [settings](https://developer.apple.com/design/human-interface-guidelines/settings) and [tab views](https://developer.apple.com/design/human-interface-guidelines/tab-views) to Talk's two independent roles.

Use actual permission text, not unexplained SDK terms. Accommodate long connection labels and localization; expose a complete accessible label when text is visually truncated. Support scrolling at the minimum window size, VoiceOver reading order, increased contrast and reduced motion. Pairing expiry must not move or hide the consent controls. Announce meaningful status changes without announcing every countdown tick.

## Acceptance evidence

Record the changed app/build and actual results. At minimum, inspect each role and empty state, then exercise setup/cancel/deny, full-code approval, allowed and denied scopes, saved reconnect, both-app restart, cold provider launch, permission replacement, revocation and consumer forgetting. Verify old grants remain readable after UI changes.

A generalized provider additionally needs a compatible consumer whose bundle ID was absent from its source: pair, save, reconnect with pairing off, and revoke. Include malformed and ambiguous routing controls. A compiling screen or an allowlist unit test alone does not establish that signed-app flow. Do not close release qualification from this UX work; see [beta readiness](BETA-READINESS.md).

Read [discoverable pairing](DISCOVERABLE-PAIRING.md), [credential lifecycle](CREDENTIAL-LIFECYCLE.md) and [public app guides](../Integrations/README.md) for the implementation contracts behind the interface.
