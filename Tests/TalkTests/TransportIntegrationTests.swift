import Foundation
import Network
import Testing
import StudioContract
@testable import Talk

struct TransportIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func approvedCallsEventsAndReconnect() async throws {
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["read", "write", "observe"])
        let counter = InvocationCounter()
        let server = TalkServer(record: record, actions: ["read": "read", "write": "write", "observe": "observe"], subscriptionAction: "observe") { action, _ in
            if action == "write" { await counter.increment() }
            return .integer(Int64(await counter.value))
        }
        let port = try await server.start()
        let client = try TalkClient(port: port, credential: record.credential)
        do {
            try await client.connect()
            for expected in 1...3 {
                #expect(try await client.request(action: "write") == .integer(Int64(expected)))
            }
            #expect(try await client.request(action: "observe") == .integer(3))
            await server.publish(action: "changed", payload: .string("focus"))
            let event = try await withDeadline(seconds: 5) {
                for try await event in client.events { return event }
                throw TalkError.disconnected
            }
            #expect(event.payload == .string("focus"))
            await client.close()
            let reconnect = try TalkClient(port: port, credential: record.credential)
            try await reconnect.connect()
            #expect(try await reconnect.request(action: "write") == .integer(4))
            await reconnect.close()
            #expect(await counter.value == 4)
            await server.stop()
        } catch { await client.close(); await server.stop(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func wrongCredentialCannotDispatch(copyPublicID: Bool) async throws {
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["write"])
        let counter = InvocationCounter()
        let server = TalkServer(record: record, actions: ["write": "write"]) { _, _ in
            await counter.increment(); return .null
        }
        let port = try await server.start()
        let wrong = try PairingCredential()
        let attackerCredential: PairingCredential
        if copyPublicID {
            let encoded = try JSONSerialization.data(withJSONObject: ["id": record.credential.id.uuidString, "secret": wrong.secret.base64EncodedString()])
            attackerCredential = try JSONDecoder().decode(PairingCredential.self, from: encoded)
        } else { attackerCredential = wrong }
        let attacker = try TalkClient(port: port, credential: attackerCredential)
        do {
            try await attacker.connect()
            Issue.record("TLS accepted an unrelated credential")
        } catch { #expect(await counter.value == 0) }
        await attacker.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func missingScopeAndRevocationDenyCalls() async throws {
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["read"])
        let counter = InvocationCounter()
        let server = TalkServer(record: record, actions: ["read": "read", "write": "write"]) { _, _ in
            await counter.increment(); return .null
        }
        let port = try await server.start()
        let client = try TalkClient(port: port, credential: record.credential)
        do {
            try await client.connect()
            do { _ = try await client.request(action: "write"); Issue.record("Unapproved scope dispatched") }
            catch { #expect(error as? TalkError == .permissionDenied) }
            #expect(await counter.value == 0)
            await server.stop()
            do { _ = try await client.request(action: "read"); Issue.record("Revoked session accepted a call") }
            catch { #expect(await counter.value == 0) }
            await client.close()
        } catch { await client.close(); await server.stop(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func setupCodeDeliversDifferentDurableCredentialOnlyOnce() async throws {
        let host = PairingHost()
        let approvals = InvocationCounter()
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["read"])
        let invitation = try await host.start(providerBundleID: record.providerBundleID) {
            await approvals.increment()
            return record
        }
        do {
            let paired = try await PairingClient.pair(using: invitation)
            #expect(paired == record)
            #expect(paired.credential.id != invitation.credential.id)
            do { _ = try await PairingClient.pair(using: invitation); Issue.record("Setup code was reused") }
            catch { #expect(await approvals.value == 1) }
            await host.stop()
        } catch { await host.stop(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func pairingDenialIsTyped() async throws {
        let host = PairingHost()
        let invitation = try await host.start(providerBundleID: "dev.example.provider") { throw TalkError.permissionDenied }
        do { _ = try await PairingClient.pair(using: invitation); Issue.record("Denied pairing succeeded") }
        catch { #expect(error as? TalkError == .permissionDenied) }
        await host.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func disconnectDuringMutationDoesNotRetry() async throws {
        let (started, began) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let counter = InvocationCounter()
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.example.provider", scopes: ["write"])
        let server = TalkServer(record: record, actions: ["write": "write"]) { _, _ in
            await counter.increment()
            began.yield(())
            for await _ in release { break }
            return .null
        }
        let port = try await server.start()
        let client = try TalkClient(port: port, credential: record.credential)
        try await client.connect()
        let request = Task { try await client.request(action: "write") }
        do {
            try await withDeadline(seconds: 5) { for await _ in started { return }; throw TalkError.timedOut }
            await server.stop()
            do { _ = try await request.value; Issue.record("Disconnected mutation reported success") }
            catch { #expect(error as? TalkError == .disconnected) }
            #expect(await counter.value == 1)
        } catch {
            request.cancel(); resume.finish(); await client.close(); await server.stop(); throw error
        }
        began.finish(); resume.finish(); await client.close()
    }
}

private actor InvocationCounter {
    var value = 0
    func increment() { value += 1 }
}
