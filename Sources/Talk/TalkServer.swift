import Foundation

/// One paired principal; TLS authenticates before dispatch. Handler cancellation
/// is cooperative: providers must check cancellation immediately before mutations.
public actor TalkServer {
    public typealias Handler = @Sendable (String, JSONValue) async throws -> JSONValue
    private let contract: ContractSchema?
    private let record: PairingRecord
    private let actions: [String: String]
    private let subscriptionAction: String?
    private let handler: Handler
    private let idleTimeout: Double
    private let handlerTimeout: Double
    private let listener = TalkListener()
    private var accepting: Task<Void, Never>?
    private var peers: [UUID: Peer] = [:]
    // Retain cancelled handlers until they exit, so noncooperative work cannot
    // bypass the global limit by repeatedly disconnecting.
    private var calls: [UUID: (UUID, Task<Void, Never>)] = [:]
    private var active = false
    private var started = false
    private var stopped = false

    private struct Peer {
        let connection: TalkConnection
        let output: AsyncStream<TalkMessage>.Continuation
        let reader: Task<Void, Never>
        let writer: Task<Void, Never>
        var negotiated: ContractRequirement?
        var subscribed = false
        var subscribing = false
        var stagedEvents: [TalkMessage] = []
        var callCount = 0
    }

    public init(record: PairingRecord, actions: [String: String], contract: ContractSchema? = nil, subscriptionAction: String? = nil,
                idleTimeout: Double = 300, handlerTimeout: Double = 30, handler: @escaping Handler) {
        self.contract = contract
        self.record = record
        self.actions = actions
        self.subscriptionAction = subscriptionAction
        self.idleTimeout = idleTimeout
        self.handlerTimeout = handlerTimeout
        self.handler = handler
    }

    deinit {
        accepting?.cancel()
        for peer in peers.values { peer.reader.cancel(); peer.writer.cancel(); peer.output.finish() }
        for (_, task) in calls.values { task.cancel() }
    }

    public func start() async throws -> UInt16 {
        guard !started else { throw TalkError.busy }
        guard idleTimeout.isFinite, idleTimeout > 0, idleTimeout <= 86_400,
              handlerTimeout.isFinite, handlerTimeout > 0, handlerTimeout <= 86_400 else { throw TalkError.invalidMessage }
        try record.validate()
        if let contract {
            try contract.validate()
            guard actions == Dictionary(uniqueKeysWithValues: contract.actions.map { ($0.id, $0.scope) }),
                  subscriptionAction == nil || actions[subscriptionAction!] != nil else { throw TalkError.invalidMessage }
        }
        started = true
        let (port, connections) = try await listener.start(credential: record.credential)
        guard !stopped else { await listener.stop(); throw TalkError.disconnected }
        active = true
        accepting = Task { [weak self] in
            for await connection in connections { await self?.accept(connection) }
        }
        return port
    }

    public func stop() async {
        active = false
        stopped = true
        accepting?.cancel()
        accepting = nil
        for (_, task) in calls.values { task.cancel() }
        for id in Array(peers.keys) { await remove(id) }
        await listener.stop()
    }

    /// Ordered, bounded live events. Overflow closes the session; reconnect and
    /// subscribe returns a fresh snapshot. No durable replay is promised.
    public func publish(action: String, payload: JSONValue) async {
        guard active, let subscriptionAction, let scope = actions[subscriptionAction], record.permits(scope) else { return }
        if let contract {
            guard let event = contract.events.first(where: { $0.id == action }),
                  (try? ContractValueValidator.validate(payload, type: event.payload, schema: contract)) != nil else { return }
        }
        let message = TalkMessage(kind: .event, action: action, payload: payload)
        guard (try? FrameCodec.encode(message)) != nil else { return }
        for id in Array(peers.keys) {
            guard let peer = peers[id], contract == nil || peer.negotiated?.events.contains(action) == true else { continue }
            if peer.subscribing {
                if peer.stagedEvents.count >= 64 { await remove(id) }
                else { peers[id]?.stagedEvents.append(message) }
            } else if peer.subscribed { await enqueue(message, to: id) }
        }
    }

    private func accept(_ connection: TalkConnection) async {
        guard active, peers.count < 8 else {
            TransportDiagnostics.record("connection=\(connection.diagnosticID) server-reject active=\(active) peers=\(peers.count)")
            await connection.close(); return
        }
        TransportDiagnostics.record("connection=\(connection.diagnosticID) server-accept peers=\(peers.count)")
        let id = UUID()
        let (output, continuation) = AsyncStream<TalkMessage>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let idleTimeout = idleTimeout
        let writer = Task { [weak self] in
            do {
                for await message in output {
                    try await withDeadline(seconds: 10) { try await connection.send(message) }
                }
            } catch { }
            await self?.remove(id)
        }
        let reader = Task { [weak self] in
            do {
                try await connection.start()
                var seen: Set<UUID> = []
                while !Task.isCancelled {
                    let message = try await withDeadline(seconds: idleTimeout) { try await connection.receive() }
                    // A bounded session lifetime prevents replay after eviction.
                    guard message.kind == .request, seen.count < 4096,
                          seen.insert(message.id).inserted else { throw TalkError.invalidMessage }
                    await self?.dispatch(message, peerID: id)
                }
            } catch { }
            await self?.remove(id)
        }
        peers[id] = Peer(connection: connection, output: continuation, reader: reader, writer: writer)
    }

    private func dispatch(_ message: TalkMessage, peerID: UUID) async {
        do {
            guard active, let peer = peers[peerID] else { throw TalkError.permissionDenied }
            if message.action == "talk.negotiate" {
                guard let contract, peer.negotiated == nil else { throw TalkError.unsupportedVersion }
                let requirement = try message.payload.decode(ContractRequirement.self)
                if try requirement.diagnostics(provider: contract).isEmpty { peers[peerID]?.negotiated = requirement }
                await enqueue(TalkMessage(kind: .response, id: message.id, action: message.action, payload: try .encoding(contract)), to: peerID)
                return
            }
            if let contract {
                guard peer.negotiated?.actions.contains(message.action) == true else { throw TalkError.unsupportedVersion }
                guard let action = contract.actions.first(where: { $0.id == message.action }) else { throw TalkError.unknownAction }
                try ContractValueValidator.validate(message.payload, type: action.input, schema: contract)
            }
            guard let scope = actions[message.action] else { throw TalkError.unknownAction }
            guard record.permits(scope) else { throw TalkError.permissionDenied }
            guard calls.count < 128, peer.callCount < 16 else { throw TalkError.busy }
            guard await HandlerCapacity.shared.acquire() else { throw TalkError.busy }
            // Revocation or another dispatch can run during the capacity await.
            guard active, let current = peers[peerID], current.callCount < 16,
                  message.action != subscriptionAction || (!current.subscribed && !current.subscribing) else {
                await HandlerCapacity.shared.release()
                throw TalkError.busy
            }
            if message.action == subscriptionAction {
                peers[peerID]?.subscribing = true
            }
            peers[peerID]?.callCount += 1
            let token = UUID()
            let handler = handler
            let contract = contract
            let handlerTimeout = handlerTimeout
            calls[token] = (peerID, Task { [weak self] in
                // Separate watchdog closes the socket even if a provider ignores
                // cancellation. Its handler slot stays occupied until it returns.
                let watchdog = Task { [weak self] in
                    do { try await DeadlineTimer.sleep(seconds: handlerTimeout); await self?.remove(peerID) }
                    catch { }
                }
                defer { watchdog.cancel() }
                let response: TalkMessage
                do {
                    try Task.checkCancellation()
                    let payload = try await handler(message.action, message.payload)
                    try Task.checkCancellation()
                    if let contract, let action = contract.actions.first(where: { $0.id == message.action }) {
                        try ContractValueValidator.validate(payload, type: action.output, schema: contract)
                    }
                    response = TalkMessage(kind: .response, id: message.id, action: message.action, payload: payload)
                } catch {
                    response = TalkMessage(kind: .response, id: message.id, action: message.action,
                                           error: (error as? TalkError) ?? .invalidMessage)
                }
                await HandlerCapacity.shared.release()
                await self?.complete(response, peerID: peerID, token: token)
            })
        } catch {
            await enqueue(TalkMessage(kind: .response, id: message.id, action: message.action,
                                      error: (error as? TalkError) ?? .invalidMessage), to: peerID)
        }
    }

    private func complete(_ response: TalkMessage, peerID: UUID, token: UUID) async {
        calls[token] = nil
        guard active, peers[peerID] != nil else { return }
        peers[peerID]?.callCount -= 1
        if response.action == subscriptionAction {
            let events = peers[peerID]?.stagedEvents ?? []
            peers[peerID]?.stagedEvents = []
            peers[peerID]?.subscribing = false
            peers[peerID]?.subscribed = response.error == nil
            await enqueue(response, to: peerID)
            if response.error == nil {
                for event in events { await enqueue(event, to: peerID) }
            }
        } else { await enqueue(response, to: peerID) }
    }

    private func enqueue(_ message: TalkMessage, to id: UUID) async {
        guard let peer = peers[id] else { return }
        guard (try? FrameCodec.encode(message)) != nil else { await remove(id); return }
        switch peer.output.yield(message) {
        case .enqueued: break
        case .dropped, .terminated: await remove(id)
        @unknown default: await remove(id)
        }
    }

    private func remove(_ id: UUID) async {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.output.finish()
        peer.reader.cancel()
        peer.writer.cancel()
        for (peerID, task) in calls.values where peerID == id { task.cancel() }
        await peer.connection.close()
    }
}
