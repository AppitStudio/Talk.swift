import Foundation
import IntegrationContract
import Talk

// Integration primitive, not a consent UI. The app owns this object for its lifetime.
@MainActor
public final class ExampleProvider {
    private var snapshot = Snapshot(sessionID: UUID(), revision: 0, value: "ready")
    private let bundleID: String
    private let store: IntegrationStore
    public private(set) lazy var provider = TalkProvider(
        store: store, contract: ExampleAPI.schema, subscriptionAction: ExampleAPI.observe
    ) { [weak self] action, payload in
        guard let self else { throw TalkError.unavailable }
        return try await self.handle(action, payload)
    }

    public init(bundleID: String, service: String) {
        self.bundleID = bundleID
        self.store = IntegrationStore(persistence: CredentialStore(service: service))
    }

    public func start() async throws { try await provider.restore() }

    // Call from the retained DiscoverablePairingHost approval closure only after visible
    // scoped consent and full-code comparison. Freeze scopes/replacement/label per mode.
    // The host app supplies cancellation-aware UI; see references/pairing.md.
    public func approveAfterConsent(scopes: Set<String>, replacing id: UUID? = nil,
                                    label: String? = nil) async throws -> PairingRecord {
        try Task.checkCancellation()
        guard !scopes.isEmpty, scopes.isSubset(of: ExampleAPI.scopes) else {
            throw TalkError.permissionDenied
        }
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: bundleID,
                                   scopes: scopes, replacesID: id, label: label)
        try await provider.approve(record)
        return record
    }

    // The host must also forward setup URLs to its DiscoverablePairingHost.receive(_:).
    public func receive(_ url: URL, allowedConsumers: Set<String>) async {
        for (id, port) in await provider.endpoints() {
            EndpointResolver.reply(to: url, pairingID: id, port: port,
                                   allowedCallbackBundleIDs: allowedConsumers)
        }
    }

    private func handle(_ action: String, _ payload: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        switch action {
        case ExampleAPI.read, ExampleAPI.observe:
            return try .encoding(snapshot)
        case ExampleAPI.set:
            let input = try payload.decode(SetValue.self)
            guard input.value.utf8.count <= 256, snapshot.revision < Int64.max else {
                throw TalkError.invalidMessage
            }
            try Task.checkCancellation()
            let next = Snapshot(sessionID: snapshot.sessionID, revision: snapshot.revision + 1,
                                value: input.value)
            snapshot = next
            await provider.publish(action: ExampleAPI.changed, payload: try .encoding(next))
            return try .encoding(next)
        default: throw TalkError.unknownAction
        }
    }
}
