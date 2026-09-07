import CryptoKit
import Foundation

/// Opt-in, one-attempt pairing mode. Route provider URLs here. Starting the app
/// never enables pairing: only an explicit user action should call `start`.
@MainActor
public final class DiscoverablePairingHost {
    public struct Request: Sendable {
        /// Untrusted routing label, not a verified application identity.
        public let consumerBundleID: String
        /// Compare with the consumer's display before granting any scopes.
        public let verificationCode: String
    }
    public typealias Approve = @Sendable (Request) async throws -> PairingRecord
    private struct Session {
        let id: UUID
        let provider: String
        let callbacks: Set<String>?
        let identity: Curve25519.KeyAgreement.PrivateKey
        let expiresAt: Date
        let approve: Approve
    }
    private var session: Session?
    private var host: PairingHost?
    private var operation: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var generation = UUID()
    private var discoveryReplies = 0
    private var keyAttempts = 0
    private let send: PairingRouting.Sender
    private let callback: PairingRouting.Callback

    public init() { send = PairingRouting.send; callback = PairingRouting.callback }
    init(send: @escaping PairingRouting.Sender, callback: @escaping PairingRouting.Callback) {
        self.send = send; self.callback = callback
    }
    deinit { operation?.cancel(); expiry?.cancel() }

    public var isDiscoverable: Bool { session.map { $0.expiresAt > Date() } ?? false }

    /// Ends after at most five minutes or one connection attempt. Call `stop`
    /// before starting another mode, including after denial or disconnection.
    /// Omit `allowedCallbackBundleIDs` to support future consumers without a
    /// provider update. A supplied set restricts public callback routing only;
    /// neither it nor the default establishes the other app's identity.
    @discardableResult
    public func start(providerBundleID: String, allowedCallbackBundleIDs: Set<String>? = nil, lifetime: Double = 300,
                      approve: @escaping Approve) throws -> Date {
        guard session == nil, host == nil else { throw TalkError.busy }
        guard lifetime.isFinite, lifetime > 0, lifetime <= 300,
              PairingRouting.validBundleID(providerBundleID),
              PairingRouting.validCallbackAllowlist(allowedCallbackBundleIDs) else { throw TalkError.invalidInvitation }
        let deadline = Date().addingTimeInterval(lifetime)
        generation = UUID()
        discoveryReplies = 0
        keyAttempts = 0
        let epoch = generation
        session = Session(id: UUID(), provider: providerBundleID, callbacks: allowedCallbackBundleIDs,
                          identity: .init(), expiresAt: deadline, approve: approve)
        expiry = Task { [weak self] in
            do {
                try await DeadlineTimer.sleep(seconds: lifetime)
                guard let self, self.generation == epoch else { return }
                await self.stop()
            } catch { }
        }
        return deadline
    }

    public func stop() async {
        generation = UUID()
        session = nil
        operation?.cancel(); operation = nil
        expiry?.cancel(); expiry = nil
        let previous = host
        host = nil
        await previous?.stop()
    }

    /// Ignores all setup URLs outside explicit pairing mode. An allowlist only
    /// limits callback routing; consent must still compare the verification code.
    public func receive(_ url: URL) {
        guard let session, session.expiresAt > Date() else { return }
        if let fields = PairingRouting.fields(url, scheme: "talk-spike-provider", host: "pairing-discover",
                                              names: ["request", "callback"]),
           let request = fields["request"], UUID(uuidString: request) != nil,
           let consumer = fields["callback"], PairingRouting.allowsCallback(consumer, allowlist: session.callbacks),
           let target = callback(consumer), discoveryReplies < 32 {
            discoveryReplies += 1
            send(PairingRouting.url(scheme: "talk-spike-consumer", host: "pairing-available", fields: [
                "request": request, "session": session.id.uuidString, "provider": session.provider,
                "key": session.identity.publicKey.rawRepresentation.base64EncodedString(),
                "expires": String(session.expiresAt.timeIntervalSince1970)
            ]), target)
            return
        }
        guard let fields = PairingRouting.fields(url, scheme: "talk-spike-provider", host: "pairing-connect",
                                                 names: ["request", "callback", "session", "key"]),
              let rawRequest = fields["request"], let requestID = UUID(uuidString: rawRequest),
              fields["session"] == session.id.uuidString,
              let consumer = fields["callback"], PairingRouting.allowsCallback(consumer, allowlist: session.callbacks),
              let rawKey = fields["key"], let consumerKey = Data(base64Encoded: rawKey), consumerKey.count == 32,
              let target = callback(consumer), keyAttempts < 8 else { return }
        keyAttempts += 1
        guard let agreement = try? PairingKeyExchange.derive(
                privateKey: session.identity, peerPublicKey: consumerKey,
                providerPublicKey: session.identity.publicKey.rawRepresentation, consumerPublicKey: consumerKey,
                sessionID: session.id, requestID: requestID, providerBundleID: session.provider, consumerBundleID: consumer)
        else { return }
        // Atomically consume before suspension: no concurrent key exchange,
        // repeated code guessing, automatic retry or replacement of a live peer.
        self.session = nil
        let epoch = generation
        let pairing = PairingHost()
        host = pairing
        let send = self.send
        let context = Request(consumerBundleID: consumer, verificationCode: agreement.verificationCode)
        let providerID = session.provider
        let sessionID = session.id
        let deadline = session.expiresAt
        let approve = session.approve
        operation = Task { [weak self] in
            do {
                let invitation = try await pairing.start(providerBundleID: providerID, credential: agreement.credential,
                                                          lifetime: max(0.001, deadline.timeIntervalSinceNow)) {
                    try Task.checkCancellation()
                    return try await approve(context)
                }
                try Task.checkCancellation()
                guard let self, self.generation == epoch, Date() < deadline else {
                    await pairing.stop(); return
                }
                send(PairingRouting.url(scheme: "talk-spike-consumer", host: "pairing-ready", fields: [
                    "request": requestID.uuidString, "session": sessionID.uuidString, "port": String(invitation.port)
                ]), target)
            } catch { await pairing.stop() }
        }
    }
}
