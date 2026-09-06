# Validation and troubleshooting

## Build and static preflight

Build the host's actual schemes/targets using its normal authorized local configuration. Typecheck generated clients and provider handlers, and run targeted domain/permission/lifecycle tests. For SDK changes run its applicable tests and contract pipeline. SDK tests alone are not evidence for host wiring.

The skill includes a read-only validator using Python 3, macOS `codesign`, and optionally already-built Talk tools. Set `TALK_SKILL_ROOT` to this skill directory and `TALK_TOOLS` to the SDK binary directory (obtain it with `swift build --package-path "$TALK_SDK_ROOT" --show-bin-path` after building).

```sh
python3 "$TALK_SKILL_ROOT/scripts/validate-app.py" \
  --app "$PROVIDER_APP" --bundle-id com.example.provider --role provider \
  --tools-dir "$TALK_TOOLS" --source-contract "$PROVIDER_CONTRACT" \
  --client-contract "$CONSUMER_CONTRACT"
python3 "$TALK_SKILL_ROOT/scripts/validate-app.py" \
  --app "$CONSUMER_APP" --bundle-id com.example.consumer --role consumer
```

Use actual expected bundle IDs and contract paths, not the illustrative values. `--role both` checks both schemes. The helper verifies strict Apple-anchored signature validity, signed application identifier/group consistency, required networking entitlements for sandboxed hosts, URL schemes, and provider metadata. With `--tools-dir` it validates the embedded schema. `--source-contract` compares canonical source vs embedded schema for staleness. `--client-contract` runs directional compatibility (client first). Without these options those checks are explicitly NOT RUN.

The helper only reads public bundle/signing metadata and writes temporary canonical schemas. It does not read Keychain values, dump profiles, launch/register apps, approve consent or qualify provisioning at runtime. It emits fixed check names/statuses without identities, paths, raw tool output or credential material. Exit zero means requested static checks passed, **not** that the integration works. Nonzero means a failed check or unusable input.

## Signed real-app acceptance matrix

Use synthetic app data and separate test grants. Exercise only the configurations the apps actually support; if both support sandbox/standard variants, run every intended provider × consumer combination. Record OS, architecture, build/configuration and signing lane without secrets or personal signing identifiers.

| Scenario | Observable pass condition |
| --- | --- |
| Registration and cold launch | Final installed provider appears with available manifest; consumer resolves one copy and cold-launches it to a successful TLS/typed call. |
| Explicit consent | One-use invitation reaches visible scope approval; deny/cancel/expiry do not create grants before approval. No code/credential appears in logs. |
| Allowed real trigger | User's actual trigger invokes the intended provider action and the expected app state changes once. Capture synthetic before/after state. |
| Least privilege | A read-only grant reads; a forbidden mutation/subscription returns `permissionDenied` and the provider state remains unchanged. Exercise the call path, not only disabled UI. |
| Saved consent | Repeated permitted actions and manual reconnect work without new permission prompts. Quit/reopen each app, then both, and repeat with the same saved grant. |
| Events | Initial subscription snapshot and later mutation events reach the active session in order; older revisions cannot overwrite newer results. Read-only sessions do not subscribe. |
| Disconnect/uncertainty | Disconnect or cancel an in-flight synthetic mutation; UI reports/reconciles actual state and never automatically replays. Close/replace a session while connection is pending; it must not resurrect. |
| Event recovery | Simulate stream loss (and bounded overflow where a controllable harness is available); old task ends, explicit reconnect obtains a fresh snapshot and acknowledges the gap. |
| Multiple grants | Two independent grants operate; revoking one cancels only its sessions and the other remains usable. |
| Scope replacement | Fresh visible approval rotates the selected key/grant; old connection cannot continue. Denial before approval preserves the old grant. |
| Durable revocation | Revoke provider-side while connected, then restart/reload provider: the removed grant remains absent and saved consumer credentials cannot reconnect. Forget consumer copy separately. |
| Partial persistence/recovery | Test controlled failed-save/disconnect using an isolated harness; surface provider-only grants or pending writes, block stale writes, reload actual state explicitly. Never alter live Keychain policy to inject failure. |
| Duplicate installation/process | Multiple provider copies/consumer processes fail visibly instead of choosing an arbitrary target. Restoring one intended copy/process restores routing. |
| Contract mismatch | An incompatible pinned client fails before unsupported handler execution; a deliberately compatible subset succeeds. |
| Signing/storage lane | Actual signed owner saves/reloads across restart and intended updates. Unprovisioned configuration fails visibly. Distribution/renewal/team-negative lanes need their own controlled evidence. |
| Cleanup | Revoke/forget only test grants, reload both stores, confirm those rows absent and other app state preserved. |

Classify unavailable fault injection as NOT RUN or BLOCKED, not a pass. Sleep/wake, unrelated teams, distribution, additional OS/hardware and independent review are separate qualification; do not force machine sleep or claim those from socket reconnect/unit tests. Use the SDK's current readiness docs for outstanding gates.

## Diagnose by stable result

| Result | Next action |
| --- | --- |
| `credentialConfiguration` | Inspect actual signed identifier, entitlements and matching authorized provisioning; ad-hoc or unprovisioned processes cannot save. |
| `credentialLocked` / `credentialStorage` | Show protected-storage failure and recover explicitly; do not change ACLs, reset user grants or fall back to files. |
| `credentialOperationPending` | Stop changing records, let the outstanding operation finish, then explicitly reload. |
| `unavailable` / `ambiguousProvider` | Inspect registered copies, final metadata, app startup, schemes, allowlist, and count of running callback receivers. Do not pick the first candidate. |
| `pairingRequired` / expired/invalid invitation | Inspect selected grant/expiry; explicitly start a new pairing flow when appropriate. Never reuse/log the old secret. |
| `permissionDenied` | Compare that record's scopes to the action's mapped scope; use fresh replacement consent for changes. |
| `ContractDiagnostic` / `unsupportedVersion` | Compare pinned client → actual provider contracts and selected capabilities/minimum minor. Re-pairing alone does not fix schema incompatibility. |
| `timedOut` / `disconnected` / cancellation | Reconcile any sent mutation before a new action; never assume rollback. Check startup URL queues for cold-launch failures. |
| `eventOverflow` / `busy` | Respect bounded capacity. Reconnect/resubscribe for a fresh snapshot after event loss; do not loop/replay mutations. |
| `invalidMessage` / `unknownAction` | Check stable IDs, payload shape, domain validation and generated/bundled schema consistency. |

## Report evidence

For each relevant scenario record `PASS`, `FAIL`, `BLOCKED`, or `NOT RUN`, plus the build/configuration, steps, observed result and redacted local evidence location. Keep the exact failure if a later run passes. Summarize which user trigger works, which scopes were exercised, whether persistence/revocation were proved, and what remains unverified. A bundle preflight PASS with runtime NOT RUN is an incomplete integration validation.
