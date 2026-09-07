import CryptoKit
import Foundation

/// Local app routing discovers only an explicitly enabled pairing mode. Keep one
/// instance and route `talk-spike-consumer` URLs to `receive`, alongside reconnect.
@MainActor
public final class PairingDiscovery {
    public struct Candidate: Sendable, Identifiable {
        public let id: UUID
        public let applicationURL: URL
        public let providerBundleID: String
        public let expiresAt: Date
        let publicKey: Data
    }
    private struct Pending {
        let host: String
        let continuation: AsyncThrowingStream<URL, any Error>.Continuation
    }
    private var pending: [UUID: Pending] = [:]
    private var connecting = false
    private let send: PairingRouting.Sender
    private let timeout: Double

    public init() { send = PairingRouting.send; timeout = 10 }
    init(timeout: Double = 10, send: @escaping PairingRouting.Sender) { self.timeout = timeout; self.send = send }

    /// `applicationURL` is selected by the app's installation policy. Labels and
    /// public keys from discovery are untrusted until the user compares codes.
    public func discover(applicationURL: URL, providerBundleID: String, callbackBundleID: String) async throws -> Candidate {
        guard PairingRouting.validBundleID(providerBundleID), PairingRouting.validBundleID(callbackBundleID) else {
            throw TalkError.invalidInvitation
        }
        let id = UUID()
        let url = PairingRouting.url(scheme: "talk-spike-provider", host: "pairing-discover", fields: [
            "request": id.uuidString, "callback": callbackBundleID
        ])
        let response = try await exchange(url, application: applicationURL, id: id, responseHost: "pairing-available")
        guard let fields = PairingRouting.fields(response, scheme: "talk-spike-consumer", host: "pairing-available",
                                                 names: ["request", "session", "provider", "key", "expires"]),
              fields["provider"] == providerBundleID,
              let session = fields["session"].flatMap(UUID.init(uuidString:)),
              let key = fields["key"].flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              let timestamp = fields["expires"].flatMap(Double.init), timestamp.isFinite else { throw TalkError.invalidInvitation }
        let deadline = Date(timeIntervalSince1970: timestamp)
        guard deadline > Date(), deadline.timeIntervalSinceNow <= 300 else { throw TalkError.invitationExpired }
        return Candidate(id: session, applicationURL: applicationURL, providerBundleID: providerBundleID,
                         expiresAt: deadline, publicKey: key)
    }

    /// Call only for the user's Connect action. Display the code until completion;
    /// provider consent must verify that exact code in both apps before approval.
    public func connect(to candidate: Candidate, callbackBundleID: String,
                        verification: @MainActor (String) -> Void) async throws -> PairingRecord {
        guard !connecting else { throw TalkError.busy }
        guard candidate.expiresAt > Date() else { throw TalkError.invitationExpired }
        guard PairingRouting.validBundleID(callbackBundleID) else { throw TalkError.invalidInvitation }
        connecting = true
        defer { connecting = false }
        let id = UUID()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let agreement = try PairingKeyExchange.derive(privateKey: key, peerPublicKey: candidate.publicKey,
            providerPublicKey: candidate.publicKey, consumerPublicKey: key.publicKey.rawRepresentation,
            sessionID: candidate.id, requestID: id, providerBundleID: candidate.providerBundleID, consumerBundleID: callbackBundleID)
        verification(agreement.verificationCode)
        let request = PairingRouting.url(scheme: "talk-spike-provider", host: "pairing-connect", fields: [
            "request": id.uuidString, "callback": callbackBundleID, "session": candidate.id.uuidString,
            "key": key.publicKey.rawRepresentation.base64EncodedString()
        ])
        let response = try await exchange(request, application: candidate.applicationURL, id: id, responseHost: "pairing-ready")
        guard let fields = PairingRouting.fields(response, scheme: "talk-spike-consumer", host: "pairing-ready",
                                                 names: ["request", "session", "port"]),
              fields["session"] == candidate.id.uuidString,
              let port = fields["port"].flatMap(UInt16.init), port > 0 else { throw TalkError.invalidInvitation }
        try Task.checkCancellation()
        return try await PairingClient.pair(using: PairingInvitation(credential: agreement.credential, port: port,
            providerBundleID: candidate.providerBundleID, expiresAt: candidate.expiresAt))
    }

    public func receive(_ url: URL) {
        let names: Set<String>
        switch url.host {
        case "pairing-available": names = ["request", "session", "provider", "key", "expires"]
        case "pairing-ready": names = ["request", "session", "port"]
        default: return
        }
        guard let host = url.host,
              let fields = PairingRouting.fields(url, scheme: "talk-spike-consumer", host: host, names: names),
              let id = fields["request"].flatMap(UUID.init(uuidString:)),
              let entry = pending[id], entry.host == host else { return }
        pending[id] = nil
        entry.continuation.yield(url)
        entry.continuation.finish()
    }

    private func exchange(_ url: URL, application: URL, id: UUID, responseHost: String) async throws -> URL {
        try Task.checkCancellation()
        guard pending.count < 4, application.isFileURL else { throw TalkError.busy }
        let (stream, continuation) = AsyncThrowingStream<URL, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pending[id] = Pending(host: responseHost, continuation: continuation)
        defer { pending.removeValue(forKey: id)?.continuation.finish() }
        send(url, application)
        return try await withDeadline(seconds: timeout) {
            for try await reply in stream { try Task.checkCancellation(); return reply }
            throw CancellationError()
        }
    }
}
