import Darwin
import Foundation
import Talk

/// Local-only, memory-only validation. No credential storage or app discovery.
@main
struct ReadinessProbe {
    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "pressure": try await pressure()
            case "idle": try await idle()
            default: throw Failure.arguments
            }
            emit("result=PASS")
        } catch {
            emit("result=FAIL code=\((error as? TalkError)?.rawValue ?? (error as? Failure)?.rawValue ?? "unexpected")")
            exit(1)
        }
    }

    enum Failure: String, Error {
        case arguments, frameSize, payloadMismatch, peerLimit, idleSessionSurvived, gateCount
    }

    static func duration(default fallback: Int, minimum: Int, maximum: Int) throws -> Int {
        guard let seconds = Int(ProcessInfo.processInfo.environment["TALK_READINESS_SECONDS"] ?? String(fallback)),
              (minimum...maximum).contains(seconds) else { throw Failure.arguments }
        return seconds
    }

    static func emit(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    static func memory(_ stage: String) throws {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure.arguments }
        emit("memory stage=\(stage) footprintKiB=\(info.phys_footprint / 1024) peakFootprintKiB=\(max(0, info.ledger_phys_footprint_peak) / 1024) residentKiB=\(info.resident_size / 1024) reusableKiB=\(info.reusable / 1024)")
    }

    static func pressure() async throws {
        let seconds = try duration(default: 60, minimum: 5, maximum: 300)
        let reliefControl = ProcessInfo.processInfo.environment["TALK_READINESS_PRESSURE_RELIEF"] == "1"
        let overhead = try FrameCodec.encode(TalkMessage(kind: .request, action: "echo", payload: .string(""))).count - 4
        let text = String(repeating: "x", count: FrameCodec.maximumPayloadBytes - overhead)
        let payload = JSONValue.string(text)
        // "response" is one byte longer than "request" in this wire envelope.
        let response = JSONValue.string(String(text.dropLast()))
        guard try FrameCodec.encode(TalkMessage(kind: .request, action: "echo", payload: payload)).count == 65_540,
              try FrameCodec.encode(TalkMessage(kind: .response, action: "echo", payload: response)).count == 65_540 else {
            throw Failure.frameSize
        }
        let start = ContinuousClock.now
        var cycles = 0
        emit("pressure begin peers=8 retainedCalls=128 requestBodyBytes=65536 responseBodyBytes=65536 seconds=\(seconds)")
        repeat {
            let gate = PressureGate()
            let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic.pressure", scopes: ["echo"])
            let server = TalkServer(record: record, actions: ["echo": "echo"], handlerTimeout: 20) { _, value in
                guard value == payload else { throw Failure.payloadMismatch }
                await gate.wait()
                try Task.checkCancellation()
                return response
            }
            var clients: [TalkClient] = []
            do {
                let port = try await server.start()
                for _ in 0..<8 {
                    let client = try TalkClient(port: port, credential: record.credential)
                    clients.append(client)
                    try await client.connect()
                }
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    for client in clients {
                        for _ in 0..<16 {
                            group.addTask { try await client.request(action: "echo", payload: payload, timeout: 20) == response }
                        }
                    }
                    do {
                        let waiting = ContinuousClock.now
                        while await gate.count != 128 {
                            guard waiting.duration(to: .now) < .seconds(10) else { throw Failure.gateCount }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        if cycles.isMultiple(of: 10) { try memory("saturated") }
                        let excess = try TalkClient(port: port, credential: record.credential)
                        do {
                            try await excess.connect()
                            _ = try await excess.request(action: "echo", payload: payload, timeout: 3)
                            await excess.close()
                            throw Failure.peerLimit
                        } catch TalkError.disconnected { await excess.close() }
                        catch { await excess.close(); throw error }
                        guard await gate.count == 128 else { throw Failure.gateCount }
                        await gate.release()
                        var completed = 0
                        for try await matches in group {
                            guard matches else { throw Failure.payloadMismatch }
                            completed += 1
                        }
                        guard completed == 128 else { throw Failure.gateCount }
                    } catch {
                        // Release suspended provider work before structured child
                        // teardown. Cancellation alone cannot resume continuations.
                        await gate.release()
                        group.cancelAll()
                        throw error
                    }
                }
                for client in clients { await client.close() }
                await server.stop()
            } catch {
                await gate.release()
                for client in clients { await client.close() }
                await server.stop()
                throw error
            }
            cycles += 1
            if cycles == 1 || cycles.isMultiple(of: 10) {
                emit("pressure progress cycles=\(cycles) roundTrips=\(cycles * 128)")
                try memory("cycle")
            }
            if reliefControl, cycles.isMultiple(of: 100) {
                // Diagnostic control only: ask this probe's allocator to release
                // unused zones/pages. Never change the SDK's allocation policy.
                try memory("beforeRelief")
                let released = malloc_zone_pressure_relief(nil, 0)
                emit("pressure reliefControl=true releasedBytes=\(released)")
                try memory("afterRelief")
            }
        } while start.duration(to: .now) < .seconds(seconds)
        emit("pressure complete cycles=\(cycles) roundTrips=\(cycles * 128) rejectedExcessPeers=\(cycles)")
        emit("cooldown seconds=10 listeners=0")
        try await Task.sleep(for: .seconds(10))
        try memory("cooldown")
    }

    static func idle() async throws {
        let seconds = try duration(default: 600, minimum: 310, maximum: 1800)
        var records: [PairingRecord] = [], servers: [TalkServer] = [], clients: [TalkClient] = [], ports: [UInt16] = []
        do {
            for _ in 0..<16 {
                let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic.idle", scopes: ["read"])
                let server = TalkServer(record: record, actions: ["read": "read"]) { _, _ in .integer(1) }
                records.append(record); servers.append(server)
                let port = try await server.start(); ports.append(port)
                let client = try TalkClient(port: port, credential: record.credential); clients.append(client)
                try await client.connect()
                guard try await client.request(action: "read") == .integer(1) else { throw Failure.payloadMismatch }
            }
            var before = rusage()
            getrusage(RUSAGE_SELF, &before)
            emit("idle begin integrations=16 seconds=\(seconds) defaultIdleTimeout=300")
            try await Task.sleep(for: .seconds(seconds))
            var after = rusage()
            getrusage(RUSAGE_SELF, &after)
            func micros(_ time: timeval) -> Int64 { Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec) }
            let cpu = micros(after.ru_utime) + micros(after.ru_stime) - micros(before.ru_utime) - micros(before.ru_stime)
            emit("idle complete processCPUTimeMicroseconds=\(cpu)")
            for client in clients {
                do {
                    _ = try await client.request(action: "read", timeout: 3)
                    throw Failure.idleSessionSurvived
                } catch TalkError.disconnected { }
            }
            for client in clients { await client.close() }
            clients.removeAll()
            for index in records.indices {
                let client = try TalkClient(port: ports[index], credential: records[index].credential)
                clients.append(client)
                try await client.connect()
                guard try await client.request(action: "read") == .integer(1) else { throw Failure.payloadMismatch }
            }
            emit("idle recovery staleSessionsClosed=16 sameGrantReconnects=16")
            for client in clients { await client.close() }
            for server in servers { await server.stop() }
        } catch {
            for client in clients { await client.close() }
            for server in servers { await server.stop() }
            throw error
        }
        emit("cooldown seconds=10 listeners=0")
        try await Task.sleep(for: .seconds(10))
    }
}

private actor PressureGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var count = 0
    func wait() async {
        count += 1
        if open { return }
        await withCheckedContinuation { continuation in continuations.append(continuation) }
    }
    func release() {
        open = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
