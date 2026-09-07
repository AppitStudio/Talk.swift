import CryptoKit
import Foundation
import Testing
@testable import Talk

@MainActor
struct DiscoverablePairingTests {
    @MainActor final class Harness {
        static let providerID = "dev.example.provider"
        static let consumerID = "dev.example.consumer"
        static let application = URL(fileURLWithPath: "/Applications/Example.app")
        var urls: [URL] = []
        var verification: String?
        var approvals = 0
        var allowed = true
        var callbackAvailable = true
        var suspendApproval = false
        var decision: AsyncStream<Bool>.Continuation?
        let requested = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        lazy var host: DiscoverablePairingHost = DiscoverablePairingHost(send: { [weak self] url, _ in
            self?.urls.append(url)
            self?.discovery.receive(url)
        }, callback: { [weak self] _ in self?.callbackAvailable == true ? Self.application : nil })
        lazy var discovery: PairingDiscovery = PairingDiscovery(timeout: 0.5, send: { [weak self] url, _ in
            self?.urls.append(url)
            self?.host.receive(url)
        })

        func start(lifetime: Double = 30) throws {
            try host.start(providerBundleID: Self.providerID, allowedCallbackBundleIDs: [Self.consumerID], lifetime: lifetime) { [weak self] request in
                guard let self else { throw TalkError.unavailable }
                return try await self.approve(request)
            }
        }
        func approve(_ request: DiscoverablePairingHost.Request) async throws -> PairingRecord {
            approvals += 1
            #expect(request.consumerBundleID == Self.consumerID)
            #expect(request.verificationCode == verification)
            if suspendApproval {
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
            return PairingRecord(credential: try PairingCredential(), providerBundleID: Self.providerID, scopes: ["read"])
        }
        func discover() async throws -> PairingDiscovery.Candidate {
            try await discovery.discover(applicationURL: Self.application, providerBundleID: Self.providerID, callbackBundleID: Self.consumerID)
        }
        func connect(_ candidate: PairingDiscovery.Candidate) async throws -> PairingRecord {
            try await discovery.connect(to: candidate, callbackBundleID: Self.consumerID) { verification = $0 }
        }
    }

    @Test func discoveryOnlyDuringExplicitMode() async throws {
        let h = Harness()
        await #expect(throws: TalkError.timedOut) { try await h.discover() }
        #expect(h.urls.count == 1)
        try h.start()
        _ = try await h.discover()
        #expect(h.host.isDiscoverable)
        await h.host.stop()
        let count = h.urls.count
        await #expect(throws: TalkError.timedOut) { try await h.discover() }
        #expect(h.urls.count == count + 1)
        #expect(h.approvals == 0)
    }

    @Test(arguments: [true, false]) func encryptedGrantRequiresConsent(allowed: Bool) async throws {
        let h = Harness()
        h.allowed = allowed
        try h.start()
        let candidate = try await h.discover()
        if allowed {
            let record = try await h.connect(candidate)
            #expect(record.scopes == ["read"])
            #expect(record.providerBundleID == Harness.providerID)
            #expect(record.credential.id != candidate.id)
        } else {
            await #expect(throws: TalkError.permissionDenied) { try await h.connect(candidate) }
        }
        #expect(h.approvals == 1)
        #expect(h.verification?.count == 14)
        #expect(!h.host.isDiscoverable)
        // Consumed sessions never accept a second exchange or disclose credentials.
        await #expect(throws: TalkError.timedOut) { try await h.connect(candidate) }
        #expect(h.approvals == 1)
        #expect(h.urls.allSatisfy { !$0.absoluteString.contains("secret") && !$0.absoluteString.contains("talk-pair-v1") })
        await h.host.stop()
    }

    @Test func expiredAndPreviousSessionsCannotConnect() async throws {
        let h = Harness()
        try h.start()
        let old = try await h.discover()
        await h.host.stop()
        try h.start()
        let current = try await h.discover()
        #expect(current.id != old.id)
        await #expect(throws: TalkError.timedOut) { try await h.connect(old) }
        #expect(h.host.isDiscoverable)
        _ = try await h.connect(current)
        await h.host.stop()
        try h.start(lifetime: 0.05)
        let short = try await h.discover()
        try await DeadlineTimer.sleep(seconds: 0.1)
        #expect(!h.host.isDiscoverable)
        await #expect(throws: TalkError.invitationExpired) { try await h.connect(short) }
        await h.host.stop()
    }

    @Test(arguments: [true, false]) func cancellationDismissesPendingConsent(fromConsumer: Bool) async throws {
        let h = Harness()
        h.suspendApproval = true
        try h.start()
        let candidate = try await h.discover()
        let task = Task { try await h.connect(candidate) }
        try await withDeadline(seconds: 5) {
            for await _ in h.requested.stream { return }
        }
        if fromConsumer { task.cancel() } else { await h.host.stop() }
        do { _ = try await task.value; Issue.record("Cancelled pairing returned a grant") } catch { }
        try await withDeadline(seconds: 5) {
            for await _ in h.cancelled.stream { return }
        }
        #expect(h.approvals == 1)
        await h.host.stop()
    }

    @Test func rejectsAmbiguousCallbackAndUnlistedConsumer() async throws {
        let h = Harness()
        try h.start()
        h.callbackAvailable = false
        await #expect(throws: TalkError.timedOut) { try await h.discover() }
        h.callbackAvailable = true
        await #expect(throws: TalkError.timedOut) {
            try await h.discovery.discover(applicationURL: Harness.application, providerBundleID: Harness.providerID,
                                           callbackBundleID: "dev.example.unlisted")
        }
        #expect(h.approvals == 0)
        await h.host.stop()
    }

    @Test func keyAgreementBindsKeysRolesAndSession() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let session = UUID(), request = UUID()
        func derive(_ key: Curve25519.KeyAgreement.PrivateKey, peer: Data, id: UUID, consumer: String = Harness.consumerID) throws -> PairingKeyExchange.Result {
            try PairingKeyExchange.derive(privateKey: key, peerPublicKey: peer,
                providerPublicKey: a.publicKey.rawRepresentation, consumerPublicKey: b.publicKey.rawRepresentation,
                sessionID: id, requestID: request, providerBundleID: Harness.providerID, consumerBundleID: consumer)
        }
        let server = try derive(a, peer: b.publicKey.rawRepresentation, id: session)
        let client = try derive(b, peer: a.publicKey.rawRepresentation, id: session)
        #expect(server.credential == client.credential)
        #expect(server.verificationCode == client.verificationCode)
        #expect(try derive(a, peer: b.publicKey.rawRepresentation, id: UUID()).credential != client.credential)
        #expect(try derive(a, peer: b.publicKey.rawRepresentation, id: session, consumer: "dev.example.other").verificationCode != client.verificationCode)
        #expect(throws: (any Error).self) { try derive(a, peer: Data(repeating: 0, count: 32), id: session) }
    }

    @Test func publicRoutingRejectsDuplicateAndOversizedFields() throws {
        let good = PairingRouting.url(scheme: "talk-spike-provider", host: "pairing-discover",
                                      fields: ["request": UUID().uuidString, "callback": Harness.consumerID])
        #expect(PairingRouting.fields(good, scheme: "talk-spike-provider", host: "pairing-discover", names: ["request", "callback"]) != nil)
        for suffix in ["&request=duplicate", "#fragment", "&extra=1", "&huge=" + String(repeating: "x", count: 2048)] {
            let url = try #require(URL(string: good.absoluteString + suffix))
            #expect(PairingRouting.fields(url, scheme: "talk-spike-provider", host: "pairing-discover", names: ["request", "callback"]) == nil)
        }
    }

    @Test func rejectsInvalidLifetimeAndAllowsRetryAfterValidationFailure() async throws {
        let h = Harness()
        for lifetime in [0, -1, 301, .infinity, .nan] {
            #expect(throws: TalkError.invalidInvitation) { try h.start(lifetime: lifetime) }
        }
        try h.start()
        #expect(throws: TalkError.busy) { try h.start() }
        await h.host.stop()
    }

    @Test func discoveryReplyFloodIsBoundedWithoutEnablingConsent() async throws {
        let h = Harness()
        try h.start()
        let request = PairingRouting.url(scheme: "talk-spike-provider", host: "pairing-discover",
                                         fields: ["request": UUID().uuidString, "callback": Harness.consumerID])
        for _ in 0..<100 { h.host.receive(request) }
        #expect(h.urls.count == 32)
        #expect(h.approvals == 0)
        await h.host.stop()
    }

    @Test(arguments: ["provider", "key", "expires"])
    func consumerRejectsInvalidDiscoveryHints(field: String) async throws {
        let h = Harness()
        try h.start()
        let candidate = try await h.discover()
        let endpoint = try #require(h.urls.last)
        let fields = try #require(PairingRouting.fields(endpoint, scheme: "talk-spike-consumer", host: "pairing-available",
                                                        names: ["request", "session", "provider", "key", "expires"]))
        var corrupt = fields
        corrupt[field] = field == "expires" ? "nan" : "invalid"
        var client: PairingDiscovery?
        client = PairingDiscovery(timeout: 0.5, send: { url, _ in
            guard let request = PairingRouting.fields(url, scheme: "talk-spike-provider", host: "pairing-discover",
                                                      names: ["request", "callback"])?["request"] else { return }
            var reply = corrupt
            reply["request"] = request
            client?.receive(PairingRouting.url(scheme: "talk-spike-consumer", host: "pairing-available", fields: reply))
        })
        let discovery = try #require(client)
        await #expect(throws: TalkError.invalidInvitation) {
            try await discovery.discover(applicationURL: candidate.applicationURL, providerBundleID: Harness.providerID,
                                           callbackBundleID: Harness.consumerID)
        }
        client = nil
        #expect(h.approvals == 0)
        await h.host.stop()
    }
}
