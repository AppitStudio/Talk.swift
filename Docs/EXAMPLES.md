# Run the example apps

Both examples target macOS 12.4 or later. Build them with the Swift 6.2+ toolchain described in [installation](INSTALLATION.md); the build host can require a newer OS than the apps.

**Talk Studio** exposes synthetic scene state, scene-selection actions, and change events. **Talk Automator** starts and ends focus sessions and uses saved permission to select Studio scenes. Both use the same production credential backend as the SDK.

The builder produces standard and sandboxed versions of each app. Build on macOS with Swift 6.2+ and use existing Apple signing material that you are authorized to use. See [installation requirements](INSTALLATION.md).

## Prepare local signing

Create `LocalBuild/example-signing.private.json` with this shape, replacing the placeholders locally:

```json
{
  "certificate": "<existing-signing-identity-SHA1-selector>",
  "profile": "<path-to-existing-macOS-provisioning-profile>"
}
```

The profile must authorize all four example identifiers:

- `dev.talk.examples.paired.studio`
- `dev.talk.examples.paired.automator`
- `dev.talk.examples.paired.studio.sandbox`
- `dev.talk.examples.paired.automator.sandbox`

A matching wildcard Apple Development profile can cover local testing. The builder checks the profile and exact signatures. It does not create certificates, enroll accounts, install profiles, modify trust, notarize, or upload builds. Keep the private configuration, profiles, and generated apps out of Git.

## Build and launch

Quit existing example processes before rebuilding. From the repository root:

```sh
python3 Scripts/build-examples.py --signing-config LocalBuild/example-signing.private.json
open "LocalBuild/Apps/standard/Talk Studio.app"
open "LocalBuild/Apps/standard/Talk Automator.app"
```

The builder exports the contract before signing, verifies all four apps, and promotes the complete set. It retains previous builds under ignored `LocalBuild/` directories.

To run the sandbox variants:

```sh
open "LocalBuild/Apps/sandboxed/Talk Studio Sandbox.app"
open "LocalBuild/Apps/sandboxed/Talk Automator Sandbox.app"
```

## Pair and automate

1. In Studio, choose the scopes to offer and create a pairing code.
2. Copy the code directly into Automator's secure input. Approve the displayed scopes in Studio.
3. Start a focus session in Automator. With selection permission, it changes Studio to the Focus scene.
4. Disconnect and reconnect, then quit and reopen both apps. The saved grant permits the same approved automation without another Talk consent prompt.
5. Use **Replace permissions** to request a different scope set through a new pairing and consent flow.
6. Revoke an integration in Studio and verify it cannot reconnect after restart. Forget its consumer copy separately.

With observe permission, provider changes arrive as live events. Use synthetic data. Pairing codes are temporary secrets; do not include them in logs, issues, screenshots, URLs, or source. Displayed names and bundle IDs do not establish verified publisher identity.

For a complete acceptance pass, test all four provider/consumer sandbox combinations, denial, read-only consent, multiple integrations, cold provider launch, and durable revocation. The [qualification report](QUALIFICATION.md) records the existing local results and their limits. Your actual app pair still needs its own runtime validation.
