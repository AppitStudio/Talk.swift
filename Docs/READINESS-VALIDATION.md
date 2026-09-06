# Local production-testing preparation — 2026-09-06

The optimized examples are ready for further controlled local testing. Production security qualification remains incomplete: the historical Keychain disclosure is unexplained, actual Apple provisioning/update continuity has not been tested, and other machines/platform conditions still need coverage. Passing load and sanitizer runs do not close those gates.

Host: **macOS 15.7.9 (24G830), Apple silicon, Swift 6.2.3 / Xcode 26.2**. All work was local, with ad-hoc signing and synthetic grants. No Git, account, distribution identity, publication, upload, trust override or ACL change. Raw measurement artifacts and earlier failures are retained privately; the sanitized results and reproduction commands are below.

## Changes that affect behavior

- Canonical contract export now enforces the same **65,536-byte** limit as manifest loading. A valid compact 30,977-byte schema previously exported successfully to 69,817 bytes, which its own loader then rejected. The new regression failed before the fix and passes afterward. Export reports `contract: canonical export exceeds 65536 bytes`; the CLI leaves an existing output file untouched. A smaller schema exports and reloads identically. Input validation and runtime transport policy are unchanged.
- The final native bundles include the previously implemented manual connection-status fix and numeric callback diagnostics. Successful manual connect/disconnect visibly clears a stale global failure.
- Added actual-wire boundary tests, a bounded memory-only pressure/idle executable, an AddressSanitizer parser mutation harness, and optimized/Rosetta measurement support. Long standalone loads now accept up to 1,800 seconds; the existing opt-in unit workload remains capped at 300 seconds.
- Credential lifecycle validation now uses a unique evidence directory per invocation, preserving previous signed owners and failure evidence.

## Measured coverage

| Check | Observed result | Limit |
| --- | --- | --- |
| Final native Swift Testing suite | 64 tests in 19 suites, passing; two opt-in skips | Skips are sustained load and noncooperative saturation, separately exercised |
| ThreadSanitizer suite | Same 64 tests passed; test binary links the TSan runtime; no race report | Instrumented tested paths, not a proof of race freedom |
| Noncooperative saturation under TSan | 128 handlers retained after stop, excess work rejected as busy, zero retained after release; passed | Separate opt-in run; one unrelated sustained test skipped |
| x86_64 translated suite | Same 64 tests passed with an x86_64 Swift test host under installed Rosetta | This is not native Intel hardware |
| Release build, contract pipeline, exporter CLI | Pass, including output-preserving oversized export rejection | No public package/release operation |
| Standard optimized workload | 1,800 s, **3,111,680 calls**, 2,917,200 events, 47,872 connections, 2,992 overflow/revocation cycles; **zero recoveries** | 16 memory-only integrations; peak RSS 31,072 KiB |
| Sandboxed optimized workload | 1,800 s, **3,055,520 calls**, 2,864,550 events, 47,008 connections, 2,938 overflow/revocation cycles; **zero recoveries** | Peak RSS 30,144 KiB |
| Standard maximum-frame pressure | 300 s, 2,203 cycles / **281,984 round trips**, 2,203 excess-peer rejections | Eight peers hold 128 handlers simultaneously; 65,536-byte request and response bodies |
| Sandboxed maximum-frame pressure | 300 s, 2,565 cycles / **328,320 round trips**, 2,565 excess-peer rejections | Same workload and bounds |
| Standard / sandbox idle | 600 s idle each; 16 expired sessions and 16 same-grant reconnects per run | Process CPU over idle interval: 12,541 / 13,566 microseconds; peak RSS 14,256 / 14,208 KiB |
| Rosetta pressure | 60 s per variant; 30,592 / 35,840 round trips; RSS 108,128 / 97,448 KiB | Translated x86_64 probe; no native Intel or AppKit x86 matrix |
| Initial parser mutations under ASan | 600 s, 7,664,572 cases, no reported sanitizer failure | Initial seed serialization was not yet verified deterministic across processes |
| Final parser mutations under ASan | 300 s, **3,234,518 cases**; 188,866 accepted frames, 52,953 schemas, 42,745 invitations; no reported sanitizer failure | Two fresh-process replays matched; synthetic fixed inputs only; not coverage-guided fuzzing |
| Standard / sandbox credential lifecycle | Migration, restart continuity, changed-build isolation, independent removal and owning cleanup passed | Does not resolve historical different-signer disclosure |
| Standard / sandbox isolated SDK storage | Locked denial, explicit reload, no mutation replay and owning cleanup passed; production injection API absent | Disposable encrypted Keychains; pending-operation gates are synthetic before real OS writes |

The two long workloads total **6,167,200 calls** and one hour of aggregate workload duration. They overlapped each other, UI work and other local builds/probes. Their CPU/throughput figures are observations under contention, not isolated comparative benchmarks. Both ended with zero observed listeners/established sockets and four numeric file descriptors after cooldown. Pressure and idle runs also returned to that socket/descriptor state.

### Memory result and retained failure

The earlier 180-second pressure attempt **failed** the conservative 768 MiB RSS ceiling at approximately 107 seconds (797,952 KiB). That result has not been reclassified. In subsequent runs, Mach task metrics and owned-process `heap --noContent` / `vmmap -summary` showed a small physical footprint alongside large clean reusable allocator regions. No memory contents or credentials were dumped.

The explicit footprint policy requires a peak physical footprint below 768 MiB and retains a separate 2 GiB RSS ceiling. Under that policy, the five-minute ordinary standard/sandbox pressure runs passed with ledger peak footprints of **55,332 / 57,571 KiB** (about 54 / 56 MiB), while peak RSS was **1,151,344 / 956,432 KiB**. Reported reusable memory explains most of the difference in these observations. This does not establish behavior under system-wide pressure or on other OS versions. The default measurement policy remains RSS. See Apple's [task VM metrics](https://developer.apple.com/documentation/kernel/task_vm_info_data_t) for the distinct fields.

A probe-only `malloc_zone_pressure_relief` control had bounded RSS, but returned zero released bytes. It is not proof of a particular reclamation mechanism. **No SDK allocator policy was changed.** The control and ordinary runs have separate records. The final wrapper rebuilds the requested probe, records source/binary hashes, and includes the last cooldown memory sample; five-second standard/sandbox checks passed after that observer change.

### Wire and native behavior

Actual TLS peers validate maximum-size correlated frames sent with individual header-byte and 997-byte body application writes. Network.framework may coalesce packets; packet fragmentation is not claimed. Authenticated zero-length, oversized, truncated, overly nested and invalid-UTF8 frames never dispatch a handler and leave a separate healthy peer usable. A stalled partial frame expires while healthy traffic continues. The first helper misplaced its deadline cancellation handler and hung on a truncated case; that failed run is retained. The corrected helper cancels within the timed operation, and truncated cases explicitly test abrupt disconnect rather than assuming immediate TLS half-close EOF.

Optimized native apps passed all four standard/sandbox provider-consumer combinations: explicit pairing once, generated calls/events, saved-grant reconnect, cold provider launch from each consumer alone, and selected revocation while the other consumer stays authorized. Both the initial optimized build and the final export-guard build passed this matrix. All final grants were revoked/forgotten, and all four stores reloaded empty. Standard apps are open unpaired; sandbox variants are quit and runnable.

On the initial optimized build, a registered duplicate provider caused `ambiguousProvider`; removing that owned duplicate restored saved reconnect and the global success text. A second running sandbox Automator at a distinct path caused the original consumer's reconnect to time out while another established connection remained active. Removing only the owned duplicate restored single-process routing and successful reconnect without new pairing. This complements the previous eight disposable AppKit routing cases. It does not prove all native duplicate combinations or atomicity across process-start/exit races. Final bundles have the same routing/status implementation; duplicate injection was not repeated after the export-only change.

## Reproduce locally

Run from the project directory. Long runs are opt-in and have bounded duration, memory ceilings and owning-process cleanup. They do not persist pairing credentials.

```sh
swift test
swift build -c release
python3 Scripts/validate-contract-pipeline.py
python3 Scripts/validate-integration-guide.py

TALK_SUSTAINED_SECONDS=1800 python3 Scripts/measure-sustained-load.py --standalone --configuration release
TALK_SUSTAINED_SECONDS=1800 python3 Scripts/measure-sustained-load.py --standalone --sandboxed --configuration release

python3 Scripts/measure-readiness.py pressure --seconds 300 --memory-policy footprint
python3 Scripts/measure-readiness.py pressure --seconds 300 --sandboxed --memory-policy footprint
python3 Scripts/measure-readiness.py idle --seconds 600
python3 Scripts/measure-readiness.py idle --seconds 600 --sandboxed
python3 Scripts/fuzz-parsers.py --seconds 300

swift test --disable-xctest --sanitize=thread --scratch-path LocalBuild/ThreadSanitizerValidation
TALK_SATURATION=1 swift test --disable-xctest --sanitize=thread --scratch-path LocalBuild/ThreadSanitizerValidation --filter noncooperativeHandlersRetainGlobalCapacityAcrossRevocation
```

On this Apple-silicon host with Rosetta already installed:

```sh
arch -x86_64 /usr/bin/xcrun swift test -c release --arch x86_64 --scratch-path LocalBuild/IntelValidation
python3 Scripts/measure-readiness.py pressure --seconds 60 --arch x86_64 --scratch-path LocalBuild/IntelValidation
python3 Scripts/measure-readiness.py pressure --seconds 60 --sandboxed --arch x86_64 --scratch-path LocalBuild/IntelValidation
```

The first cross-architecture test invocation compiled successfully but used an arm64 test host and failed to load x86_64 tests. Explicitly running the Swift host under Rosetta resolved the mismatch. The installed Apple compiler rejected `-sanitize=fuzzer`; no coverage-guided run occurred and no replacement toolchain was downloaded. A later filtered TSan invocation hit macOS sanitizer-loading policy in the unused XCTest discovery helper; use `--disable-xctest` for this Swift Testing project. No platform security setting was changed.

## Evidence handling

Raw logs, captured source/binary snapshots, and historical signing/storage artifacts are retained privately. Sources and binaries captured by individual runs describe that run; later harness revisions do not retroactively improve earlier evidence. The measured failures above remain part of the result.

## Remaining production gates

1. Explain and remediate the historical decoded Keychain disclosure, retaining its owning artifacts. Controlled denial results do not erase the earlier positive disclosure. No attacker read approval, ACL relaxation or trust override is an acceptable substitute.
2. Use an explicitly authorized actual Apple signing/provisioning environment for legitimate updates, certificate renewal, data-protection Keychain and unrelated Team IDs. Local ad-hoc and synthetic certificates cannot establish these properties.
3. Run on native Intel, minimum macOS 13 and other target OS versions. Test arbitrary installation paths, multi-user isolation, firewall/filter conditions, sleep/wake, IPv6 policy and resource pressure on a separate test machine. Rosetta and passive idle do not cover those conditions.
4. Extend native simultaneous-copy combinations and process-lifecycle races; perform longer coverage-guided fuzzing with a compatible toolchain, real system-pressure observation and independent security review.
5. This historical evidence does not establish stable-release readiness. Current source publication is a development preview; use [current beta readiness](BETA-READINESS.md) for the maintained qualification status.
