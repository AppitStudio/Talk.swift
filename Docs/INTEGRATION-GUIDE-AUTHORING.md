# Publish an app's public integration guide

A developer should be able to implement your app's Talk features from a public guide and exported schema, without your app's source. Keep one maintained guide per app under `Integrations/<app>/GUIDE.md`. Use the single [canonical template](../Integrations/TEMPLATE.md) whether the app provides actions, consumes actions, or does both.

The guide format, app/API version, SDK version and schema format version are independent. Format 1 uses a recognizable HTML marker followed by a JSON metadata block and fixed sections. JSON avoids a YAML parser dependency. The metadata declares roles, the SDK baseline, provider contract identity/version/hash/module, and a closed list of consumed provider guides. The contract hash detects drift; it does not verify publisher identity.

## Create the draft

From a Talk checkout, build the existing schema tools:

```sh
swift build --product TalkSchemaExporter
swift build --product TalkContractChecker
TALK_TOOLS=$(swift build --show-bin-path)
```

For an app with a real provider contract, choose your own app slug and bundle ID and point to its actual schema:

```sh
python3 Scripts/integration-guides.py init sample-studio \
  --name "Sample Studio" --roles provider \
  --bundle-id com.example.SampleStudio \
  --contract Examples/Shared/StudioContract/Contract.talk.json \
  --tools-dir "$TALK_TOOLS"
```

The command validates and canonicalizes JSON through `TalkSchemaExporter`, creates `Contract/Package.swift` with `TalkClientPlugin`, and fills identity, hash and action/scope rows in the one template. It never overwrites an existing guide. The sample's schema is synthetic; for your own app pass the real exported contract. A provider cannot be scaffolded from a marketing description or an inferred private Swift method.

For a consumer-only app:

```sh
python3 Scripts/integration-guides.py init sample-launcher \
  --name "Sample Launcher" --roles consumer \
  --consumes Integrations/dockflow/GUIDE.md
```

Use `--roles provider,consumer` with both sets of inputs for a dual-role app. Repeat `--consumes` for each provider the app actually integrates with. `--module` optionally selects the Swift contract module name. Consumer-only guides must use `provider: null`; never synthesize a fake inbound API to complete a template.

## Fill the contract's meaning

Use the [public Talk skill](../Skills/talk-integrations/SKILL.md) and its [guide workflow](../Skills/talk-integrations/references/guides.md) with your preferred coding agent. Give the agent your provider source **locally** so it can inspect handlers, actual domain side effects, versioning, limits, consent and lifecycle. The resulting public artifacts must stand alone. An agent can draft text; it cannot infer evidence that was never collected.

A useful request is:

> Use the Talk integration skill to complete this app's guide from its actual schema and handlers. Follow Integrations/TEMPLATE.md. Make it usable without access to this app's repository. Document real permissions, side effects, limits and recovery; add a minimal consumer that compiles using only the public artifacts. Preserve unknown or untested app versions and runtime behavior as explicit gaps. Run the guide checker and contract/consumer build before proposing publication.

Remove every template instruction after replacing it with factual content. The draft needs:

- Actual provider/consumer roles, supported app versions or explicit unreleased status, SDK pin and installation/signing prerequisites.
- Public canonical schema, typed client generation and DTO semantics. Describe bounded lists, optional fields and anything the schema cannot express.
- Every action, scope and side effect, subscription/event permissions, mutation admission versus completion, and no automatic replay after uncertainty.
- End-to-end pairing, persistence, URL routing, saved reconnect, permission replacement, revocation, forgetting and protected-store recovery.
- A compile-checked public example that depends only on Talk and the exported contract; no private source imports, local checkout paths, signing identities or account configuration.
- Actual evidence with independent PASS/FAIL/NOT RUN outcomes. An earlier SDK example run or compilation does not establish your app's runtime behavior.

Use the [integration UX specification](INTEGRATION-UX.md): Talk Integrations → Apps I control is the developer's implemented outgoing library, while Apps with access manages generic incoming grants. A provider supporting unknown consumers must use the generic callback default in Talk `0.1.0-beta.2` or later and cannot silently retain a fixed list of known client bundle IDs. Neither direction grants the other.

## Validate and review

Once the facts are filled, set `status` to `beta` or `stable` according to the actual app/API maturity. A stable guide status does not qualify an unqualified SDK. Run:

```sh
python3 Scripts/integration-guides.py check --tools-dir "$TALK_TOOLS"
python3 Scripts/validate-public-integrations.py
```

The first command checks metadata/sections, artifact links, the SHA-256 pin, module/plugin pin, documented action/scope/method references, consumed contract pins and authoritative schema export/compatibility. Omit `--tools-dir` only for a lightweight metadata check; its output explicitly marks Swift schema validation as NOT RUN. `--allow-draft` allows unfinished template instructions for work in progress; it is not a publication check.

The second command proves the repository's DockFlow example can be generated and compiled in an isolated consumer using only public artifacts and a local copy of the public SDK. It also exercises scaffold, no-overwrite, draft rejection, reference/hash/version/scope and actual-export drift controls. It does not launch apps or run mutations. When adding a new provider guide, add that provider's own exact minimal consumer to the validation workflow; do not claim the existing DockFlow smoke build covers it.

To compare a guide with an actual exported provider schema, pass one guide and the export:

```sh
python3 Scripts/integration-guides.py check Integrations/dockflow/GUIDE.md \
  --tools-dir "$TALK_TOOLS" \
  --provider-export Integrations/dockflow/Contract/Sources/DockFlowTalkContract/Contract.talk.json
```

The command above demonstrates the syntax with the public file; replace the last argument with your provider's freshly exported/embedded file for actual provenance evidence. A self-comparison is not a provider comparison. When adopting changes, separately run `TalkContractChecker <old-consumer.json> <new-provider.json>`; structural acceptance cannot prove unchanged semantics.

Run `python3 Scripts/audit-public-source.py` before publication. The guide checker proves local references exist inside the checkout; the public-source audit separately enforces which files can be published and rejects links to private notes. Review the public diff for user data, credentials, private paths and unsupported claims. Publish the guide, canonical contract and example together through the repository's normal review process, then add the registry entry. The tool does not create a Git commit, upload files or submit a PR. A GitHub action or hosted LLM service is unnecessary for this workflow. Keep license and release decisions explicit; visibility alone is not a license grant.

## Maintain one source of truth

The provider's schema owns wire shape; its app guide owns human semantics; the skill owns the authoring/integration workflow. Generate Swift from JSON. Consumer guides link to the provider's action table instead of repeating it. When the schema changes, update its guide's hash/version and example, then compare the old consumer pin against the new provider export and test the actual app behavior. Never auto-refresh a pin from untrusted discovery metadata.

Increment `guideVersion` for documentation/example revisions. Change `contractVersion` only for real API evolution and review compatibility in both required directions. Pin the app's actual supported version once released, and retain honest runtime/platform/distribution limits until tested.
