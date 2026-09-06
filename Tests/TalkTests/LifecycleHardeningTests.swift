import Foundation
import Testing
import StudioContract
@testable import Talk

struct LifecycleHardeningTests {
    private func record() throws -> PairingRecord {
        PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["read", "write", "observe"])
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentGeneratedCallsAreCorrelated() async throws {
        let grant = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: StudioAPI.scopes)
        let server = TalkServer(record: grant, actions: StudioAPI.actions, contract: StudioAPI.schema) { _, payload in
            let selection = try payload.decode(SelectScene.self)
            await Task.yield()
            return try .encoding(StudioSnapshot(sessionID: UUID(), revision: 1, selectedSceneID: selection.id))
        }
        let client = try TalkClient(port: try await server.start(), credential: grant.credential)
        do {
            try await client.connect()
            let typed = StudioClient(transport: client)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<16 {
                    group.addTask {
                        let result = try await typed.selectScene(SelectScene(id: "scene-\(index)"))
                        #expect(result.selectedSceneID == "scene-\(index)")
                    }
                }
                try await group.waitForAll()
            }
        } catch { await client.close(); await server.stop(); throw error }
        await client.close(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationAndRevocationStopSuspendedMutation(revoke: Bool) async throws {
        let grant = try record()
        let (started, began) = AsyncStream<Void>.makeStream()
        let (cancelled, ended) = AsyncStream<Void>.makeStream()
        let mutations = Count()
        let server = TalkServer(record: grant, actions: ["write": "write"]) { _, _ in
            began.yield(())
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { ended.yield(()); throw error }
            try Task.checkCancellation()
            await mutations.increment()
            return .null
        }
        let client = try TalkClient(port: try await server.start(), credential: grant.credential)
        try await client.connect()
        let request = Task { try await client.request(action: "write") }
        do {
            try await signal(started)
            if revoke { await server.stop() } else { request.cancel() }
            do { _ = try await request.value; Issue.record("Cancelled mutation succeeded") }
            catch { #expect(error is CancellationError || error as? TalkError == .disconnected) }
            try await signal(cancelled)
            #expect(await mutations.value == 0)
        } catch { request.cancel(); await client.close(); await server.stop(); throw error }
        began.finish(); ended.finish(); await client.close(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func idleDisconnectAllowsFreshSessionWithoutNewGrant() async throws {
        let grant = try record()
        let server = TalkServer(record: grant, actions: ["read": "read"], idleTimeout: 0.1) { _, _ in .string("snapshot") }
        let port = try await server.start()
        let client = try TalkClient(port: port, credential: grant.credential)
        do {
            try await client.connect()
            _ = try await client.request(action: "read")
            do { try await withDeadline(seconds: 5) { for try await _ in client.events { }; throw TalkError.invalidMessage } }
            catch { #expect(error as? TalkError == .disconnected) }
            let next = try TalkClient(port: port, credential: grant.credential)
            try await next.connect()
            #expect(try await next.request(action: "read") == .string("snapshot"))
            await next.close()
        } catch { await client.close(); await server.stop(); throw error }
        await client.close(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func handlerDeadlineClosesAndCancelsActivity() async throws {
        let grant = try record()
        let (cancelled, ended) = AsyncStream<Void>.makeStream()
        let server = TalkServer(record: grant, actions: ["write": "write"], handlerTimeout: 0.1) { _, _ in
            do { try await Task.sleep(nanoseconds: 30_000_000_000); return .null }
            catch { ended.yield(()); throw error }
        }
        let client = try TalkClient(port: try await server.start(), credential: grant.credential)
        try await client.connect()
        do { _ = try await client.request(action: "write"); Issue.record("Handler deadline ignored") }
        catch { #expect(error as? TalkError == .disconnected) }
        try await signal(cancelled)
        ended.finish(); await client.close(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedSubscriptionDoesNotReceiveEvents() async throws {
        let grant = try record()
        let server = TalkServer(record: grant, actions: ["observe": "observe", "read": "read"], subscriptionAction: "observe") { action, _ in
            if action == "observe" { throw TalkError.invalidMessage }
            return .null
        }
        let client = try TalkClient(port: try await server.start(), credential: grant.credential)
        try await client.connect()
        do { _ = try await client.request(action: "observe"); Issue.record("Invalid subscription accepted") }
        catch { #expect(error as? TalkError == .invalidMessage) }
        await server.publish(action: "private", payload: .string("synthetic"))
        _ = try await client.request(action: "read") // ordered writer barrier
        await client.close()
        var delivered = 0
        do { for try await _ in client.events { delivered += 1 } } catch { }
        #expect(delivered == 0)
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func slowConsumerGetsExplicitEventOverflow() async throws {
        let grant = try record()
        let server = TalkServer(record: grant, actions: ["observe": "observe", "read": "read"], subscriptionAction: "observe") { _, _ in .null }
        let client = try TalkClient(port: try await server.start(), credential: grant.credential)
        try await client.connect()
        _ = try await client.request(action: "observe")
        for index in 0..<65 {
            await server.publish(action: "changed", payload: .integer(Int64(index)))
            do { _ = try await client.request(action: "read") }
            catch { #expect(index == 64); break }
        }
        var events = 0
        do { for try await _ in client.events { events += 1 }; Issue.record("Overflow was silent") }
        catch { #expect(error as? TalkError == .eventOverflow) }
        #expect(events == 64)
        await client.close(); await server.stop()
    }

    @Test func rejectsDeepJSONAndInvalidTimeout() async throws {
        let nested = Data((String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)).utf8)
        #expect(throws: TalkError.invalidMessage) { try FrameCodec.decode(nested) }
        for timeout in [0, -1, Double.infinity, Double.nan] {
            await #expect(throws: TalkError.invalidMessage) { try await withDeadline(seconds: timeout) { true } }
        }
    }

    private func signal(_ stream: AsyncStream<Void>) async throws {
        try await withDeadline(seconds: 5) { for await _ in stream { return }; throw TalkError.timedOut }
    }
}

private actor Count {
    var value = 0
    func increment() { value += 1 }
}
