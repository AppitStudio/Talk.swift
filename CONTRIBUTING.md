# Contributing to Talk.swift

Talk.swift is a macOS development preview. Bug reports, focused fixes, documentation improvements, and reproducible compatibility results are welcome through [GitHub issues](https://github.com/AppitStudio/Talk.swift/issues) and pull requests. For larger API or architecture changes, discuss the intended behavior in an issue first.

## Get started

Use macOS and Swift 6.2 or later; the tested toolchain is Xcode 26.2. Read the [installation guide](Docs/INSTALLATION.md), [integration guide](Docs/INTEGRATION-GUIDE.md), and [security model](Docs/SECURITY-NOTES.md). No third-party runtime dependencies are required.

```sh
swift test --disable-xctest
swift build -c release
python3 Scripts/validate-contract-pipeline.py
python3 Scripts/validate-integration-guide.py
python3 Scripts/validate-integration-skill.py
python3 Scripts/audit-public-source.py
```

These commands do not create or install signing identities. Persistent example-app testing needs your own authorized signing configuration; see [examples](Docs/EXAMPLES.md). The skill validator reads existing local signed examples only when present, and does not test actual runtime pairing.

## Changes and validation

Explain the concrete problem, resulting behavior, and checks performed in each pull request. Test behavior that changes, including a negative control for security boundaries. Preserve TLS pinning, explicit scoped consent, bounded resources, cancellation, and the rule against automatic mutation retries. Do not add a storage fallback or widen Keychain access to make a test pass.

Keep schema, protocol, and package versions distinct. Changes to wire IDs, scopes, DTO shapes, or mutation semantics need compatibility review. Preview APIs can change; no stable-release compatibility or support window is promised yet.

For signing/platform qualification, use [the qualification matrix](Docs/QUALIFICATION.md). Record failures, inconclusive results, and missing positive controls as well as passes. A timeout is not proof of access denial or successful revocation. Do not claim an actual-app integration passed based only on SDK tests or a static checker.

## Keep private material out of Git

Use synthetic data. Build output and local evidence belong in ignored `.build/` or `LocalBuild/` directories. Never commit pairing codes, stored credentials, signing profiles/keys, private account configuration, personal app data, machine paths, or raw diagnostic dumps.

The source audit checks an explicit file allowlist, text patterns, and local Markdown targets. With `--stage`, it creates a source-only review copy. With `--check-index`, it also verifies the actual Git index against that source set. Neither check substitutes for human review or a dedicated secret scanner. Ignore rules do not protect files that are already tracked.

Security vulnerabilities must be reported through [SECURITY.md](SECURITY.md), not a public issue. No response-time guarantee is currently offered.
