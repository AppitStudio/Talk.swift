# Integrate with a coding agent

The portable **talk-integrations** skill helps a coding agent add a provider, consumer, or both to existing macOS apps. It covers package setup, contract generation, app registration, Start Pairing → Discover → Connect UI, full-code comparison, saved scoped consent, real automation triggers, calls/events, recovery, and signed-app validation.

Talk is beta software and still needs more testing and validation. Use it with caution. Agent-generated integration code and a successful build do not establish production readiness; validate the actual app pair with synthetic or noncritical data.

The skill lives at [`Skills/talk-integrations`](../Skills/talk-integrations). Install the **whole directory**: `SKILL.md` links to references, compilable starter assets, and a read-only bundle validation script.

## Install in Codex

Clone the SDK into a persistent development directory:

```sh
git clone https://github.com/AppitStudio/Talk.swift.git
cd Talk.swift
```

From that checkout, copy the skill into your Codex skills directory. This command refuses to overwrite an existing installation:

```sh
talk_skill_parent="${CODEX_HOME:-$HOME/.codex}/skills"
talk_skill_target="$talk_skill_parent/talk-integrations"
mkdir -p "$talk_skill_parent"
if [ -e "$talk_skill_target" ] || [ -L "$talk_skill_target" ]; then
  echo "talk-integrations already exists; review it before updating."
else
  cp -R Skills/talk-integrations "$talk_skill_target"
fi
```

Start a new Codex session in your app project and invoke `$talk-integrations`. Supply the actual SDK checkout location or resolved package source. The copied skill does not include the full SDK; review skill updates alongside the resolved SDK API. The current skill targets `0.1.0-beta.2`; documentation on main may contain later corrections without changing that SDK tag. If you installed a copy, review and refresh the whole directory, including references/assets. If your installed skill is a symlink to this checkout, updating the checkout updates the skill too. Preserve any local skill customizations. Installing the skill does not modify or sign your apps.

## Other coding agents

If your agent supports directory-based `SKILL.md` skills, install the same complete folder through its documented mechanism. Otherwise attach or point the agent to [`SKILL.md`](../Skills/talk-integrations/SKILL.md), allow it to read the linked references and assets, and provide the SDK checkout. The workflow can be followed without a particular agent plugin or MCP server.

## Describe the integration

Give the agent the app projects, intended behavior, and existing signing constraints. For example:

```text
Use $talk-integrations to connect my workspace app and focus app.
The workspace app is the provider: expose read-scene, select-scene, and scene-change
events. The focus app is the consumer: starting a focus session selects Focus;
ending it selects Available. Add Start Pairing in the provider and Discover → Connect
in the consumer, require full-code comparison before scoped consent, and save grants.
Use the Talk.swift checkout at the local path I supply. Preserve existing app
lifecycle and signing configuration. Validate permitted and denied operations,
pairing-off discovery, denial/cancel, events, both-app restart, cold provider launch,
permission replacement, and revocation.
```

For consumer-only work, supply the provider's actual contract. The agent should not invent action IDs or infer permissions from discovery metadata. For provider-only work, describe the capabilities, scope boundaries, and side effects you want exposed.

When the provider's source is private, supply its [public app guide](../Integrations/README.md). The DockFlow guide ships the schema and a generated-contract package needed by an external consumer. The guide's availability and version requirements are separate from the SDK's declared minimum.

```text
Use $talk-integrations and Integrations/dockflow/GUIDE.md to add a DockFlow
integration to my app. Use only the public guide and contract; do not assume
access to DockFlow source. Add DockFlow to Apps I control in Talk Integrations,
wire the feature I describe to the typed API, and validate the actual signed pair.
```

To publish your own app's API, use the same [canonical template and authoring workflow](INTEGRATION-GUIDE-AUTHORING.md). `Integrations/` contains only apps that supply a public contract, including apps that also consume others. A consumer-only app uses the selected provider's guide and does not need its own entry. The skill inspects source, describes semantics and runs a deterministic scaffold/check command. There is no required hosted model, model API key or AI dependency in the SDK. Human review still owns the promised semantics and recorded runtime evidence.

All integrations should follow [Integration UX](INTEGRATION-UX.md): Apps I control is a deliberate outgoing App Library; Apps with access is generic incoming saved consent. A dual-role app keeps each direction's lifecycle and permissions separate.

Existing authorized signing configuration can be used. If signing or native UI access is unavailable, the agent can still implement and compile the integration, then report the exact runtime checks left untested. Do not supply pairing codes, credentials, signing keys, or private profiles in prompts.

## What is included

| Resource | Purpose |
| --- | --- |
| [`SKILL.md`](../Skills/talk-integrations/SKILL.md) | Workflow, source discovery, and SDK invariants |
| [`pairing workflow`](../Skills/talk-integrations/references/pairing.md) | Default mode/Discover/Connect sequence, code comparison, task ownership and upgrade continuity |
| [`references`](../Skills/talk-integrations/references) | Installation, contracts, lifecycle, and acceptance checks |
| [`assets`](../Skills/talk-integrations/assets) | External Swift package with generated contract and provider/consumer wiring |
| [`validate-app.py`](../Skills/talk-integrations/scripts/validate-app.py) | Read-only metadata, signature, entitlement, resource, and compatibility preflight |

The starter is synthetic wiring, not a finished app or consent UI. Adapt it to actual app state and visible consent. The starter provides approval/save/client primitives; implement the app-owned discoverable host, discovery object and cancellation-aware UI using the pairing workflow. Do not copy the native examples’ manual invitation field into the default discoverable flow. Read the [validation reference](../Skills/talk-integrations/references/validation.md) for preflight commands and runtime acceptance criteria.

To validate the skill resources from the SDK checkout:

```sh
python3 Scripts/validate-integration-skill.py
```

This builds the starter as an external package and checks positive/negative preflight fixtures. Existing local signed example bundles are inspected only if present. It does not sign, launch, pair, or exercise your actual apps. A successful static check is not evidence of working runtime consent, transport, persistence, or revocation.
