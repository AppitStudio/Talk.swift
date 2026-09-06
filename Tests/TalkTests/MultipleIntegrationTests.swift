import Foundation
import Testing
import StudioContract
@testable import Talk

actor MemoryIntegrations: IntegrationPersistence {
    private var data: Data = Data()
    var failAfterWrite = false
    func setFailure(_ enabled: Bool) { failAfterWrite = enabled }
    func loadRecords() throws -> [PairingRecord] { data.isEmpty ? [] : try IntegrationArchive.decode(data) }
    func saveRecords(_ records: [PairingRecord]) throws {
        data = try IntegrationArchive.encode(records)
        if failAfterWrite { throw TalkError.credentialOperationPending }
    }
}

struct MultipleIntegrationTests {
    private func grant(_ scopes: Set<String>, replacing: UUID? = nil) throws -> PairingRecord {
        PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: scopes, replacesID: replacing)
    }
    private func provider(_ persistence: MemoryIntegrations, handler: TalkServer.Handler? = nil) -> TalkProvider {
        TalkProvider(store: IntegrationStore(persistence: persistence), contract: StudioAPI.schema, subscriptionAction: StudioAPI.observe,
                     handler: handler ?? { _, _ in try .encoding(StudioSnapshot(sessionID: UUID(), revision: 1, selectedSceneID: "focus")) })
    }
    private func client(_ provider: TalkProvider, _ record: PairingRecord) async throws -> StudioClient {
        let endpoints = await provider.endpoints()
        let port = try #require(endpoints[record.credential.id])
        let client = StudioClient(transport: try TalkClient(port: port, credential: record.credential))
        try await client.connect()
        return client
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentProvidersScopesRevocationAndRestart() async throws {
        let storage = MemoryIntegrations()
        let first = provider(storage)
        let second = provider(MemoryIntegrations())
        try await first.restore(); try await second.restore()
        let read = try grant([StudioAPI.read])
        let full = try grant(StudioAPI.scopes)
        let independent = try grant(StudioAPI.scopes)
        try await first.approve(read); try await first.approve(full); try await second.approve(independent)
        let a = try await client(first, read)
        let b = try await client(first, full)
        let c = try await client(second, independent)
        do {
            async let ar = a.snapshot()
            async let br = b.subscribe()
            async let cr = c.subscribe()
            _ = try await (ar, br, cr)
            await #expect(throws: TalkError.permissionDenied) { try await a.selectScene(SelectScene(id: "focus")) }
            await #expect(throws: TalkError.permissionDenied) { try await a.subscribe() }
            let value = StudioSnapshot(sessionID: UUID(), revision: 2, selectedSceneID: "away")
            await first.publish(action: StudioAPI.changed, payload: try .encoding(value))
            let event = try await withDeadline(seconds: 5) {
                for try await event in b.transport.events { return event }
                throw TalkError.disconnected
            }
            #expect(event.action == StudioAPI.changed)
            _ = try await a.snapshot() // ordered response barrier
            await a.transport.close()
            var deniedEvents = 0
            do { for try await _ in a.transport.events { deniedEvents += 1 } } catch { }
            #expect(deniedEvents == 0)
            try await first.revoke(full.credential.id)
            await #expect(throws: (any Error).self) { try await b.snapshot() }
            _ = try await c.selectScene(SelectScene(id: "focus"))
            await first.stop()
            let restarted = provider(storage)
            try await restarted.restore()
            #expect(await restarted.integrations().count == 1)
            let restored = try await client(restarted, read)
            _ = try await restored.snapshot()
            await #expect(throws: TalkError.permissionDenied) { try await restored.subscribe() }
            await restored.transport.close(); await restarted.stop()
        } catch {
            await a.transport.close(); await b.transport.close(); await c.transport.close()
            await first.stop(); await second.stop(); throw error
        }
        await a.transport.close(); await b.transport.close(); await c.transport.close()
        await first.stop(); await second.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func individualRevocationCancelsActivityAndScopeReplacementRotatesKey() async throws {
        let (started, begin) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let (cancelled, end) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let service = provider(MemoryIntegrations()) { action, payload in
            if action == StudioAPI.select, try payload.decode(SelectScene.self).id == "suspended" {
                begin.yield(())
                do { try await Task.sleep(for: .seconds(30)) }
                catch { end.yield(()); throw error }
            }
            try Task.checkCancellation()
            return try .encoding(StudioSnapshot(sessionID: UUID(), revision: 1, selectedSceneID: "focus"))
        }
        try await service.restore()
        let a = try grant(StudioAPI.scopes), b = try grant([StudioAPI.read])
        try await service.approve(a); try await service.approve(b)
        let active = try await client(service, a), other = try await client(service, b)
        _ = try await active.subscribe()
        let request = Task { try await active.selectScene(SelectScene(id: "suspended")) }
        try await withDeadline(seconds: 5) { for await _ in started { return }; throw TalkError.timedOut }
        try await service.revoke(a.credential.id)
        await #expect(throws: (any Error).self) { try await request.value }
        try await withDeadline(seconds: 5) { for await _ in cancelled { return }; throw TalkError.timedOut }
        _ = try await other.snapshot()
        let replacement = try grant(StudioAPI.scopes, replacing: b.credential.id)
        try await service.approve(replacement) // explicitly consented replacement
        await #expect(throws: (any Error).self) { try await other.snapshot() }
        let next = try await client(service, replacement)
        _ = try await next.selectScene(SelectScene(id: "focus"))
        #expect(await service.integrations().count == 1)
        let endpoints = await service.endpoints()
        let port = try #require(endpoints[replacement.credential.id])
        let obsolete = try TalkClient(port: port, credential: b.credential)
        await #expect(throws: (any Error).self) { try await obsolete.connect() }
        await obsolete.close(); await active.transport.close(); await other.transport.close(); await next.transport.close()
        await service.stop(); begin.finish(); end.finish()
    }

    @Test func archiveBoundsAndUnresolvedRecovery() async throws {
        let old = try grant([StudioAPI.read])
        let data = try JSONEncoder().encode(old)
        #expect(throws: TalkError.credentialStorage) { try IntegrationArchive.decode(data) }
        let restored = try IntegrationArchive.decode(IntegrationArchive.encode([old]))
        #expect(restored == [old])
        #expect(throws: TalkError.credentialStorage) { try IntegrationArchive.encode([old, old]) }
        #expect(throws: TalkError.credentialStorage) { try IntegrationArchive.decode(Data("{\"version\":99,\"records\":[]}".utf8)) }
        let persistence = MemoryIntegrations(), store = IntegrationStore(persistence: MemoryIntegrations())
        _ = try await store.reload()
        for _ in 0..<16 { try await store.insert(grant([StudioAPI.read])) }
        await #expect(throws: TalkError.credentialStorage) { try await store.insert(grant([StudioAPI.read])) }
        let recovery = IntegrationStore(persistence: persistence)
        _ = try await recovery.reload(); try await recovery.insert(old)
        await persistence.setFailure(true)
        await #expect(throws: TalkError.credentialOperationPending) { try await recovery.remove(old.credential.id) }
        await #expect(throws: TalkError.credentialOperationPending) { try await recovery.insert(grant(StudioAPI.scopes)) }
        await persistence.setFailure(false)
        #expect(try await recovery.reload().isEmpty)
        try await recovery.insert(grant([StudioAPI.read]))
        #expect(try await recovery.all().count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedRevocationStopsOnlySelectedUntilRecovery() async throws {
        let storage = MemoryIntegrations(), service = provider(storage)
        try await service.restore()
        let first = try grant(StudioAPI.scopes), second = try grant(StudioAPI.scopes)
        try await service.approve(first); try await service.approve(second)
        let a = try await client(service, first), b = try await client(service, second)
        await storage.setFailure(true)
        await #expect(throws: TalkError.credentialOperationPending) { try await service.revoke(first.credential.id) }
        #expect(await service.integrations().filter { $0.state == .revocationPending }.count == 1)
        await #expect(throws: (any Error).self) { try await a.snapshot() }
        _ = try await b.snapshot()
        await storage.setFailure(false)
        try await service.restore()
        #expect(await service.integrations().count == 1)
        let recovered = try await client(service, second)
        _ = try await recovered.snapshot()
        await a.transport.close(); await b.transport.close(); await recovered.transport.close(); await service.stop()
    }

    @Test func movedDuplicateAndUnavailableInstallationsFailSafely() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let original = root.appending(path: "Original.app"), moved = root.appending(path: "Moved.app")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try ProviderDiscovery.uniqueInstallation([original, original]).path == original.path)
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(throws: TalkError.ambiguousProvider) { try ProviderDiscovery.uniqueInstallation([original, moved]) }
        #expect(throws: TalkError.unavailable) { try ProviderDiscovery.uniqueInstallation([original]) }
        #expect(try ProviderDiscovery.uniqueInstallation([moved]).path == moved.path)
    }
}
