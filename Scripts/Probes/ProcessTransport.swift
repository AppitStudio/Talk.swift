// Compiled with the actual SDK transport sources by validate-process-transport.py.
// stdin/stdout are private anonymous control pipes, never evidence logs.
import Foundation
import Network
import os

private struct Command: Codable, Sendable {
    let operation: String
    var credential: PairingCredential?
    var port: UInt16?
}

private struct Reply: Codable {
    var result = "ok"
    var credential: PairingCredential?
    var port: UInt16?
    var diagnostics: [String]?
}

private enum Channel {
    static let queue = DispatchQueue(label: "talk.validation.control")
    static func read() async throws -> Command {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    var data = Data()
                    while data.count < 4096 {
                        guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else {
                            throw TalkError.disconnected
                        }
                        if byte == Data([10]) {
                            continuation.resume(returning: try JSONDecoder().decode(Command.self, from: data))
                            return
                        }
                        data.append(byte)
                    }
                    throw TalkError.invalidMessage
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func write(_ reply: Reply) throws {
        var bytes = try JSONEncoder().encode(reply)
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}

@main
private enum ProcessTransport {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "provider" { try await provider() }
            else { try await consumer() }
        } catch {
            // Error descriptions may contain endpoint data. Only fixed SDK codes
            // and the SDK's bounded anonymous numeric diagnostics leave memory.
            try? Channel.write(Reply(result: (error as? TalkError)?.rawValue ?? "probeFailure",
                                     diagnostics: TransportDiagnostics.snapshot()))
            exit(1)
        }
    }

    static func provider() async throws {
        var original: ProbeListener?
        var replacement: ProbeListener?
        var seed: NWConnection?
        defer { seed?.cancel(); original?.stop(); replacement?.stop() }
        while true {
            let command = try await Channel.read()
            switch command.operation {
            case "listen":
                seed?.cancel(); original?.stop(); replacement?.stop()
                original = nil; replacement = nil; seed = nil
                let credential = try PairingCredential()
                let listener = try ProbeListener(credential: credential, port: .any)
                original = listener
                try Channel.write(Reply(credential: credential, port: try await listener.ready().rawValue))
            case "seed":
                guard let original else { throw TalkError.invalidMessage }
                let peer = try await original.accept()
                seed = peer
                try await ready(peer)
                try Channel.write(Reply())
            case "replace":
                guard let credential = command.credential, let port = command.port,
                      let endpoint = NWEndpoint.Port(rawValue: port), port > 0 else { throw TalkError.invalidMessage }
                seed?.cancel(); seed = nil
                try await Task.sleep(for: .milliseconds(20))
                // Keep the first listener alive, matching the in-process control.
                let listener = try ProbeListener(credential: credential, port: endpoint)
                replacement = listener
                guard try await listener.ready() == endpoint else { throw TalkError.unavailable }
                try Channel.write(Reply())
            case "exchange":
                guard let replacement else { throw TalkError.invalidMessage }
                let peer = TalkConnection(accepted: try await replacement.accept())
                do {
                    try await peer.start(timeout: 3)
                    try await withDeadline(seconds: 5) {
                        for _ in 0..<8 {
                            let request = try await peer.receive()
                            guard request.kind == .request, request.action == "probe.echo", request.payload == .string("synthetic") else {
                                throw TalkError.invalidMessage
                            }
                            try await peer.send(TalkMessage(kind: .response, id: request.id, action: request.action, payload: request.payload))
                        }
                        // Client acknowledgement proves the last response arrived.
                        let ack = try await peer.receive()
                        guard ack.action == "probe.complete" else { throw TalkError.invalidMessage }
                    }
                    await peer.close()
                } catch { await peer.close(); throw error }
                try Channel.write(Reply())
            case "reject":
                guard let replacement else { throw TalkError.invalidMessage }
                let peer = TalkConnection(accepted: try await replacement.accept())
                do {
                    try await peer.start(timeout: 3)
                    await peer.close()
                    throw TalkError.invalidMessage
                } catch TalkError.disconnected {
                    await peer.close()
                    try Channel.write(Reply(result: "rejected", diagnostics: TransportDiagnostics.snapshot()))
                } catch { await peer.close(); throw error }
            case "stop": try Channel.write(Reply()); return
            default: throw TalkError.invalidMessage
            }
        }
    }

    static func consumer() async throws {
        var seed: NWConnection?
        defer { seed?.cancel() }
        while true {
            let command = try await Channel.read()
            switch command.operation {
            case "seed":
                guard let credential = command.credential, let port = command.port,
                      let endpoint = NWEndpoint.Port(rawValue: port) else { throw TalkError.invalidMessage }
                let connection = NWConnection(host: "127.0.0.1", port: endpoint,
                                              using: try TLSConfiguration.parameters(credential: credential))
                seed = connection
                try await ready(connection)
                guard case .hostPort(_, let source)? = connection.currentPath?.localEndpoint, source != .any else {
                    throw TalkError.unavailable
                }
                try Channel.write(Reply(port: source.rawValue))
            case "closeSeed": seed?.cancel(); seed = nil; try Channel.write(Reply())
            case "exchange", "reject":
                guard let credential = command.credential, let port = command.port else { throw TalkError.invalidMessage }
                let key = command.operation == "reject" ? try PairingCredential() : credential
                let client = try TalkConnection(port: port, credential: key)
                do {
                    try await client.start(timeout: 3)
                    guard command.operation != "reject" else { throw TalkError.invalidMessage }
                    try await withDeadline(seconds: 5) {
                        for _ in 0..<8 {
                            let request = TalkMessage(kind: .request, action: "probe.echo", payload: .string("synthetic"))
                            try await client.send(request)
                            let response = try await client.receive()
                            guard response.kind == .response, response.id == request.id,
                                  response.action == request.action, response.payload == request.payload else { throw TalkError.invalidMessage }
                        }
                        try await client.send(TalkMessage(kind: .request, action: "probe.complete"))
                    }
                    await client.close()
                    try Channel.write(Reply())
                } catch TalkError.disconnected where command.operation == "reject" {
                    await client.close()
                    try Channel.write(Reply(result: "rejected", diagnostics: TransportDiagnostics.snapshot()))
                } catch { await client.close(); throw error }
            case "stop": try Channel.write(Reply()); return
            default: throw TalkError.invalidMessage
            }
        }
    }

    static func ready(_ connection: NWConnection) async throws {
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: continuation.yield(()); continuation.finish()
            case .failed(let error), .waiting(let error):
                TransportDiagnostics.record("seed failure=\(TransportDiagnostics.error(error))")
                continuation.finish(throwing: TalkError.disconnected)
            case .cancelled: continuation.finish(throwing: TalkError.disconnected)
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        try await withTaskCancellationHandler {
            try await withDeadline(seconds: 3) {
                for try await _ in stream { return }
                throw TalkError.disconnected
            }
        } onCancel: { connection.cancel() }
    }
}

private final class ProbeListener: Sendable {
    let listener: NWListener
    let ports: AsyncThrowingStream<NWEndpoint.Port, any Error>
    private struct State: Sendable {
        var stopped = false
        var all: [NWConnection] = []
        var pending: [NWConnection] = []
    }
    private let peers = OSAllocatedUnfairLock(initialState: State())
    init(credential: PairingCredential, port: NWEndpoint.Port) throws {
        let parameters = try TLSConfiguration.parameters(credential: credential, isServer: true)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        listener = try NWListener(using: parameters)
        let (stream, continuation) = AsyncThrowingStream<NWEndpoint.Port, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        ports = stream
        let listener = self.listener, peers = self.peers
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { continuation.yield(port); continuation.finish() }
                else { continuation.finish(throwing: TalkError.unavailable) }
            case .failed(let error):
                TransportDiagnostics.record("listener failure=\(TransportDiagnostics.error(error))")
                continuation.finish(throwing: TalkError.unavailable)
            case .cancelled: continuation.finish(throwing: TalkError.disconnected)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            let accepted = peers.withLock { state in
                guard !state.stopped, state.all.count < 4 else { return false }
                state.all.append(connection); state.pending.append(connection)
                return true
            }
            if !accepted { connection.cancel() }
        }
        listener.start(queue: .global(qos: .utility))
    }
    func ready() async throws -> NWEndpoint.Port {
        try await withDeadline(seconds: 3) {
            for try await port in self.ports { return port }
            throw TalkError.unavailable
        }
    }
    func accept() async throws -> NWConnection {
        try await withDeadline(seconds: 3) {
            while true {
                try Task.checkCancellation()
                if let connection = self.peers.withLock({ $0.pending.isEmpty ? nil : $0.pending.removeFirst() }) { return connection }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    func stop() {
        let connections = peers.withLock { state in
            state.stopped = true
            let all = state.all
            state.all.removeAll(); state.pending.removeAll()
            return all
        }
        listener.cancel()
        for connection in connections { connection.cancel() }
    }
}
