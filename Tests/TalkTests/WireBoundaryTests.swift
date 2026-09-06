import Foundation
import Network
import Testing
@testable import Talk

struct WireBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func maximumFrameSurvivesSplitHeaderAndBodyWrites() async throws {
        let overhead = try FrameCodec.encode(TalkMessage(kind: .request, action: "echo", payload: .string(""))).count - 4
        let input = String(repeating: "x", count: FrameCodec.maximumPayloadBytes - overhead)
        let output = JSONValue.string(String(input.dropLast()))
        let record = try grant()
        let server = TalkServer(record: record, actions: ["echo": "read"]) { _, value in
            guard value == .string(input) else { throw TalkError.invalidMessage }
            return output
        }
        let peer = try WirePeer(port: try await server.start(), credential: record.credential)
        do {
            try await peer.start()
            let message = TalkMessage(kind: .request, action: "echo", payload: .string(input))
            let frame = try FrameCodec.encode(message)
            #expect(frame.count == 65_540)
            // Distinct application writes include each individual header byte;
            // Network.framework may still coalesce packets on the wire.
            var offset = 0
            while offset < frame.count {
                let count = offset < 4 ? 1 : min(997, frame.count - offset)
                try await peer.send(Data(frame[offset..<(offset + count)]))
                offset += count
            }
            let header = try await peer.readExactly(4)
            let length = try FrameCodec.payloadLength(header)
            #expect(length == FrameCodec.maximumPayloadBytes)
            let response = try FrameCodec.decode(try await peer.readExactly(length))
            #expect(response.id == message.id)
            let matches = response.payload == output
            #expect(matches)
        } catch { peer.close(); await server.stop(); throw error }
        peer.close(); await server.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["zero", "oversize", "shortHeader", "shortBody", "deep", "utf8"])
    func malformedAuthenticatedPeerDoesNotDispatchOrBreakHealthyPeer(kind: String) async throws {
        let record = try grant()
        let counter = WireCounter()
        let server = TalkServer(record: record, actions: ["read": "read"]) { _, _ in .integer(await counter.increment()) }
        let port = try await server.start()
        let healthy = try TalkClient(port: port, credential: record.credential)
        let offender = try WirePeer(port: port, credential: record.credential)
        do {
            try await healthy.connect()
            #expect(try await healthy.request(action: "read") == .integer(1))
            try await offender.start()
            var bytes: Data
            var final = false
            switch kind {
            case "zero": bytes = Data([0, 0, 0, 0])
            case "oversize": bytes = Data([0, 1, 0, 1])
            case "shortHeader": bytes = Data([0, 0]); final = true
            case "shortBody": bytes = Data([0, 0, 0, 4, 123]); final = true
            case "deep":
                let body = Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)
                bytes = Data([0, 0, 0, UInt8(body.count)]) + body
            default: bytes = Data([0, 0, 0, 2, 255, 255])
            }
            try await offender.send(bytes, final: final)
            // An abrupt disconnect after a partial frame must not dispatch it.
            // This does not assume TLS half-close immediately delivers TCP EOF.
            if final { offender.close() }
            await #expect(throws: TalkError.disconnected) { try await offender.readExactly(1) }
            #expect(try await healthy.request(action: "read") == .integer(2))
            #expect(await counter.value == 2)
        } catch { offender.close(); await healthy.close(); await server.stop(); throw error }
        offender.close(); await healthy.close(); await server.stop()
    }

    private func grant() throws -> PairingRecord {
        PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic.wire", scopes: ["read"])
    }

    @Test(.timeLimit(.minutes(1)))
    func stalledPartialFrameExpiresWhileHealthyPeerStaysActive() async throws {
        let record = try grant()
        let counter = WireCounter()
        let server = TalkServer(record: record, actions: ["read": "read"], idleTimeout: 1) { _, _ in
            .integer(await counter.increment())
        }
        let port = try await server.start()
        let healthy = try TalkClient(port: port, credential: record.credential)
        let stalled = try WirePeer(port: port, credential: record.credential)
        do {
            try await healthy.connect()
            try await stalled.start()
            try await stalled.send(Data([0, 0, 0, 100, 123]))
            for index in 1...15 {
                #expect(try await healthy.request(action: "read") == .integer(Int64(index)))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            await #expect(throws: TalkError.disconnected) { try await stalled.readExactly(1) }
            #expect(await counter.value == 15)
        } catch { stalled.close(); await healthy.close(); await server.stop(); throw error }
        stalled.close(); await healthy.close(); await server.stop()
    }
}

private actor WireCounter {
    private(set) var value: Int64 = 0
    func increment() -> Int64 { value += 1; return value }
}

private struct WirePeer: Sendable {
    let connection: NWConnection
    init(port: UInt16, credential: PairingCredential) throws {
        let parameters = try TLSConfiguration.parameters(credential: credential)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let endpoint = NWEndpoint.Port(rawValue: port), port > 0 else { throw TalkError.unavailable }
        connection = NWConnection(host: "127.0.0.1", port: endpoint, using: parameters)
    }
    func start() async throws {
        let (states, continuation) = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: continuation.yield(()); continuation.finish()
            case .waiting, .failed, .cancelled: continuation.finish(throwing: TalkError.disconnected)
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        try await withTaskCancellationHandler {
            try await withDeadline(seconds: 5) {
                for try await _ in states { return }
                throw TalkError.disconnected
            }
        } onCancel: { connection.cancel() }
    }
    func send(_ bytes: Data, final: Bool = false) async throws {
        try await withDeadline(seconds: 5) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.send(content: bytes, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                                    completion: .contentProcessed { error in
                        if error != nil { continuation.resume(throwing: TalkError.disconnected) }
                        else { continuation.resume() }
                    })
                }
            } onCancel: { connection.cancel() }
        }
    }
    func readExactly(_ count: Int) async throws -> Data {
        try await withDeadline(seconds: 5) {
            try await withTaskCancellationHandler {
                var result = Data()
                while result.count < count {
                    try Task.checkCancellation()
                    let remaining = count - result.count
                    let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, _ in
                            if let data, !data.isEmpty { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: TalkError.disconnected) }
                        }
                    }
                    result.append(bytes)
                }
                return result
            } onCancel: { connection.cancel() }
        }
    }
    func close() { connection.cancel() }
}
