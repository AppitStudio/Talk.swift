import CryptoKit
import Foundation
import Testing
@testable import Talk

@MainActor
struct IntegrationConnectionTests {
    @MainActor final class Harness {
        static let provider = VerifiedApplication(identity: AppIdentity(bundleID: "dev.test.provider", teamID: "TESTTEAM"),
                                                  applicationURL: URL(fileURLWithPath: "/Applications/Provider.app"), processIdentifier: 10)
        static let consumer = VerifiedApplication(identity: AppIdentity(bundleID: "dev.test.consumer", teamID: "TESTTEAM"),
                                                  applicationURL: URL(fileURLWithPath: "/Applications/Consumer.app"), processIdentifier: 11)
        var approvals = 0
        var urls: [URL] = []
        var allowed = true
        var waiting = false
        var wrongSender = false
        var wrongScopes = false
        var decision: AsyncStream<Bool>.Continuation?
        let requested = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        lazy var host: IntegrationConnectionHost = IntegrationConnectionHost(providerBundleID: Self.provider.identity.bundleID, lifetime: 5, send: { [weak self] url, _ in
            guard let self else { return }
            self.urls.append(url)
            self.client.receive(AuthenticatedAppMessage(url: url, sender: self.wrongSender ? Self.consumer : Self.provider))
        }, approve: { [weak self] request in
            guard let self else { throw TalkError.unavailable }
            return try await self.approve(request)
        })
        lazy var client: IntegrationConnection = IntegrationConnection(timeout: 0.25, launch: { _, identity in
            #expect(identity == Self.provider.identity)
            return Self.provider
        }, send: { [weak self] url, _ in
            self?.urls.append(url)
            self?.host.receive(AuthenticatedAppMessage(url: url, sender: Self.consumer))
        })
        func approve(_ request: IntegrationConnectionHost.Request) async throws -> PairingRecord {
            approvals += 1
            #expect(request.consumer.identity == Self.consumer.identity)
            #expect(request.scopes == ["read"])
            if waiting {
                let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
                decision = continuation
                requested.continuation.yield(())
                let result = await withTaskCancellationHandler {
                    for await value in stream { return value }
                    return false
                } onCancel: { continuation.finish() }
                if Task.isCancelled { cancelled.continuation.yield(()) }
                try Task.checkCancellation()
                guard result else { throw TalkError.permissionDenied }
            }
            guard allowed else { throw TalkError.permissionDenied }
            return PairingRecord(credential: try PairingCredential(), providerBundleID: Self.provider.identity.bundleID,
                                 scopes: wrongScopes ? ["read", "write"] : request.scopes,
                                 replacesID: request.replacesID, consumerIdentity: request.consumer.identity)
        }
        func connect(replacing: UUID? = nil) async throws -> PairingRecord {
            try await client.connect(applicationURL: Self.provider.applicationURL, provider: Self.provider.identity,
                                     consumerBundleID: Self.consumer.identity.bundleID, scopes: ["read"], replacing: replacing)
        }
    }

    @Test(arguments: [true, false]) func connectNeedsNoPairingModeOrCode(allowed: Bool) async throws {
        let h = Harness(); h.allowed = allowed
        if allowed {
            let record = try await h.connect()
            #expect(record.scopes == ["read"])
            #expect(record.consumerIdentity == Harness.consumer.identity)
        } else {
            await #expect(throws: TalkError.permissionDenied) { try await h.connect() }
        }
        #expect(h.approvals == 1)
        #expect(h.urls.count == 2)
        #expect(h.urls.allSatisfy { !$0.absoluteString.contains("secret") && !$0.absoluteString.contains("verification") })
        await h.host.stop()
    }

    @Test func stoppedHostAndWrongSenderCannotGrant() async throws {
        let h = Harness(); h.wrongSender = true
        await #expect(throws: TalkError.timedOut) { try await h.connect() }
        #expect(h.approvals == 0)
        await h.host.stop()
        h.wrongSender = false
        await #expect(throws: TalkError.timedOut) { try await h.connect() }
        #expect(h.approvals == 0)
    }

    @Test func replayDoesNotCreateAnotherGrant() async throws {
        let h = Harness()
        _ = try await h.connect()
        let request = try #require(h.urls.first)
        h.host.receive(AuthenticatedAppMessage(url: request, sender: Harness.consumer))
        #expect(h.urls.count == 2)
        #expect(h.approvals == 1)
        // A fresh deliberate attempt works without restarting the provider host.
        _ = try await h.connect()
        #expect(h.approvals == 2)
        await h.host.stop()
    }

    @Test func providerCannotExpandRequestedScopes() async throws {
        let h = Harness(); h.wrongScopes = true
        await #expect(throws: TalkError.permissionDenied) { try await h.connect() }
        await h.host.stop()
    }

    @Test(arguments: [true, false]) func cancellationDismissesConsent(fromConsumer: Bool) async throws {
        let h = Harness(); h.waiting = true
        let task = Task { try await h.connect() }
        try await withDeadline(seconds: 3) { for await _ in h.requested.stream { return } }
        if fromConsumer { task.cancel() } else { await h.host.stop() }
        do { _ = try await task.value; Issue.record("Cancelled request returned a grant") } catch { }
        try await withDeadline(seconds: 3) { for await _ in h.cancelled.stream { return } }
        await h.host.stop()
    }

    @Test func scopeAndReplacementBoundToKeyExchange() throws {
        let provider = Curve25519.KeyAgreement.PrivateKey(), consumer = Curve25519.KeyAgreement.PrivateKey()
        let session = UUID(), request = UUID()
        let scopes = try IntegrationConnectionWire.encodeScopes(["read"])
        func derive(_ scopes: String, replacing: UUID?) throws -> PairingCredential {
            try IntegrationConnectionWire.credential(privateKey: provider, peerPublicKey: consumer.publicKey.rawRepresentation,
                providerKey: provider.publicKey.rawRepresentation, consumerKey: consumer.publicKey.rawRepresentation,
                session: session, request: request, provider: "dev.test.provider", consumer: "dev.test.consumer", scopes: scopes, replacing: replacing)
        }
        let original = try derive(scopes, replacing: nil)
        #expect(original != (try derive(IntegrationConnectionWire.encodeScopes(["write"]), replacing: nil)))
        #expect(original != (try derive(scopes, replacing: UUID())))
        #expect(throws: TalkError.invalidMessage) { try IntegrationConnectionWire.encodeScopes([]) }
        let duplicates = Data("[\"read\",\"read\"]".utf8).base64EncodedString()
        #expect(throws: TalkError.invalidMessage) { try IntegrationConnectionWire.decodeScopes(duplicates) }
    }

    @Test func offerMustMatchAuthenticatedProvider() throws {
        let id = UUID(), old = UUID()
        let fields = ["request": id.uuidString, "provider": Harness.provider.identity.bundleID,
                      "scopes": try IntegrationConnectionWire.encodeScopes(["read"]), "replacing": old.uuidString]
        let url = PairingRouting.url(scheme: "talk-spike-consumer", host: "integration-offer", fields: fields)
        let request = try #require(IntegrationConnectionRequest.parse(AuthenticatedAppMessage(url: url, sender: Harness.provider)))
        #expect(request.id == id && request.replacesID == old && request.scopes == ["read"])
        #expect(IntegrationConnectionRequest.parse(AuthenticatedAppMessage(url: url, sender: Harness.consumer)) == nil)
    }

    @Test func savedLegacyGrantsDecodeWithoutMigration() throws {
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.test.provider", scopes: ["read"])
        let data = try IntegrationArchive.encode([record])
        #expect(!String(decoding: data, as: UTF8.self).contains("consumerIdentity"))
        #expect(try IntegrationArchive.decode(data) == [record])
    }

    @Test func replacementCannotStealAnotherConsumersGrant() async throws {
        let store = IntegrationStore(persistence: MemoryIntegrations())
        _ = try await store.reload()
        let original = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.test.provider", scopes: ["read"],
                                     consumerIdentity: Harness.consumer.identity)
        try await store.insert(original)
        let impostor = PairingRecord(credential: try PairingCredential(), providerBundleID: original.providerBundleID, scopes: ["read"],
                                     replacesID: original.credential.id, consumerIdentity: Harness.provider.identity)
        await #expect(throws: TalkError.permissionDenied) { try await store.insert(impostor) }
        #expect(try await store.all() == [original])
    }
}
