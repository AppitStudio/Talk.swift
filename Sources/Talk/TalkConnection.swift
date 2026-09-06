import Foundation
import Network

/// One reader per connection. Network.framework owns socket synchronization;
/// this actor owns framing and the bounded outstanding-write count.
public actor TalkConnection {
    private let connection: NWConnection
    nonisolated let diagnosticID = TransportDiagnostics.identifier()
    private var started = false
    private var reading = false
    private var writes = 0
    private var closed = false

    public init(port: UInt16, credential: PairingCredential) throws {
        guard let port = NWEndpoint.Port(rawValue: port), port.rawValue > 0 else { throw TalkError.unavailable }
        let parameters = try TLSConfiguration.parameters(credential: credential)
        // Bind the source address explicitly: an unspecified source reproduced
        // transient address conflicts when a listener reused a former client port.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
    }

    init(accepted connection: NWConnection) { self.connection = connection }

    public func start(timeout: Double = 10) async throws {
        guard started == false, closed == false else { throw TalkError.disconnected }
        started = true
        let diagnosticID = diagnosticID
        TransportDiagnostics.record("connection=\(diagnosticID) start")
        let (states, continuation) = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                TransportDiagnostics.record("connection=\(diagnosticID) ready")
                continuation.yield(()); continuation.finish()
            case .failed(let error):
                TransportDiagnostics.record("connection=\(diagnosticID) failed=\(TransportDiagnostics.error(error))")
                continuation.finish(throwing: TalkError.disconnected)
            case .waiting(let error):
                TransportDiagnostics.record("connection=\(diagnosticID) waiting=\(TransportDiagnostics.error(error))")
                continuation.finish(throwing: TalkError.disconnected)
            case .cancelled:
                TransportDiagnostics.record("connection=\(diagnosticID) cancelled")
                continuation.finish(throwing: TalkError.disconnected)
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        do {
            try await withTaskCancellationHandler {
                try await withDeadline(seconds: timeout) {
                    for try await _ in states { return }
                    throw CancellationError()
                }
            } onCancel: { self.connection.cancel() }
        } catch {
            close()
            throw error
        }
    }

    public func send(_ message: TalkMessage) async throws {
        guard started, closed == false else { throw TalkError.disconnected }
        guard writes < 16 else { throw TalkError.busy }
        let bytes = try FrameCodec.encode(message)
        writes += 1
        defer { writes -= 1 }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: TalkError.disconnected) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { self.connection.cancel() }
    }

    public func receive() async throws -> TalkMessage {
        guard reading == false, started, closed == false else { throw TalkError.disconnected }
        reading = true
        defer { reading = false }
        let header = try await readExactly(4)
        let length = try FrameCodec.payloadLength(header)
        return try FrameCodec.decode(try await readExactly(length))
    }

    public func close() {
        TransportDiagnostics.record("connection=\(diagnosticID) close")
        closed = true
        connection.cancel()
    }

    private func readExactly(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk: Data = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                        if let data, data.isEmpty == false { continuation.resume(returning: data) }
                        else if error != nil || complete { continuation.resume(throwing: TalkError.disconnected) }
                        else { continuation.resume(throwing: TalkError.invalidFrame) }
                    }
                }
            } onCancel: { self.connection.cancel() }
            buffer.append(chunk)
        }
        return buffer
    }
}
