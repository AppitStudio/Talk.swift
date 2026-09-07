# Security status and reporting

Talk is beta software: use it with caution. More testing and validation are required. No stable release, production readiness, or complete independent security audit has been declared. See [beta readiness](Docs/BETA-READINESS.md) for current evidence and remaining gates.

Use `CredentialStore` with correctly provisioned app-specific data-protection Keychain access. This is the only shipped backend. The retired file-based implementation and associated compatibility/signing paths have been removed after an unexplained historical cross-signer disclosure. Current storage never queries or migrates those old items; retained old binaries/evidence must not be distributed as current builds.

Pairing authenticates possession of a secret; app names and bundle IDs are not verified publisher identity. Providers must obtain explicit scoped consent. For discoverable pairing, the user must first compare the entire verification code in both apps; public discovery keys and routing hints alone do not authenticate the intended peer. Debuggable hosts, compromised processes, shared credentials, and code authorized for the same Keychain group are outside app-isolation claims. Do not widen entitlements or approve another app's credential request to make tests pass.

Report suspected vulnerabilities through [GitHub private vulnerability reporting](https://github.com/AppitStudio/Talk.swift/security/advisories/new). Include a minimal synthetic reproduction, affected commit, macOS/toolchain version, sandbox mode, and stable error codes. Do not open a public issue for an undisclosed vulnerability. There is no guaranteed response time or supported stable-release window for this preview.

Never post live pairing codes, secrets, Keychain dumps, signing identities/profiles, private logs or application data in public issues. Use synthetic records and include the SDK source digest, macOS/toolchain version, sandbox mode, stable error code and minimal reproduction. Report suspected disclosures privately even if they are intermittent.

For an affected integration, stop its automation, revoke the provider grant, wait for persistence to resolve and confirm that a fresh reload does not restore it. Forget the consumer copy separately. A timeout or disconnected session does not prove durable revocation or rollback. Pair again only after fixing and validating the storage boundary.
