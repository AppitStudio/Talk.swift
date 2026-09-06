# Contract schema version 1

`Examples/Shared/StudioContract/Contract.talk.json` is the example's authoritative contract. `schemaVersion` describes this file format; `contractVersion` describes the API; `TalkMessage.protocolVersion` describes transport envelopes. They are separate version domains.

## Authoring and build responsibilities

1. Declare DTOs, actions and events in JSON. Validation rejects unsupported keys, duplicate identifiers, unknown types, cycles, excessive declarations and invalid names, with a declaration path in the diagnostic.
2. `TalkClientGenerator` validates and emits Swift DTOs, action/scope constants, typed requests, and typed event decoding. The SwiftPM `TalkClientPlugin` runs it with declared input/output files in the plugin work directory. It never adds package dependencies or rewrites source inputs.
3. `TalkSchemaExporter` separately validates and canonicalizes JSON. `Scripts/build-examples.py` invokes it to embed `Contract.talk.json` before code signing. It never initializes or launches provider application logic.
4. The provider binds the generated action IDs to application handlers and passes the generated scope mapping to `TalkServer`. Runtime authorization is enforced on every action. The example validates payloads and checks cancellation before scene mutation.
5. The consumer uses generated `StudioClient` methods and event decoding. Generated calls never retry automatically. A disconnected or timed-out mutation has an uncertain outcome.

There are no provider macros in this stage. The explicit schema is the source of truth and does not attempt to infer arbitrary Swift `Codable`, custom encoders, stored/computed properties, actors or generics. A future optional macro layer may emit descriptors into this pipeline; it must not perform export, app launch, or signing. No SwiftSyntax or external runtime dependency was added.

## Supported DTO subset

| Declaration | Wire encoding | Swift output |
| --- | --- | --- |
| `String` | JSON string | `String` |
| `Bool` | JSON boolean | `Bool` |
| `Int64` | Signed 64-bit JSON integer | `Int64` |
| `UUID` | Codable UUID string | Foundation `UUID` |
| Named `struct` | Object of declared fields | Immutable `Codable, Sendable, Equatable` struct and public initializer |
| Named `enum` | Declared case's string spelling | String raw-value enum, also `CaseIterable` |
| `[T]` | Array | `[T]` |
| `T?` | Null or value; nil object fields are omitted by synthesized Codable | Optional |
| `Void` | Null | Only action input/output, never DTO fields or event payloads |

Nested DTOs mean fields referring to other top-level named DTOs. Nested Swift declarations are not inferred. Recursive DTOs, associated-value enums, dates, floating-point values, binary data, dictionaries, tuples, sets, arbitrary integer widths, custom `CodingKeys`, default values, inheritance and generics are unsupported. Unknown enum values fail decoding. Unknown object fields are ignored by synthesized Codable; new required fields are not backward compatible. UUIDs and synthetic session revisions in the example are data, not peer identity.

Limits: input schema and canonical exported manifest 64 KiB, 128 types/actions/events each, 64 fields/cases per type, at most eight array/optional wrappers, and no cyclic DTO graph. Runtime messages remain limited to 64 KiB and 32 JSON container levels including the envelope. A compact accepted input can expand beyond the limit during pretty-printed canonical export; export then throws `contract: canonical export exceeds 65536 bytes` before the CLI replaces its output. Reduce the schema before embedding it. Schema acceptance does not waive runtime value-size limits.

## Versioning and compatibility

- Only schema and protocol version 1 are accepted. Contract versions must be `major.minor.patch` with nonnegative integers and no suffix.
- Wire action and scope IDs are explicit and stable; Swift names can change without deriving new wire IDs. Renaming a wire ID, changing a type, adding required fields or changing enum cases requires a compatibility review and usually a new contract major version. Future incompatible majors must have distinct action IDs or an explicit negotiated compatibility mechanism.
- Generated clients carry a pinned schema, negotiate it over authenticated TLS, and require compatible action/event capabilities before dispatch. `TalkContractChecker client.json provider.json` separately reports directional structural compatibility. Discovery schemas remain untrusted metadata and cannot grant scopes.
- Same major is necessary; minimum minor and explicit required action/event subsets are checked independently. The default generated client requires its full schema; a new client can select an older compatible subset in its initializer. Unselected methods fail before handler execution.
- Inputs are checked client → provider; results/events are checked provider → client. Required receiver fields must be supplied. Optional receiver fields may be missing/null; an optional sender cannot satisfy a required receiver. Unknown object fields are ignored. Array elements and named DTOs are compared recursively. A receiver enum must contain every case its sender can produce. Renaming a wire action/event, changing its scope or mutation meaning, missing capabilities, incompatible types and majors produce path diagnostics. Swift symbol changes are not wire breaks but may break source consumers.
- Structural acceptance does not prove unchanged application semantics: even an ignored new optional input may matter to a mutation. Use minimum minor/capability changes and author review for such meaning changes. No defaults or unknown-enum fallback are invented. The checker bounds expansion at 4096 comparisons and fails closed if a schema is too complex.
- Validation, compatibility, export, generation and runtime value enforcement have distinct APIs/targets. Negotiation freezes capabilities per connection. Runtime rejects malformed inputs before handlers and invalid output/event payloads before delivery. Low-level TalkServer instances without a contract remain available only for low-level protocol/testing; contract-configured servers reject unnegotiated dispatch.
- `Tests/Fixtures/CompatibilityOld` and `CompatibilityNew` exercise the current directional compatibility behavior using independently generated clients. The obsolete pre-release manifest and hand-written client fixtures were removed; they are not supported integration APIs.

See [the runnable integration guide](INTEGRATION-GUIDE.md) for provider handlers, pairing, generated clients, subscriptions, permission replacement and errors. `CompatibilityOld`/`CompatibilityNew` are generated fixture modules exercised over real TLS in both directions.

## Local validation

```sh
swift test --disable-xctest
python3 Scripts/validate-contract-pipeline.py
swift build -c release --scratch-path LocalBuild/ReleaseValidation
python3 Scripts/build-examples.py --signing-config LocalBuild/example-signing.private.json
```

The pipeline script exports canonically, generates and typechecks a client without the Studio implementation, compiles arrays/optionals/Bool/Int64/UUID/enum/nested DTO output, and checks rejection of unsupported declarations. Generated source and temporary validation files stay under `.build/` or `LocalBuild/`. The example builder requires existing authorized signing configuration and builds both standard/sandboxed variants; see [the example app guide](EXAMPLES.md) for the private configuration format.

SwiftPM integration follows the public [build tool plugin model](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md). Provider macro architecture, if later adopted, remains separate from resource export as described in [Apple's macro overview](https://developer.apple.com/videos/play/wwdc2023/10167/).
