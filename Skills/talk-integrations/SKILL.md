---
name: talk-integrations
description: Add or audit end-to-end Talk.swift SDK integrations between macOS apps, from package installation and provider registration to typed contracts, pairing, persistent scoped consent, calls, events, and signed-app validation. Use for apps exposing or consuming Talk capabilities.
---

# Talk SDK integrations

Implement the requested provider, consumer, or both in the user's existing macOS apps. Finish with evidence from the actual signed apps, or precise untested checks and blockers. Compilation alone does not establish a working integration.

Talk is beta software and still needs more testing and validation. State this in the integration handoff, recommend cautious evaluation with synthetic or noncritical data, and do not claim production readiness from a successful build or static preflight.

## Establish the integration

Inspect the host's instructions, project/package configuration, app lifecycle, signing and sandbox settings, and existing integration code. Locate the user's Talk SDK checkout or resolved package source; refer to it as `TALK_SDK_ROOT` in commands. Do not assume this skill is installed inside the SDK. If needed, request its local location while inspecting the host.

Read the SDK's `Package.swift`, `Docs/INSTALLATION.md`, `Docs/INTEGRATION-GUIDE.md`, `Docs/CONTRACTS.md`, and relevant `Sources/Talk` APIs. Check `Docs/BETA-READINESS.md` for qualification limits; do not copy historical test counts into a new app's results. This skill targets the 6 September 2026 development preview: Swift tools 6.2, declared macOS 13 minimum, explicit pairing and the sole data-protection Keychain backend. If the checked-out APIs differ, adapt against that source and record the difference.

Determine which app exposes actions (provider), which calls them (consumer), their bundle IDs, the actual automation trigger, expected data/side effects, scopes, and whether live events are needed. For consumer-only work, use the provider's supplied contract; do not invent action IDs. An app can play both roles, with separate provider and consumer archives. Ask only for consequential details not supplied by code or user; continue independent setup work.

## Implementation route

1. Read [installation and registration](references/installation.md). Add the remote or local package, host capabilities, embedded provider contract and URL routing. There is no cloud registration or dashboard. Registration means a signed bundle discoverable through LaunchServices, runtime handler binding, and explicit saved grants.
2. Read [contract and generation](references/contracts.md). Define or consume the API and generate a shared contract module. Use [the starter assets](assets/Package.swift) for a new module; adapt the synthetic domain to the requested integration.
3. Read [provider and consumer lifecycle](references/lifecycle.md) for the requested roles. Implement visible first consent, saved grants, URL delivery, calls/events, reconnect, revocation and recovery. Wire the user's actual trigger and app state.
4. Read [validation and troubleshooting](references/validation.md). Run relevant builds, bundle checks and actual-app scenarios. Fix failures in scope and repeat affected checks. Distinguish pass, fail, blocked and not run.

## SDK invariants

- Persist through `IntegrationStore(persistence: CredentialStore(service: ...))`. Each app uses its own signed application-identifier access group. One store owns a service's whole archive; do not race writers across scenes, helpers or processes. Provider and consumer roles in one app should use distinct stable services.
- First provider consent grants exactly selected scopes. Subsequent permitted automation uses saved consent without prompts. Scope replacement requires fresh consent and a fresh credential, never an in-place scope edit.
- Names, bundle IDs, discovery metadata and callbacks are untrusted hints. Paired TLS proves possession of a key, not another app's publisher identity.
- Never put invitations or records in URLs, logs, UserDefaults, fixtures, screenshots, telemetry or source. Transfer codes directly through protected app input. Record stable errors and synthetic observations instead of credential data.
- Keep TLS, Keychain protection and resource bounds intact. Failed protected writes freeze changes until explicit recovery/reload. Consumer forgetting is not provider revocation.
- Do not replay mutations after timeout, cancellation or disconnect. Reconcile app state and report uncertainty. Events have no durable replay; resubscription starts from a fresh snapshot.
- Own pairing hosts, transports and tasks explicitly. Guard operations across actor suspension, cancel/close on teardown, and prevent old sessions from updating new UI state.

## Scope and completion

The canonical repository is `https://github.com/AppitStudio/Talk.swift.git`. Follow the host's remote dependency pin or local checkout preference; use the SDK installation guide for the `talk.swift` remote package identity. No stable release tag is declared by this skill. Do not invent a tag or distribution qualification. Integration work does not authorize publication, changing accounts, identities, profiles, system trust or Keychain policy. Use existing authorized signing configuration; continue code/build work if signing needs user action.

Deliver the changes, how to invoke the automation, the contract/scopes, validation evidence and remaining gaps. Update host task/handoff files when required. Never claim real-app success from SDK example results or a static checker.
