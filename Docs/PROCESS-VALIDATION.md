# Separate-process local validation

These probes compile frozen copies of the actual SDK sources, ad-hoc sign disposable bundles, and retain a unique evidence directory under `LocalBuild`. They do not access Keychain credentials or change the runnable example apps. The tested host is macOS 15.7.9 (24G830), arm64, Swift 6.2.3 / Xcode 26.2. Other OS versions and architectures remain untested.

## Transport

```sh
python3 Scripts/validate-process-transport.py
python3 Scripts/validate-process-transport.py --without-source-binding
```

The second command removes only the outgoing source-binding assignment in its frozen source copy. It never edits the working SDK. A successful control is recorded as successful; it is not forced to fail to support the mitigation.

For each of the four standard/sandbox provider-consumer combinations, two distinct processes perform 16 trials. An initial mutually authenticated TLS connection supplies a former outgoing source port. After closing both initial peers, the provider retains its first listener and binds a second listener to that former client port, with a 20 ms settling interval. The actual `TalkConnection` outgoing and accepted initializers then exchange eight correlated framed requests/responses, reconnect with the same credential, and repeat. A wrong-key control on the final listener must fail on both peers, with actual pin rejection and a numeric TLS failure on the client.

Credentials and endpoints travel only over anonymous parent-child pipes. They are not arguments, environment variables, files or evidence output. Messages use fixed synthetic data. Control messages, listener retention, reads and connection deadlines are bounded; the parent terminates and reaps only its owned children on failure. There is no connection retry or replay after an error. Evidence includes source/binary hashes, completed counts, cleanup status and bounded anonymous diagnostics. Framework stderr is discarded because it may contain endpoints; use the retained SDK diagnostics instead.

Results on 2026-09-06:

| Source configuration | Trials | Round trips | Reconnects | Wrong-key controls | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Current outgoing binding | 64 | 1,024 | 64 | 4 bilateral rejections | PASS |
| Assignment removed in frozen copy | 64 | 1,024 | 64 | 4 bilateral rejections | PASS |

The two successful runs are retained privately. An earlier run stopped on a misspelled diagnostic assertion in the harness; it remains failed and is not counted in these totals.

Both separate-process configurations passed. This is additional transport compatibility coverage, **not** a separate-process reproduction of POSIX48 or new causal evidence for source binding. The earlier in-process failing baseline and matched controls remain distinct evidence. The probe does not exercise persistent pairing, provider authorization, long load, resource saturation, IPv6 or system sleep.

## Duplicate callback routing

```sh
python3 Scripts/validate-callback-routing.py
```

Disposable AppKit receiver bundles advertise the real `talk-spike-consumer` callback scheme. Each run uses unique synthetic bundle IDs and explicitly registers its owned app copies. It exercises the actual `EndpointResolver.reply` method, with no pairing credentials or Keychain access. The callback port is a fixed synthetic hint; no service listens there.

Each of the four sender/receiver sandbox combinations runs two cases: copies at different bundle paths, and two processes at the same bundle path. Each case requires:

1. Exactly one running receiver and a successfully delivered callback.
2. Two distinct running receiver processes, known bundle URLs, and the expected same/different-path relationship.
3. A callback attempt with no delivery to either process over a two-second observation, while the duplicate enumeration stays unchanged.
4. Removal of the owned second process, exactly one remaining receiver, and a second successfully delivered callback.

All **eight cases passed**, with 16 positive deliveries and zero deliveries observed during ambiguity. This validates stable duplicate-process selection and recovery in the tested local directory tree. It does not prove atomic routing against a process starting/exiting between enumeration and LaunchServices delivery, arbitrary installation locations, or the full paired Automator UI flow with duplicate copies. Bundle identity is still an untrusted routing hint; TLS authenticates connections.

Final run artifacts are retained privately. Every owned process exited; all eight synthetic identities had zero running processes and zero registered installations after cleanup. Signed artifacts were retained with `.app.noindex` names. The four ordinary example identities still each resolve to their original installation.

Earlier runs deliberately remain failed. Their receivers advertised an unrelated scheme, so standard senders delivered but sandboxed senders failed their positive control. The diagnostic run recorded callback open error code 256. Explicit registration and a frozen-copy Workspace URL lookup control did not remedy that configuration. Advertising the SDK's actual callback scheme made all eight cases pass with the existing routing policy. These failures are probe-configuration evidence, not duplicate-denial passes or proof of a routing defect. The speculative Workspace lookup was not adopted.

Callback delivery errors now add only a fixed stage and numeric NSError code to the existing opt-in, 256-event diagnostic ring. URLs, bundle IDs, request nonces and error descriptions remain absent; disabled diagnostics retain nothing. The number alone does not identify every possible underlying OS failure.
