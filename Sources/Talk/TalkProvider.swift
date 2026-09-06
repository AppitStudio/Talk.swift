import Foundation

public struct IntegrationStatus: Sendable, Identifiable {
    public enum State: String, Sendable { case ready, unavailable, revocationPending }
    public let id: UUID
    public let label: String?
    public let providerBundleID: String
    public let scopes: Set<String>
    public let state: State
}

/// Bounded multi-principal provider. Each grant owns its TLS listener, peers,
/// tasks and queues. Revocation never stops a different integration's server.
public actor TalkProvider {
    private let store: IntegrationStore
    private let contract: ContractSchema
    private let subscriptionAction: String?
    private let handler: TalkServer.Handler
    private var servers: [UUID: TalkServer] = [:]
    private var ports: [UUID: UInt16] = [:]
    private var statuses: [UUID: IntegrationStatus] = [:]
    private var busy = false
    private var generation: UInt64 = 0
    private var running = false

    public init(store: IntegrationStore, contract: ContractSchema, subscriptionAction: String? = nil,
                handler: @escaping TalkServer.Handler) {
        self.store = store; self.contract = contract
        self.subscriptionAction = subscriptionAction; self.handler = handler
    }

    public func integrations() -> [IntegrationStatus] { statuses.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    public func endpoints() -> [UUID: UInt16] { ports }

    public func restore() async throws {
        guard !busy else { throw TalkError.busy }
        busy = true
        defer { busy = false }
        let epoch = generation
        await stopServers()
        let records = try await store.reload()
        guard generation == epoch else { throw TalkError.disconnected }
        running = true
        statuses.removeAll()
        for record in records {
            guard generation == epoch else { throw TalkError.disconnected }
            do { try await activate(record) }
            catch { setStatus(record, .unavailable) }
        }
    }

    /// Provider UI must obtain fresh explicit consent before calling this method.
    public func approve(_ record: PairingRecord) async throws {
        guard running else { throw TalkError.unavailable }
        let epoch = generation
        guard !busy else { throw TalkError.busy }
        busy = true
        defer { busy = false }
        try record.validate()
        guard record.scopes.isSubset(of: Set(contract.actions.map(\.scope))) else { throw TalkError.permissionDenied }
        if let old = record.replacesID {
            guard let previous = statuses[old], previous.providerBundleID == record.providerBundleID else { throw TalkError.pairingRequired }
            await stopServer(old)
            statuses[old] = IntegrationStatus(id: old, label: previous.label, providerBundleID: previous.providerBundleID, scopes: previous.scopes, state: .revocationPending)
        }
        guard running, generation == epoch else { throw TalkError.disconnected }
        try await store.insert(record)
        guard generation == epoch else { throw TalkError.disconnected }
        if let old = record.replacesID { statuses[old] = nil }
        do { try await activate(record) }
        catch { setStatus(record, .unavailable); throw error }
    }

    public func revoke(_ id: UUID) async throws {
        guard !busy else { throw TalkError.busy }
        busy = true
        defer { busy = false }
        guard let status = statuses[id] else { return }
        // Invalidate endpoint and cancel work before the durable operation.
        await stopServer(id)
        statuses[id] = IntegrationStatus(id: id, label: status.label, providerBundleID: status.providerBundleID, scopes: status.scopes, state: .revocationPending)
        try await store.remove(id)
        statuses[id] = nil
    }

    public func publish(action: String, payload: JSONValue) async {
        for server in Array(servers.values) { await server.publish(action: action, payload: payload) }
    }

    public func stop() async {
        generation &+= 1
        running = false
        await stopServers()
    }

    private func activate(_ record: PairingRecord) async throws {
        guard running else { throw TalkError.unavailable }
        let server = TalkServer(record: record, actions: Dictionary(uniqueKeysWithValues: contract.actions.map { ($0.id, $0.scope) }),
                                contract: contract, subscriptionAction: subscriptionAction, handler: handler)
        let epoch = generation
        let port = try await server.start()
        guard generation == epoch else { await server.stop(); throw TalkError.disconnected }
        servers[record.credential.id] = server
        ports[record.credential.id] = port
        setStatus(record, .ready)
    }
    private func setStatus(_ record: PairingRecord, _ state: IntegrationStatus.State) {
        statuses[record.credential.id] = IntegrationStatus(id: record.credential.id, label: record.label, providerBundleID: record.providerBundleID, scopes: record.scopes, state: state)
    }
    private func stopServer(_ id: UUID) async {
        ports[id] = nil
        let server = servers.removeValue(forKey: id)
        await server?.stop()
    }
    private func stopServers() async { for id in Array(servers.keys) { await stopServer(id) } }
}
