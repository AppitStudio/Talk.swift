import CryptoKit
import Foundation

/// Always-available authenticated setup. Construct after restoring the provider
/// store; passive library discovery does not create a listener or grant.
/// Only a verified Connect message starts a bounded, one-use TLS exchange.
@MainActor
public final class IntegrationConnectionHost {
    public struct Request: Sendable {
        public let consumer: VerifiedApplication
        public let scopes: Set<String>
        public let replacesID: UUID?
        /// Echoes a provider library request; use it to reject a canceled or expired offer.
        public let originRequestID: UUID?
    }
    /// Apply explicit provider policy: recognized, pinned integrations may use
    /// the initiating app's Connect action as consent. Other apps need a visible
    /// Allow decision. A valid signature alone is never authorization.
    public typealias Approve = @Sendable (Request) async throws -> PairingRecord
    private struct Session {
        let host: PairingHost
        let task: Task<Void, Never>
    }
    private let providerBundleID: String
    private let approve: Approve
    private let send: IntegrationConnectionWire.Send
    private let lifetime: Double
    private var active: [UUID: Session] = [:]
    private var recent: [UUID: Date] = [:]
    private var stopped = false

    public init(providerBundleID: String, approve: @escaping Approve) {
        self.providerBundleID = providerBundleID
        self.approve = approve
        send = AuthenticatedAppRouting.send
        lifetime = 120
    }

    init(providerBundleID: String, lifetime: Double = 120,
         send: @escaping IntegrationConnectionWire.Send, approve: @escaping Approve) {
        self.providerBundleID = providerBundleID; self.lifetime = lifetime
        self.send = send; self.approve = approve
    }

    deinit { for session in active.values { session.task.cancel() } }

    public func stop() async {
        stopped = true
        let sessions = Array(active.values)
        active.removeAll()
        for session in sessions { session.task.cancel(); await session.host.stop() }
    }

    public func receive(_ message: AuthenticatedAppMessage) {
        guard !stopped, PairingRouting.validBundleID(providerBundleID),
              let fields = IntegrationConnectionWire.fields(message.url, scheme: "talk-spike-provider", host: "integration-connect",
                                                            names: ["request", "consumer", "key", "scopes", "replacing", "origin"]),
              let id = fields["request"].flatMap(UUID.init(uuidString:)),
              fields["consumer"] == message.sender.identity.bundleID,
              let rawKey = fields["key"], let publicKey = Data(base64Encoded: rawKey), publicKey.count == 32,
              let encodedScopes = fields["scopes"], let scopes = try? IntegrationConnectionWire.decodeScopes(encodedScopes),
              let rawReplacement = fields["replacing"],
              rawReplacement.isEmpty || UUID(uuidString: rawReplacement) != nil,
              let rawOrigin = fields["origin"], rawOrigin.isEmpty || UUID(uuidString: rawOrigin) != nil else { return }
        recent = recent.filter { $0.value > Date() }
        // Remember attempts through their full validity window, including after
        // failure, to prevent replay. Bound resources even for signed callers.
        guard recent[id] == nil else { return }
        guard active.count < 4, recent.count < 32,
              lifetime.isFinite, lifetime > 0, lifetime <= 120 else {
            reject(id, peer: message.sender, error: .busy); return
        }
        recent[id] = Date().addingTimeInterval(120)
        let context = Request(consumer: message.sender, scopes: scopes, replacesID: UUID(uuidString: rawReplacement), originRequestID: UUID(uuidString: rawOrigin))
        let host = PairingHost()
        let session = UUID()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let providerKey = key.publicKey.rawRepresentation
        let approve = self.approve
        let providerID = providerBundleID
        let deadline = Date().addingTimeInterval(lifetime)
        let task = Task { [weak self] in
            do {
                let credential = try IntegrationConnectionWire.credential(
                    privateKey: key, peerPublicKey: publicKey, providerKey: providerKey, consumerKey: publicKey,
                    session: session, request: id, provider: providerID, consumer: context.consumer.identity.bundleID,
                    scopes: encodedScopes, replacing: context.replacesID, origin: context.originRequestID)
                let invitation = try await host.start(providerBundleID: providerID, credential: credential,
                                                       lifetime: max(0.001, deadline.timeIntervalSinceNow), onFinish: { [weak self] in
                    await self?.finished(id)
                }) {
                    try Task.checkCancellation()
                    let record = try await approve(context)
                    try record.validate()
                    guard record.providerBundleID == providerID, record.scopes.isSubset(of: context.scopes),
                          record.consumerIdentity == context.consumer.identity,
                          record.replacesID == context.replacesID else { throw TalkError.permissionDenied }
                    try Task.checkCancellation()
                    return record
                }
                try Task.checkCancellation()
                guard let self, !self.stopped, self.active[id] != nil else { await host.stop(); return }
                try self.send(PairingRouting.url(scheme: "talk-spike-consumer", host: "integration-ready", fields: [
                    "request": id.uuidString, "session": session.uuidString,
                    "key": providerKey.base64EncodedString(), "port": String(invitation.port),
                    "expires": String(deadline.timeIntervalSince1970)
                ]), context.consumer)
            } catch {
                self?.reject(id, peer: context.consumer, error: (error as? TalkError) ?? .unavailable)
                await host.stop()
                self?.finished(id)
            }
        }
        active[id] = Session(host: host, task: task)
    }

    private func finished(_ id: UUID) { active[id] = nil }

    private func reject(_ id: UUID, peer: VerifiedApplication, error: TalkError) {
        try? send(PairingRouting.url(scheme: "talk-spike-consumer", host: "integration-error", fields: [
            "request": id.uuidString, "error": error.rawValue
        ]), peer)
    }
}
