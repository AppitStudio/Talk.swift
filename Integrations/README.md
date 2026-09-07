# Public app integration guides

Build a feature against an app's public Talk contract without access to its source. Each app uses the same [guide template](TEMPLATE.md), with versioned metadata, a declared role, permissions, lifecycle, typed usage and honest validation evidence.

| App | Exposes actions | Calls other apps | Public guide |
| --- | --- | --- | --- |
| DockFlow | List/read/apply presets; observe changes | No Talk consumer API listed | [DockFlow](dockflow/GUIDE.md) |
| ExtraBar | No provider API currently exposed | DockFlow preset widget | [ExtraBar](extrabar/GUIDE.md) |

A provider guide is the starting point for calling that app. A consumer-only guide describes implemented outgoing features; it does not imply the app is callable. These are documentation entries, not an app store, publisher verification service or SDK runtime registry. A listing grants neither installation trust nor permissions.

DockFlow's [public contract package](dockflow/Contract/Package.swift) and [consumer recipe](dockflow/Examples/DockFlowRecipe.swift) are sufficient to generate and compile a typed integration without private app code. Generic provider routing is available in Talk `0.1.0-beta.2`; consult the guide's app-version prerequisites before relying on a shipping app build. Talk remains beta; see [readiness](../Docs/BETA-READINESS.md).

For coding agents, load the public [Talk integration skill](../Skills/talk-integrations/SKILL.md), then the selected provider guide and its linked JSON. Preserve wire IDs and scopes. Discovery metadata cannot replace the reviewed contract. Implement a real feature before adding an app to your product's outgoing library.

To publish a guide for your own app, use the [authoring workflow](../Docs/INTEGRATION-GUIDE-AUTHORING.md). The deterministic scaffold exports your contract and creates this one template; your preferred coding agent fills the semantics from your implementation. No hosted LLM service, API key or runtime dependency is required. Review and publish the public files through your normal repository process.
