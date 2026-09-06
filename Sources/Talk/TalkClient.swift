import Foundation

public actor TalkClient {
    private let connection: TalkConnection
    private var reader: Task<Void, Never>?
    private var pending: [UUID: (String, AsyncThrowingStream<TalkMessage, any Error>.Continuation)] = [:]
    private var connected = false
    private var negotiated: ContractRequirement?
    private var negotiation: (ContractRequirement, Task<Void, any Error>)?
    public nonisolated let events: AsyncThrowingStream<TalkMessage, any Error>
    private let eventContinuation: AsyncThrowingStream<TalkMessage, any Error>.Continuation

    public init(port: UInt16, credential: PairingCredential) throws {
        connection = try TalkConnection(port: port, credential: credential)
        (events, eventContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }

    deinit { reader?.cancel(); eventContinuation.finish() }

    public func connect(requirement: ContractRequirement? = nil) async throws {
        guard reader == nil else { throw TalkError.busy }
        try await connection.start()
        connected = true
        let connection = connection
        reader = Task { [weak self] in
            do {
                while Task.isCancelled == false {
                    let message = try await connection.receive()
                    await self?.received(message)
                }
            } catch { await self?.finish(error); await connection.close() }
        }
        if let requirement {
            do { try await prepare(requirement) }
            catch { await close(); throw error }
        }
    }

    /// Authenticated, bounded compatibility exchange. Concurrent generated calls
    /// share one handshake; no application request is sent before it succeeds.
    public func prepare(_ requirement: ContractRequirement) async throws {
        if let negotiated {
            guard negotiated == requirement else { throw TalkError.unsupportedVersion }
            return
        }
        if let negotiation {
            guard negotiation.0 == requirement else { throw TalkError.unsupportedVersion }
            try await negotiation.1.value
            return
        }
        let task = Task {
            let value = try await self.request(action: "talk.negotiate", payload: .encoding(requirement))
            let schema = try value.decode(ContractSchema.self)
            let issues = try requirement.diagnostics(provider: schema)
            guard issues.isEmpty else { throw ContractDiagnostic(issues.map(\.message).joined(separator: "\n")) }
        }
        negotiation = (requirement, task)
        do {
            try await task.value
            guard connected else { throw TalkError.disconnected }
            negotiated = requirement
            negotiation = nil
        } catch { negotiation = nil; await close(); throw error }
    }

    /// Requests are never retried automatically, including after uncertain delivery.
    public func request(action: String, payload: JSONValue = .null, timeout: Double = 10, requirement: ContractRequirement? = nil) async throws -> JSONValue {
        if let requirement { try await prepare(requirement) }
        guard connected else { throw TalkError.disconnected }
        guard pending.count < 16 else { throw TalkError.busy }
        let message = TalkMessage(kind: .request, action: action, payload: payload)
        let (responses, continuation) = AsyncThrowingStream<TalkMessage, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pending[message.id] = (action, continuation)
        defer { pending.removeValue(forKey: message.id)?.1.finish() }
        let connection = connection
        do {
            return try await withDeadline(seconds: timeout) {
                try await connection.send(message)
                for try await response in responses {
                    if let error = response.error { throw error }
                    return response.payload
                }
                throw CancellationError()
            }
        } catch {
            // There is no remote rollback. Closing propagates cancellation to the
            // provider and makes every other pending result explicitly uncertain.
            if error is CancellationError || (error as? TalkError) == .timedOut {
                await close()
            }
            throw error
        }
    }

    public func close() async {
        finish(TalkError.disconnected)
        await connection.close()
    }

    private func received(_ message: TalkMessage) async {
        switch message.kind {
        case .response:
            guard let (action, continuation) = pending.removeValue(forKey: message.id) else { return }
            guard action == message.action else {
                continuation.finish(throwing: TalkError.invalidMessage)
                await close()
                return
            }
            continuation.yield(message)
            continuation.finish()
        case .event:
            switch eventContinuation.yield(message) {
            case .dropped:
                finish(TalkError.eventOverflow)
                await connection.close()
            default: break
            }
        case .request:
            finish(TalkError.invalidMessage)
            await connection.close()
        }
    }

    private func finish(_ error: any Error) {
        connected = false
        negotiation?.1.cancel()
        negotiation = nil
        negotiated = nil
        reader?.cancel()
        reader = nil
        for (_, continuation) in pending.values { continuation.finish(throwing: error) }
        pending.removeAll()
        eventContinuation.finish(throwing: error)
    }
}
