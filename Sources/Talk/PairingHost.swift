import Foundation

/// A short-lived listener that can exchange one setup credential for a separately
/// generated durable credential. It never dispatches application actions.
public actor PairingHost {
    public typealias Approve = @Sendable () async throws -> PairingRecord
    private let listener = TalkListener()
    private var acceptTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var connection: TalkConnection?
    private var consumed = false
    private var started = false
    private var expiresAt = Date.distantPast

    public init() {}
    deinit { acceptTask?.cancel(); expiryTask?.cancel(); worker?.cancel() }

    public func start(providerBundleID: String, lifetime: Double = 300, approve: @escaping Approve) async throws -> PairingInvitation {
        try await start(providerBundleID: providerBundleID, credential: PairingCredential(), lifetime: lifetime, approve: approve)
    }

    func start(providerBundleID: String, credential: PairingCredential, lifetime: Double, approve: @escaping Approve) async throws -> PairingInvitation {
        guard !started else { throw TalkError.busy }
        guard lifetime.isFinite, lifetime > 0, lifetime <= 300 else { throw TalkError.invalidInvitation }
        started = true
        expiresAt = Date().addingTimeInterval(lifetime)
        let (port, connections) = try await listener.start(credential: credential)
        guard !consumed, Date() < expiresAt, !Task.isCancelled else {
            await listener.stop()
            throw TalkError.invitationExpired
        }
        acceptTask = Task { [weak self] in
            for await peer in connections { await self?.accept(peer, approve: approve) }
        }
        expiryTask = Task { [weak self] in
            do { try await DeadlineTimer.sleep(seconds: lifetime); await self?.stop() }
            catch { }
        }
        return PairingInvitation(credential: credential, port: port, providerBundleID: providerBundleID, expiresAt: expiresAt)
    }

    public func stop() async {
        consumed = true
        acceptTask?.cancel()
        expiryTask?.cancel()
        worker?.cancel()
        acceptTask = nil
        expiryTask = nil
        worker = nil
        let peer = connection
        connection = nil
        await listener.stop()
        await peer?.close()
    }

    private func accept(_ peer: TalkConnection, approve: @escaping Approve) async {
        guard consumed == false, connection == nil, Date() < expiresAt else { await peer.close(); return }
        connection = peer
        worker = Task { [weak self] in
            do {
                try await peer.start()
                let request = try await withDeadline(seconds: 10) { try await peer.receive() }
                guard request.kind == .request, request.action == "talk.pair", request.payload == .null else { throw TalkError.invalidMessage }
                guard let self, await self.consume() else { throw TalkError.invitationExpired }
                // Monitor the socket while consent is pending. A departing
                // consumer must cancel the provider's approval wait promptly.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            let record = try await approve()
                            try Task.checkCancellation()
                            try await peer.send(TalkMessage(kind: .response, id: request.id, action: request.action, payload: .encoding(record)))
                        } catch {
                            try Task.checkCancellation()
                            try await peer.send(TalkMessage(kind: .response, id: request.id, action: request.action,
                                                            error: (error as? TalkError) ?? .permissionDenied))
                        }
                    }
                    group.addTask {
                        _ = try await peer.receive()
                        throw TalkError.invalidMessage // No second setup request.
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch { }
            await peer.close()
            await self?.finished()
        }
    }

    private func consume() -> Bool {
        guard consumed == false, Date() < expiresAt else { return false }
        consumed = true
        return true
    }

    private func finished() async { await stop() }
}
