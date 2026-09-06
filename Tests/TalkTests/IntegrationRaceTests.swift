import Foundation
import Testing
import StudioContract
@testable import Talk

private actor PausedPersistence: IntegrationPersistence {
    var records: [PairingRecord] = []
    let started: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>
    init(started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>) { self.started = started; self.release = release }
    func loadRecords() -> [PairingRecord] { records }
    func saveRecords(_ records: [PairingRecord]) async {
        started.yield(())
        for await _ in release { break }
        self.records = records
    }
}

struct IntegrationRaceTests {
    @Test(.timeLimit(.minutes(1)))
    func shutdownDuringDurableApprovalCannotResurrectListener() async throws {
        let (started, begin) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let store = IntegrationStore(persistence: PausedPersistence(started: begin, release: release))
        let provider = TalkProvider(store: store, contract: StudioAPI.schema) { _, _ in
            try .encoding(StudioSnapshot(sessionID: UUID(), revision: 0, selectedSceneID: "focus"))
        }
        try await provider.restore()
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
        let approval = Task { try await provider.approve(record) }
        try await withDeadline(seconds: 5) { for await _ in started { return }; throw TalkError.timedOut }
        let extra = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
        await #expect(throws: TalkError.busy) { try await store.insert(extra) }
        await provider.stop()
        resume.yield(())
        await #expect(throws: TalkError.disconnected) { try await approval.value }
        #expect(await provider.endpoints().isEmpty)
        try await provider.restore() // completed save is recovered explicitly
        #expect(await provider.endpoints().count == 1)
        await provider.stop(); begin.finish(); resume.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func slowIntegrationOverflowDoesNotInterruptAnotherSubscriber() async throws {
        let provider = TalkProvider(store: IntegrationStore(persistence: MemoryIntegrations()), contract: StudioAPI.schema,
                                    subscriptionAction: StudioAPI.observe) { _, _ in
            try .encoding(StudioSnapshot(sessionID: UUID(), revision: 0, selectedSceneID: "focus"))
        }
        try await provider.restore()
        var clients: [StudioClient] = []
        for _ in 0..<2 {
            let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
            try await provider.approve(record)
            let endpoints = await provider.endpoints()
            let port = try #require(endpoints[record.credential.id])
            let client = StudioClient(transport: try TalkClient(port: port, credential: record.credential))
            try await client.connect(); _ = try await client.subscribe(); clients.append(client)
        }
        let slow = clients[0], fast = clients[1]
        var fastEvents = fast.transport.events.makeAsyncIterator()
        for revision in 1...65 {
            let snapshot = StudioSnapshot(sessionID: UUID(), revision: Int64(revision), selectedSceneID: "focus")
            await provider.publish(action: StudioAPI.changed, payload: try .encoding(snapshot))
            let event = try await fastEvents.next()
            #expect(event?.action == StudioAPI.changed)
            if revision < 65 { _ = try await slow.snapshot() }
        }
        let count = try await confirmedSlowConsumerOverflow(slow)
        #expect(count == 64)
        _ = try await fast.selectScene(SelectScene(id: "focus"))
        for client in clients { await client.transport.close() }
        await provider.stop()
    }
}

/// The fast consumer cannot prove delivery to a different connection. A final
/// read-only request follows the 65th queued event on the slow connection; it
/// must fail before we start draining, otherwise draining can prevent overflow.
func confirmedSlowConsumerOverflow(_ slow: StudioClient) async throws -> Int {
    do { _ = try await slow.snapshot(); throw TalkError.invalidMessage }
    catch TalkError.eventOverflow { }
    catch TalkError.disconnected { }
    return try await withDeadline(seconds: 5) {
        var count = 0
        do { for try await _ in slow.transport.events { count += 1 } }
        catch TalkError.eventOverflow { return count }
        throw TalkError.invalidMessage
    }
}
