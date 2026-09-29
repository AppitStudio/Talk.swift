import CryptoKit
import Foundation

/// Code-free setup between authenticated applications on this Mac. Retain one
/// instance in the consumer and forward captured messages to `receive`.
/// Discovery is passive; call `connect` only for a deliberate Connect action.
@MainActor
public final class IntegrationConnection {
    private struct Pending {
        let peer: VerifiedApplication
        let continuation: AsyncThrowingStream<URL, any Error>.Continuation
    }
    private var pending: [UUID: Pending] = [:]
    private var connecting = false
    private let launch: IntegrationConnectionWire.Launch
    private let send: IntegrationConnectionWire.Send
    private let timeout: Double

    public init() {
        launch = AuthenticatedAppRouting.launch
        send = AuthenticatedAppRouting.send
        timeout = 15
    }

    init(timeout: Double = 15, launch: @escaping IntegrationConnectionWire.Launch,
         send: @escaping IntegrationConnectionWire.Send) {
        self.timeout = timeout; self.launch = launch; self.send = send
    }

    /// Opens the selected installation in the background, authenticates its
    /// publisher, exchanges ephemeral keys, and returns the scoped grant over
    /// TLS. The caller validates and saves it in its existing IntegrationStore.
    public func connect(applicationURL: URL, provider: AppIdentity, consumerBundleID: String,
                        scopes: Set<String>, replacing: UUID? = nil, originRequestID: UUID? = nil) async throws -> PairingRecord {
        guard !connecting else { throw TalkError.busy }
        guard PairingRouting.validBundleID(consumerBundleID) else { throw TalkError.invalidMessage }
        let encodedScopes = try IntegrationConnectionWire.encodeScopes(scopes)
        connecting = true
        defer { connecting = false }
        try Task.checkCancellation()
        let target = try await launch(applicationURL, provider)
        try Task.checkCancellation()
        let id = UUID()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let request = PairingRouting.url(scheme: "talk-spike-provider", host: "integration-connect", fields: [
            "request": id.uuidString, "consumer": consumerBundleID,
            "key": key.publicKey.rawRepresentation.base64EncodedString(),
            "scopes": encodedScopes, "replacing": replacing?.uuidString ?? "", "origin": originRequestID?.uuidString ?? ""
        ])
        let response = try await exchange(request, peer: target, id: id)
        guard let fields = IntegrationConnectionWire.fields(response, scheme: "talk-spike-consumer", host: "integration-ready",
                                                            names: ["request", "session", "key", "port", "expires"]),
              let session = fields["session"].flatMap(UUID.init(uuidString:)),
              let publicKey = fields["key"].flatMap({ Data(base64Encoded: $0) }), publicKey.count == 32,
              let port = fields["port"].flatMap(UInt16.init), port > 0,
              let timestamp = fields["expires"].flatMap(Double.init), timestamp.isFinite else {
            throw TalkError.invalidMessage
        }
        let expires = Date(timeIntervalSince1970: timestamp)
        guard expires > Date(), expires.timeIntervalSinceNow <= 120 else { throw TalkError.invitationExpired }
        let credential = try IntegrationConnectionWire.credential(
            privateKey: key, peerPublicKey: publicKey, providerKey: publicKey,
            consumerKey: key.publicKey.rawRepresentation, session: session, request: id,
            provider: provider.bundleID, consumer: consumerBundleID, scopes: encodedScopes, replacing: replacing, origin: originRequestID)
        try Task.checkCancellation()
        let record = try await PairingClient.pair(using: PairingInvitation(
            credential: credential, port: port, providerBundleID: provider.bundleID, expiresAt: expires))
        try record.validate()
        guard record.providerBundleID == provider.bundleID,
              record.consumerIdentity?.bundleID == consumerBundleID,
              record.scopes.isSubset(of: scopes), record.replacesID == replacing else {
            throw TalkError.permissionDenied
        }
        try Task.checkCancellation()
        return record
    }

    /// Capture the authenticated message synchronously in the app's URL
    /// delegate, before hopping actors or putting it in a cold-start queue.
    public func receive(_ message: AuthenticatedAppMessage) {
        let url = message.url
        let names: Set<String>
        switch url.host {
        case "integration-ready": names = ["request", "session", "key", "port", "expires"]
        case "integration-error": names = ["request", "error"]
        default: return
        }
        guard let host = url.host,
              let fields = IntegrationConnectionWire.fields(url, scheme: "talk-spike-consumer", host: host, names: names),
              let id = fields["request"].flatMap(UUID.init(uuidString:)), let entry = pending[id],
              IntegrationConnectionWire.sameProcess(message.sender, entry.peer) else { return }
        pending[id] = nil
        if host == "integration-error" {
            let error = fields["error"].flatMap(TalkError.init(rawValue:)) ?? .unavailable
            entry.continuation.finish(throwing: error)
        } else {
            entry.continuation.yield(url)
            entry.continuation.finish()
        }
    }

    private func exchange(_ url: URL, peer: VerifiedApplication, id: UUID) async throws -> URL {
        let (stream, continuation) = AsyncThrowingStream<URL, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pending[id] = Pending(peer: peer, continuation: continuation)
        defer { pending.removeValue(forKey: id)?.continuation.finish() }
        try send(url, peer)
        return try await withDeadline(seconds: timeout) {
            for try await reply in stream { try Task.checkCancellation(); return reply }
            throw CancellationError()
        }
    }
}

/// Lets a provider's integration library initiate the SAME directional grant
/// from its own Connect button. Receiving apps must explicitly recognize the
/// provider identity and implemented contract before acting on this request.
public struct IntegrationConnectionRequest: Sendable {
    public let id: UUID
    public let provider: VerifiedApplication
    public let scopes: Set<String>
    public let replacesID: UUID?

    public static func parse(_ message: AuthenticatedAppMessage) -> Self? {
        guard let fields = IntegrationConnectionWire.fields(message.url, scheme: "talk-spike-consumer", host: "integration-offer",
                                                            names: ["request", "provider", "scopes", "replacing"]),
              let id = fields["request"].flatMap(UUID.init(uuidString:)),
              fields["provider"] == message.sender.identity.bundleID,
              let rawReplacement = fields["replacing"],
              rawReplacement.isEmpty || UUID(uuidString: rawReplacement) != nil,
              let encoded = fields["scopes"], let scopes = try? IntegrationConnectionWire.decodeScopes(encoded) else { return nil }
        return Self(id: id, provider: message.sender, scopes: scopes, replacesID: UUID(uuidString: rawReplacement))
    }

    @MainActor @discardableResult
    public static func send(applicationURL: URL, consumer: AppIdentity, providerBundleID: String,
                            scopes: Set<String>, replacing: UUID? = nil, requestID: UUID = UUID()) async throws -> UUID {
        guard PairingRouting.validBundleID(providerBundleID) else { throw TalkError.invalidMessage }
        let encoded = try IntegrationConnectionWire.encodeScopes(scopes)
        let target = try await AuthenticatedAppRouting.launch(applicationURL: applicationURL, identity: consumer)
        try Task.checkCancellation()
        try AuthenticatedAppRouting.send(PairingRouting.url(scheme: "talk-spike-consumer", host: "integration-offer", fields: [
            "request": requestID.uuidString, "provider": providerBundleID, "scopes": encoded,
            "replacing": replacing?.uuidString ?? ""
        ]), to: target)
        return requestID
    }
}

enum IntegrationConnectionWire {
    typealias Launch = @MainActor (URL, AppIdentity) async throws -> VerifiedApplication
    typealias Send = @MainActor (URL, VerifiedApplication) throws -> Void

    static func sameProcess(_ first: VerifiedApplication, _ second: VerifiedApplication) -> Bool {
        first.identity == second.identity && first.processIdentifier == second.processIdentifier
            && first.applicationURL.standardizedFileURL == second.applicationURL.standardizedFileURL
    }

    static func fields(_ url: URL, scheme: String, host: String, names: Set<String>) -> [String: String]? {
        guard url.absoluteString.utf8.count <= 8192,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == scheme, c.host == host, c.user == nil, c.password == nil, c.port == nil,
              c.path.isEmpty, c.fragment == nil, let items = c.queryItems, items.count == names.count,
              Set(items.map(\.name)) == names,
              items.allSatisfy({ $0.value != nil && ($0.value?.utf8.count ?? 0) <= 6144 }) else { return nil }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
    }

    static func encodeScopes(_ scopes: Set<String>) throws -> String {
        guard !scopes.isEmpty, scopes.count <= 32,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw TalkError.invalidMessage }
        let data = try JSONEncoder().encode(scopes.sorted())
        guard data.count <= 4096 else { throw TalkError.invalidMessage }
        return data.base64EncodedString()
    }

    static func decodeScopes(_ value: String) throws -> Set<String> {
        guard let data = Data(base64Encoded: value), data.count <= 4096,
              let array = try? JSONDecoder().decode([String].self, from: data),
              Set(array).count == array.count else { throw TalkError.invalidMessage }
        let scopes = Set(array)
        _ = try encodeScopes(scopes)
        return scopes
    }

    static func credential(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                           providerKey: Data, consumerKey: Data, session: UUID, request: UUID,
                           provider: String, consumer: String, scopes: String, replacing: UUID?, origin: UUID? = nil) throws -> PairingCredential {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var transcript = Data()
        for field in [Data("Talk authenticated app connection v1".utf8), providerKey, consumerKey,
                      Data(session.uuidString.utf8), Data(request.uuidString.utf8), Data(provider.utf8),
                      Data(consumer.utf8), Data(scopes.utf8), Data((replacing?.uuidString ?? "").utf8),
                      Data((origin?.uuidString ?? "").utf8)] {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { transcript.append(contentsOf: $0) }
            transcript.append(field)
        }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: transcript)),
                                                 sharedInfo: Data("setup TLS credential".utf8), outputByteCount: 32)
        return try PairingCredential(id: request, secret: key.withUnsafeBytes { Data($0) })
    }
}
