import Darwin
import Foundation
import Testing
import StudioContract
@testable import Talk

/// Opt-in measured local transport load. No Keychain items or native UI grants.
struct SustainedLoadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TALK_SUSTAINED_SECONDS"] != nil), .timeLimit(.minutes(10)))
    func sustainedIntegrationsReconnectOverflowAndRevocation() async throws {
        let seconds = min(300, max(5, Int(ProcessInfo.processInfo.environment["TALK_SUSTAINED_SECONDS"] ?? "5") ?? 5))
        let provider = TalkProvider(store: IntegrationStore(persistence: MemoryIntegrations()), contract: StudioAPI.schema,
                                    subscriptionAction: StudioAPI.observe) { _, _ in
            try .encoding(StudioSnapshot(sessionID: UUID(), revision: 1, selectedSceneID: "focus"))
        }
        try await provider.restore()
        var records: [PairingRecord] = []
        for _ in 0..<16 {
            let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
            try await provider.approve(record); records.append(record)
        }
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        var cycles = 0, calls = 0, events = 0, reconnects = 0, overflows = 0, revocations = 0
        var phase = "setup"
        do {
            repeat {
                var clients: [StudioClient] = []
                let endpoints = await provider.endpoints()
                for record in records {
                    phase = "connect-\(clients.count)"
                    let port = try #require(endpoints[record.credential.id])
                    let client = StudioClient(transport: try TalkClient(port: port, credential: record.credential))
                    try await client.connect(); _ = try await client.subscribe(); clients.append(client)
                    reconnects += 1
                }
                // Fifteen consumers drain in lockstep; one deliberately never reads.
                var iterators = clients.dropLast().map { $0.transport.events.makeAsyncIterator() }
                for revision in 1...65 {
                    phase = "snapshot-\(revision)"
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for client in clients.dropLast() { group.addTask { _ = try await client.snapshot() } }
                        try await group.waitForAll()
                    }
                    calls += 15
                    phase = "publish-\(revision)"
                    await provider.publish(action: StudioAPI.changed, payload: try .encoding(StudioSnapshot(sessionID: UUID(), revision: Int64(revision), selectedSceneID: "focus")))
                    for index in iterators.indices {
                        phase = "event-\(revision)-\(index)"
                        let message = try await iterators[index].next()
                        #expect(message?.action == StudioAPI.changed); events += 1
                    }
                    phase = "slow-barrier-\(revision)"
                    if revision < 65 { _ = try await clients[15].snapshot(); calls += 1 }
                }
                phase = "slow-drain"
                let slowEvents = try await confirmedSlowConsumerOverflow(clients[15])
                #expect(slowEvents == 64); overflows += 1
                phase = "revoke"
                try await provider.revoke(records[0].credential.id); revocations += 1
                await #expect(throws: (any Error).self) { try await clients[0].snapshot() }
                phase = "surviving-mutation"
                _ = try await clients[1].selectScene(SelectScene(id: "focus")); calls += 1
                for client in clients { await client.transport.close() }
                let replacement = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
                // Synthetic in-memory consent fixture, never an automatic real regrant.
                try await provider.approve(replacement); records[0] = replacement
                cycles += 1
                if cycles % 5 == 0 { print("LOAD progress cycles=\(cycles) calls=\(calls) retained=\(await HandlerCapacity.shared.retained)") }
            } while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) < UInt64(seconds) * 1_000_000_000
        } catch { print("LOAD failure cycle=\(cycles) phase=\(phase) error=\(error) retained=\(await HandlerCapacity.shared.retained)"); await provider.stop(); throw error }
        for record in records { try await provider.revoke(record.credential.id) }
        #expect(await provider.integrations().isEmpty)
        await provider.stop()
        try await withDeadline(seconds: 5) {
            while await HandlerCapacity.shared.retained != 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        print("LOAD complete durationSeconds=\(Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1_000_000_000) integrations=16 cycles=\(cycles) calls=\(calls) events=\(events) connections=\(reconnects) overflows=\(overflows) revocations=\(revocations) retained=0")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TALK_SATURATION"] == "1"), .timeLimit(.minutes(2)))
    func noncooperativeHandlersRetainGlobalCapacityAcrossRevocation() async throws {
        let gate = NoncooperativeGate()
        let provider = TalkProvider(store: IntegrationStore(persistence: MemoryIntegrations()), contract: StudioAPI.schema) { _, _ in
            await gate.wait()
            return try .encoding(StudioSnapshot(sessionID: UUID(), revision: 0, selectedSceneID: "focus"))
        }
        try await provider.restore()
        var clients: [StudioClient] = [], requests: [Task<StudioSnapshot, any Error>] = []
        do {
            for _ in 0..<16 {
                let grant = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
                try await provider.approve(grant)
                let port = try #require(await provider.endpoints()[grant.credential.id])
                let client = StudioClient(transport: try TalkClient(port: port, credential: grant.credential))
                try await client.connect(); clients.append(client)
                for _ in 0..<8 { requests.append(Task { try await client.snapshot() }) }
            }
            try await withDeadline(seconds: 10) {
                while await gate.count != 128 { try await Task.sleep(nanoseconds: 5_000_000) }
            }
            #expect(await HandlerCapacity.shared.retained == 128)
            await provider.stop()
            for request in requests { _ = await request.result }
            #expect(await HandlerCapacity.shared.retained == 128)
            try await provider.restore() // retained work survives server replacement
            let grant = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: ["read"])
            let check = TalkServer(record: grant, actions: ["read": "read"]) { _, _ in Issue.record("Exceeded global handler capacity"); return .null }
            let client = try TalkClient(port: try await check.start(), credential: grant.credential)
            try await client.connect()
            await #expect(throws: TalkError.busy) { try await client.request(action: "read") }
            await client.close(); await check.stop()
        } catch {
            await gate.release(); for client in clients { await client.transport.close() }
            await provider.stop(); for request in requests { _ = await request.result }; throw error
        }
        await gate.release()
        for client in clients { await client.transport.close() }
        await provider.stop()
        try await withDeadline(seconds: 5) {
            while await HandlerCapacity.shared.retained != 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        print("SATURATION handlers=128 integrations=16 afterStop=128 excess=busy afterRelease=0")
    }
}

private actor NoncooperativeGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}
