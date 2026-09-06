import Foundation
import os
import Testing
@testable import Talk

struct StorageRecoveryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func unresolvedMutationRecoversWithoutReplay(cancel: Bool) async throws {
        let backend = DelayedArchive(timeout: cancel ? 30 : 0.05)
        defer { backend.release.signal() }
        let store = IntegrationStore(persistence: backend)
        #expect(try await store.reload().isEmpty)
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: ["read"])
        let operation = Task { try await store.insert(record) }
        try await withDeadline(seconds: 5) { for await _ in backend.started { return }; throw TalkError.timedOut }
        if cancel { operation.cancel() }
        await #expect(throws: TalkError.credentialOperationPending) { try await withDeadline(seconds: 1) { try await operation.value } }
        await #expect(throws: TalkError.credentialOperationPending) { try await store.insert(record) }
        await #expect(throws: TalkError.credentialOperationPending) { try await store.reload() }
        #expect(backend.mutations == 1)
        backend.release.signal()
        let recovered = try await withDeadline(seconds: 5) {
            while true {
                do { return try await store.reload() }
                catch TalkError.credentialOperationPending { try await Task.sleep(nanoseconds: 2_000_000) }
            }
        }
        #expect(recovered == [record])
        #expect(backend.mutations == 1) // only explicit read recovery, no automatic save replay
    }

    @Test(.timeLimit(.minutes(1)))
    func unresolvedOperationsRetainFourProcessSlots() async throws {
        let operations = KeychainOperations()
        let gates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
        defer { for gate in gates { gate.signal() } }
        for (index, gate) in gates.enumerated() {
            await #expect(throws: TalkError.credentialOperationPending) {
                try await operations.perform(key: "synthetic-\(index)", timeout: 0.02) { gate.wait(); return nil }
            }
        }
        await #expect(throws: TalkError.credentialOperationPending) {
            try await operations.perform(key: "fifth") { Issue.record("Exceeded blocking-operation limit"); return nil }
        }
        for gate in gates { gate.signal() }
        try await withDeadline(seconds: 5) {
            while true {
                do { _ = try await operations.perform(key: "recovered") { nil }; return }
                catch TalkError.credentialOperationPending { try await Task.sleep(nanoseconds: 2_000_000) }
            }
        }
    }
}

private final class DelayedArchive: IntegrationPersistence, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (data: Data(), mutations: 0))
    private let operations = KeychainOperations()
    private let timeout: Double
    let release = DispatchSemaphore(value: 0)
    let started: AsyncStream<Void>
    private let begin: AsyncStream<Void>.Continuation
    init(timeout: Double) { self.timeout = timeout; (started, begin) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1)) }
    var mutations: Int { state.withLock { $0.mutations } }
    func loadRecords() async throws -> [PairingRecord] {
        let data = try await operations.perform(key: "archive") { self.state.withLock { $0.data } }
        guard let data, !data.isEmpty else { return [] }
        return try IntegrationArchive.decode(data)
    }
    func saveRecords(_ records: [PairingRecord]) async throws {
        let data = try IntegrationArchive.encode(records)
        _ = try await operations.perform(key: "archive", timeout: timeout) {
            self.state.withLock { $0.mutations += 1 }
            self.begin.yield(())
            self.release.wait() // models a noncancellable Security call, off cooperative executors
            self.state.withLock { $0.data = data }
            return nil
        }
    }
}
