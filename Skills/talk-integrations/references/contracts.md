# Contract and generation

For a new provider, adapt [the synthetic contract](../assets/Sources/IntegrationContract/Contract.talk.json). It generates `ExampleAPI`, `ExampleClient`, `Snapshot`, `SetValue`, read/set/observe methods and a changed event. For an existing provider, pin its supplied contract; discovery metadata is not a trusted API definition.

Choose stable contract/action IDs and scopes. `name` controls Swift prefixes, `symbol` creates an API constant, and `method` creates a client method. Action IDs and scope strings are independent: use `ExampleAPI.actions[actionID]` or explicit scope constants for consent UI. Do not assume generated action constants are scope strings.

Actions specify input, output, scope and mutation classification. Separate read and mutation permissions. Events have payloads but no scope field; the configured subscription action supplies permission. The preview has one provider-wide subscription action: its event feed must fit that permission. Separate providers/contracts if feeds need independent confidentiality boundaries; consumer filtering is not authorization.

Supported DTOs: named immutable structs, string enums, `String`, `Bool`, `Int64`, `UUID`, arrays and optionals. `Void` is action input/output only. No recursive DTOs, floating point, dates, dictionaries, arbitrary Codable inference or associated-value enums. Map domain data explicitly and validate semantics. Use bounded domain operations/pagination for large data; the encoded frame limit is 64 KiB including the envelope.

Set actual paths and run from the host:

```sh
mkdir -p LocalBuild/TalkContract
swift run --package-path "$TALK_SDK_ROOT" TalkSchemaExporter Sources/IntegrationContract/Contract.talk.json LocalBuild/TalkContract/Contract.talk.json
swift run --package-path "$TALK_SDK_ROOT" TalkClientGenerator LocalBuild/TalkContract/Contract.talk.json LocalBuild/TalkContract/Example.generated.swift
swift run --package-path "$TALK_SDK_ROOT" TalkContractChecker Sources/IntegrationContract/Contract.talk.json LocalBuild/TalkContract/Contract.talk.json
```

That last command is only baseline self-compatibility. For an integration/upgrade, compare the **consumer's pinned contract first, actual provider's exported contract second**. Test old/new directions separately. Structural acceptance cannot establish unchanged semantics. Major mismatch, missing capabilities, changed scopes/mutation classification and incompatible DTO shapes fail. New required fields or enum cases can break one direction.

Generate Swift and embedded canonical JSON from the same schema. Export before signing. Do not edit generated Swift. Generated clients require all schema capabilities by default; optionally choose `requiredActions`, `requiredEvents` and `minimumMinor` deliberately. Capabilities and saved consent are separate. Call the generated client's `connect()` to negotiate over authenticated TLS.

[The provider sample](../assets/Sources/IntegrationWiring/Provider.swift) binds IDs to typed decoding, validation, cancellation before mutation and event publication. Replace synthetic state with the app's actor-owned domain model. Runtime shape validation does not replace domain validation, application persistence or cancellation.

For full syntax/limits read the current SDK `Docs/CONTRACTS.md`; for generated APIs inspect `Sources/TalkContractSchema/SwiftClientGenerator.swift`.
