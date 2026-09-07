import Foundation
import Network

public actor TalkListener {
    private var listener: NWListener?
    private var incoming: AsyncStream<TalkConnection>.Continuation?

    public init() {}
    deinit { listener?.cancel(); incoming?.finish() }

    public func start(credential: PairingCredential) async throws -> (UInt16, AsyncStream<TalkConnection>) {
        guard listener == nil else { throw TalkError.busy }
        let parameters = try TLSConfiguration.parameters(credential: credential, isServer: true)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let diagnosticID = TransportDiagnostics.identifier()
        TransportDiagnostics.record("listener=\(diagnosticID) start")
        let (connections, continuation) = AsyncStream<TalkConnection>.makeStream(bufferingPolicy: .bufferingOldest(8))
        incoming = continuation
        listener.newConnectionHandler = { connection in
            let peer = TalkConnection(accepted: connection)
            TransportDiagnostics.record("listener=\(diagnosticID) accept connection=\(peer.diagnosticID)")
            switch continuation.yield(peer) {
            case .dropped, .terminated:
                TransportDiagnostics.record("listener=\(diagnosticID) rejected-full-or-ended")
                connection.cancel()
            case .enqueued: break
            @unknown default: connection.cancel()
            }
        }
        let (ready, readyContinuation) = AsyncThrowingStream<UInt16, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                TransportDiagnostics.record("listener=\(diagnosticID) ready")
                if let port = listener?.port { readyContinuation.yield(port.rawValue); readyContinuation.finish() }
                else { readyContinuation.finish(throwing: TalkError.unavailable) }
            case .failed(let error):
                TransportDiagnostics.record("listener=\(diagnosticID) failure=\(TransportDiagnostics.error(error))")
                readyContinuation.finish(throwing: TalkError.unavailable)
                continuation.finish()
            case .cancelled:
                TransportDiagnostics.record("listener=\(diagnosticID) cancelled")
                readyContinuation.finish(throwing: TalkError.unavailable)
                continuation.finish()
            default: break
            }
        }
        listener.start(queue: .global(qos: .utility))
        do {
            let port = try await withDeadline(seconds: 10) {
                for try await port in ready { return port }
                throw CancellationError()
            }
            guard self.listener === listener else { throw TalkError.disconnected }
            return (port, connections)
        } catch {
            if self.listener === listener { stop() }
            else { listener.cancel() }
            throw error
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        incoming?.finish()
        incoming = nil
    }
}
