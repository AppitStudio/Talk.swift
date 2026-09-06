import Foundation
import Testing
@testable import Talk

struct ResourceLimitTests {
    private func record() throws -> PairingRecord {
        PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["read", "observe"])
    }

    @Test(.timeLimit(.minutes(1)))
    func disconnectCancelsPendingPairingApproval() async throws {
        let (entered, begin) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let (cancelled, end) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let host = PairingHost()
        let invitation = try await host.start(providerBundleID: "dev.example.provider") {
            begin.yield(())
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { end.yield(()); throw error }
            throw TalkError.permissionDenied
        }
        let pairing = Task { try await PairingClient.pair(using: invitation) }
        do {
            try await withDeadline(seconds: 5) { for await _ in entered { return }; throw TalkError.timedOut }
            pairing.cancel()
            _ = await pairing.result
            try await withDeadline(seconds: 5) { for await _ in cancelled { return }; throw TalkError.timedOut }
        } catch { pairing.cancel(); await host.stop(); throw error }
        begin.finish(); end.finish(); await host.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateRequestIDCannotDispatchTwice() async throws {
        let grant = try record()
        let server = TalkServer(record: grant, actions: ["read": "read"]) { _, _ in .null }
        let connection = try TalkConnection(port: try await server.start(), credential: grant.credential)
        do {
            try await connection.start()
            let message = TalkMessage(kind: .request, action: "read")
            try await connection.send(message)
            #expect(try await connection.receive().id == message.id)
            try await connection.send(message)
            await #expect(throws: TalkError.disconnected) { try await connection.receive() }
        } catch { await connection.close(); await server.stop(); throw error }
        await connection.close(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingCallsAreBounded() async throws {
        let grant = try record()
        let (entered, begin) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let server = TalkServer(record: grant, actions: ["read": "read"]) { _, _ in
            begin.yield(())
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .null
        }
        let client = try TalkClient(port: try await server.start(), credential: grant.credential)
        try await client.connect()
        let requests = (0..<16).map { _ in Task { try await client.request(action: "read") } }
        do {
            try await withDeadline(seconds: 5) {
                var count = 0
                for await _ in entered { count += 1; if count == 16 { return } }
                throw TalkError.timedOut
            }
            await #expect(throws: TalkError.busy) { try await client.request(action: "read") }
        } catch {
            for task in requests { task.cancel() }
            await client.close(); await server.stop(); throw error
        }
        for task in requests { task.cancel() }
        for task in requests { _ = await task.result }
        begin.finish(); await client.close(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func subscriptionStagesEventsUntilSnapshotSucceeds(deny: Bool) async throws {
        let grant = try record()
        let (entered, begin) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let server = TalkServer(record: grant, actions: ["observe": "observe", "read": "read"], subscriptionAction: "observe") { action, _ in
            if action == "observe" {
                begin.yield(())
                for await _ in release { break }
                try Task.checkCancellation()
                if deny { throw TalkError.invalidMessage }
            }
            return .integer(0)
        }
        let client = try TalkClient(port: try await server.start(), credential: grant.credential)
        try await client.connect()
        let subscription = Task { try await client.request(action: "observe") }
        do {
            try await withDeadline(seconds: 5) { for await _ in entered { return }; throw TalkError.timedOut }
            await server.publish(action: "changed", payload: .integer(1))
            await server.publish(action: "changed", payload: .integer(2))
            resume.yield(())
            if deny {
                await #expect(throws: TalkError.invalidMessage) { try await subscription.value }
            } else { #expect(try await subscription.value == .integer(0)) }
            _ = try await client.request(action: "read")
            await client.close()
            var values: [JSONValue] = []
            do { for try await message in client.events { values.append(message.payload) } } catch { }
            #expect(values == (deny ? [] : [.integer(1), .integer(2)]))
        } catch {
            subscription.cancel(); resume.finish(); await client.close(); await server.stop(); throw error
        }
        begin.finish(); resume.finish(); await server.stop()
    }
}
