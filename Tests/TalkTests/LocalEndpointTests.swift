import Foundation
import Network
import os
import Testing
@testable import Talk

struct LocalEndpointTests {
    @Test(.timeLimit(.minutes(2)))
    func connectsWhenListenerUsesFormerOutgoingSourcePort() async throws {
        var completed = 0
        for _ in 0..<16 {
            try await formerSourceTrial()
            completed += 1
        }
        #expect(completed == 16)
    }

    private func formerSourceTrial() async throws {
        let credential = try PairingCredential()
        let first = try EndpointTestListener(credential: credential, port: .any)
        defer { first.stop() }
        let initialPort = try await first.ready()
        let initial = NWConnection(host: "127.0.0.1", port: initialPort,
                                   using: try TLSConfiguration.parameters(credential: credential))
        defer { initial.cancel() }
        let initialStates = startStates(initial)
        let initialPeer = try await first.accept()
        let peerStates = startStates(initialPeer)
        try await waitUntilReady(initialStates)
        try await waitUntilReady(peerStates)
        // Keep the observed endpoint in memory. Assertions/logs expose only
        // equality and completion, never endpoint values or synthetic secrets.
        guard case .hostPort(_, let formerSource)? = initial.currentPath?.localEndpoint,
              formerSource != .any else { throw TalkError.unavailable }
        initial.cancel()
        initialPeer.cancel()
        // This recreates the observed rapid role change; it is deliberately not
        // a claim that cancellation has reclaimed kernel/framework reservations.
        try await Task.sleep(for: .milliseconds(20))
        let replacement = try EndpointTestListener(credential: credential, port: formerSource)
        defer { replacement.stop() }
        let replacementPort = try await replacement.ready()
        let listenerUsesFormerSource = replacementPort == formerSource
        try #require(listenerUsesFormerSource)
        let client = try TalkConnection(port: replacementPort.rawValue, credential: credential)
        do {
            // Exercise the SDK's outbound initializer and accepted initializer,
            // including mutual TLS readiness on both sides before success.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await client.start(timeout: 3) }
                group.addTask {
                    let peer = TalkConnection(accepted: try await replacement.accept())
                    try await peer.start(timeout: 3)
                }
                try await group.waitForAll()
            }
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    private func startStates(_ connection: NWConnection) -> AsyncThrowingStream<Void, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: continuation.yield(()); continuation.finish()
            case .waiting(let error), .failed(let error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish(throwing: TalkError.disconnected)
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        return stream
    }

    private func waitUntilReady(_ states: AsyncThrowingStream<Void, any Error>) async throws {
        try await withDeadline(seconds: 3) {
            for try await _ in states { return }
            throw TalkError.disconnected
        }
    }
}

private final class EndpointTestListener: Sendable {
    private let listener: NWListener
    private let ports: AsyncThrowingStream<NWEndpoint.Port, any Error>
    private struct PeerState: Sendable {
        var stopped = false
        var connections: [NWConnection] = []
        var pending: [NWConnection] = []
    }
    private let peers = OSAllocatedUnfairLock(initialState: PeerState())

    init(credential: PairingCredential, port: NWEndpoint.Port) throws {
        let parameters = try TLSConfiguration.parameters(credential: credential, isServer: true)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        // The fixed endpoint belongs only in requiredLocalEndpoint. Supplying
        // it in both places produces an unrelated invalid-configuration error.
        listener = try NWListener(using: parameters)
        let (ports, continuation) = AsyncThrowingStream<NWEndpoint.Port, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        self.ports = ports
        let listener = self.listener, peers = self.peers
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { continuation.yield(port); continuation.finish() }
                else { continuation.finish(throwing: TalkError.unavailable) }
            case .failed(let error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish(throwing: TalkError.disconnected)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            let accepted = peers.withLock { state in
                guard !state.stopped, state.connections.count < 4 else { return false }
                state.connections.append(connection)
                state.pending.append(connection)
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
        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let (connection, stopped) = peers.withLock { state in
                (state.pending.isEmpty ? nil : state.pending.removeFirst(), state.stopped)
            }
            if let connection { return connection }
            guard !stopped else { throw TalkError.unavailable }
            guard started.duration(to: .now) < .seconds(3) else { throw TalkError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() {
        let connections = peers.withLock { state in
            state.stopped = true
            let connections = state.connections
            state.connections.removeAll()
            state.pending.removeAll()
            return connections
        }
        listener.cancel()
        for connection in connections { connection.cancel() }
    }
}
