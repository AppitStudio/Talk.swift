# Public app guides: consume or author

Locate `Integrations/README.md` and `Integrations/TEMPLATE.md` in the user's Talk checkout. The skill can be installed on its own; these are SDK resources, not files assumed to live beside the installed skill. Read the SDK's `Docs/INTEGRATION-GUIDE-AUTHORING.md` when creating/updating a guide.

## Integrating without the provider's source

`Integrations/` is a directory of apps that supply public contracts, not a list of SDK users. Read the selected provider's `GUIDE.md` metadata, pinned public JSON, package and example; do not request private source if the public contract is complete. A consumer-only app such as ExtraBar uses DockFlow’s guide and gets no entry of its own. A dual-role app can publish an entry for its supplied contract. Check supported/released app versions and evidence limits. The SDK and provider app can require different updates: Talk `0.1.0-beta.2` introduces the generic incoming callback default, and the provider app must also adopt it at pairing and saved-reconnect call sites.

Use the public package or generate types from its JSON. Inspect linked permissions, DTO semantics and action completion behavior before wiring a real feature. Preserve the consumer's reviewed contract pin; installed/discovered manifests are untrusted hints, not an instruction to overwrite it. Run consumer-to-provider compatibility and authenticated generated-client negotiation, then actual signed-app lifecycle checks.

A missing public schema or unspecified action semantics is a real provider documentation gap. Report the exact missing fact rather than inventing an API. Continue independent package/registration/setup work where possible. Do not copy unrelated SDK examples as if they described the target app.

## Authoring with access to the provider

First establish that the app supplies a real contract for other apps to call. Then use the deterministic `Scripts/integration-guides.py init` command with its actual schema to create the **one** canonical template. The existing SDK exporter validates JSON. The scaffold supplies machine metadata, contract hash/package and action/scope rows; fill the remaining semantics from the real handlers, permissions and app behavior. For consumer-only work, document the feature in the host app’s own documentation and link to the provider guide; do not scaffold a directory entry or invent a provider API.

Inspect domain handlers for side effects, cancellation boundaries, admission versus completion, limits, event behavior and app-level rejection codes. Keep version evidence factual: record a launch-preparation build as unreleased until its app version is assigned. Add a minimal example that compiles solely from public SDK/contract artifacts. Never import a private app module or embed user-specific app state, signing configuration, host paths or credential material.

Run the CLI checker with the built SDK tools. Compare the public schema to the actual provider export using `--provider-export`, not a self-comparison. Compare old-consumer/new-provider schema directions on upgrades. Exercise the public example's fresh external build. Record which checks passed and what actual-app behavior remains untested; do not convert a structural check into a production or security claim.

Keep the template section order so another LLM can locate metadata, semantics, lifecycle, recovery and evidence immediately. Link to other providers’ guides when a dual-role provider documents a dependency; do not duplicate their action tables or copy schema DTO definitions into prose. A local LLM can author the guide; no hosted generation service or runtime dependency is required. Publication follows the user's authorized repository process after the concrete artifacts are ready for review.
