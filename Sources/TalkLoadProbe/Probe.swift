import Foundation
import Darwin
@_spi(Validation) import Talk
import StudioContract

/// Standalone measured workload avoids test-framework assertion/event retention.
/// Synthetic grants stay in memory; it cannot load or modify example credentials.
@main
struct LoadProbe {
    @MainActor
    static func main() async {
        do {
            emit("LOAD startup noninteractive=true persistence=memory")
            try await run()
        }
        catch { emit("LOAD failed: \(error)"); exit(1) }
    }
    static func run() async throws {
        // Explicit opt-in runs may span 30 minutes; ordinary invocations remain
        // three minutes. The external observer retains its RSS/watchdog limits.
        let seconds = min(1800, max(5, Int(ProcessInfo.processInfo.environment["TALK_SUSTAINED_SECONDS"] ?? "180") ?? 180))
        let injectEstablishmentFailure = ProcessInfo.processInfo.environment["TALK_LOAD_TEST_ESTABLISHMENT_FAILURE"] == "1"
        let provider = TalkProvider(store: IntegrationStore(persistence: VolatileIntegrations()), contract: StudioAPI.schema,
                                    subscriptionAction: StudioAPI.observe) { _, _ in
            try .encoding(StudioSnapshot(sessionID: UUID(), revision: 1, selectedSceneID: "focus"))
        }
        emit("LOAD preparing integrations=16")
        try await provider.restore()
        var records: [PairingRecord] = []
        for _ in 0..<16 {
            let record = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
            try await provider.approve(record); records.append(record)
        }
        emit("LOAD ready integrations=16")
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        var cycles = 0, calls = 0, events = 0, connections = 0, recoveredConnections = 0
        var phase = "setup" {
            didSet {
                if cycles == 0, !phase.hasPrefix("event-"), !phase.hasPrefix("snapshot-"),
                   !phase.hasPrefix("publish-"), !phase.hasPrefix("slow-barrier-"),
                   ProcessInfo.processInfo.environment["TALK_TRANSPORT_DIAGNOSTICS"] == "1" {
                    emit("LOAD firstCycle phase=\(phase)")
                }
            }
        }
        var clients: [StudioClient] = []
        // Endpoint values remain private, bounded in memory; only equality and
        // counts are emitted when an establishment failure needs localization.
        var retiredPorts = Set<UInt16>()
        var mostRecentlyRetiredPort: UInt16?
        do {
            repeat {
                clients.removeAll(keepingCapacity: true)
                let endpoints = await provider.endpoints()
                for record in records {
                    phase = "connect-\(clients.count)"
                    guard let port = endpoints[record.credential.id] else { throw TalkError.unavailable }
                    var client = StudioClient(transport: try TalkClient(port: port, credential: record.credential))
                    clients.append(client)
                    do {
                        phase = "handshake-\(clients.count - 1)"
                        if injectEstablishmentFailure, cycles == 0, clients.count == 1 {
                            emit("LOAD injectedEstablishmentFailure=true applicationCalls=0")
                            throw TalkError.disconnected
                        }
                        try await client.connect()
                        phase = "subscribe-\(clients.count - 1)"
                        _ = try await client.subscribe()
                    } catch {
                        let establishmentError = error
                        // Explicit benchmark recovery control: a fresh connection
                        // to the SAME port/key, before any mutating call. This is
                        // not SDK retry behavior and never replays a mutation.
                        for event in TransportDiagnostics.snapshot() { emit("TRANSPORT " + event) }
                        emit("LOAD connectionFailure cycle=\(cycles) phase=\(phase) error=\(error)")
                        emit("LOAD endpointControl active=\(endpoints.count) distinctActive=\(Set(endpoints.values).count) previouslyRetired=\(retiredPorts.contains(port)) equalsLastRetired=\(mostRecentlyRetiredPort == port) retiredDistinct=\(retiredPorts.count)")
                        await client.transport.close()
                        client = StudioClient(transport: try TalkClient(port: port, credential: record.credential))
                        clients[clients.count - 1] = client
                        phase = "same-grant-recovery-\(clients.count - 1)"
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        do {
                            try await client.connect(); _ = try await client.subscribe()
                        } catch {
                            // Bounded, read-only localization after same-grant
                            // failure. Neither control alters grants or replays a
                            // mutating action. The original run still fails.
                            for event in TransportDiagnostics.snapshot() { emit("TRANSPORT " + event) }
                            try await rawTCPControl(port: port)
                            let other = records[clients.count % records.count]
                            if let otherPort = endpoints[other.credential.id] {
                                emit("LOAD otherGrantControl destinationEqualsFailed=\(otherPort == port)")
                                let control = StudioClient(transport: try TalkClient(port: otherPort, credential: other.credential))
                                do {
                                    try await control.connect(); _ = try await control.snapshot()
                                    emit("LOAD otherGrantControl=success")
                                } catch { emit("LOAD otherGrantControl=failed error=\(error)") }
                                await control.transport.close()
                            }
                            emit("LOAD delayedSameGrantControl waitSeconds=35")
                            try await Task.sleep(nanoseconds: 35_000_000_000)
                            let delayed = StudioClient(transport: try TalkClient(port: port, credential: record.credential))
                            do {
                                try await delayed.connect(); _ = try await delayed.snapshot()
                                emit("LOAD delayedSameGrantControl=success")
                            } catch { emit("LOAD delayedSameGrantControl=failed error=\(error)") }
                            await delayed.transport.close()
                            throw establishmentError
                        }
                        recoveredConnections += 1
                        emit("LOAD explicitSameGrantRecovery=success")
                        // Recovery is diagnostic evidence only. It cannot erase
                        // the first establishment failure or resume the workload.
                        throw establishmentError
                    }
                    connections += 1
                }
                var iterators = clients.dropLast().map { $0.transport.events.makeAsyncIterator() }
                for revision in 1...65 {
                    phase = "snapshot-\(revision)"
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for client in clients.dropLast() { group.addTask { _ = try await client.snapshot() } }
                        try await group.waitForAll()
                    }
                    calls += 15
                    phase = "publish-\(revision)"
                    await provider.publish(action: StudioAPI.changed, payload: try .encoding(StudioSnapshot(sessionID: UUID(), revision: Int64(revision), selectedSceneID: "focus")))
                    for index in iterators.indices {
                        phase = "event-\(revision)-\(index)"
                        guard try await iterators[index].next()?.action == StudioAPI.changed else { throw TalkError.invalidMessage }
                        events += 1
                    }
                    phase = "slow-barrier-\(revision)"
                    if revision < 65 { _ = try await clients[15].snapshot(); calls += 1 }
                }
                // Keep the slow event stream unread until its 65th event has
                // arrived. A read-only response shares the server output queue,
                // so it cannot overtake that event and accidentally begin draining
                // before overflow. Failed reads are not counted or retried.
                phase = "slow-overflow-barrier"
                do {
                    _ = try await clients[15].snapshot()
                    throw TalkError.invalidMessage
                } catch TalkError.eventOverflow { }
                  catch TalkError.disconnected { }
                phase = "slow-drain"
                var slowEvents = 0, overflow = false
                do { for try await _ in clients[15].transport.events { slowEvents += 1 } }
                catch TalkError.eventOverflow { overflow = true }
                guard overflow, slowEvents == 64 else { throw TalkError.invalidMessage }
                phase = "revoke"
                if let retiring = endpoints[records[0].credential.id] {
                    mostRecentlyRetiredPort = retiring
                    retiredPorts.insert(retiring)
                }
                try await provider.revoke(records[0].credential.id)
                var revoked = false
                do { _ = try await clients[0].snapshot() } catch { revoked = true }
                guard revoked else { throw TalkError.permissionDenied }
                phase = "surviving-mutation"
                _ = try await clients[1].selectScene(SelectScene(id: "focus")); calls += 1
                for client in clients { await client.transport.close() }
                let replacement = PairingRecord(credential: try PairingCredential(), providerBundleID: "dev.talk.synthetic", scopes: StudioAPI.scopes)
                try await provider.approve(replacement); records[0] = replacement
                cycles += 1
                if cycles % 20 == 0 { emit("LOAD progress cycles=\(cycles) calls=\(calls)") }
            } while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) < UInt64(seconds) * 1_000_000_000
        } catch {
            for event in TransportDiagnostics.snapshot() { emit("TRANSPORT " + event) }
            emit("LOAD failure cycle=\(cycles) phase=\(phase) error=\(error)")
            for client in clients { await client.transport.close() }
            await provider.stop(); throw error
        }
        clients.removeAll()
        for record in records { try await provider.revoke(record.credential.id) }
        guard await provider.integrations().isEmpty else { throw TalkError.invalidMessage }
        await provider.stop()
        emit("LOAD complete durationSeconds=\(Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1_000_000_000) integrations=16 cycles=\(cycles) calls=\(calls) events=\(events) connections=\(connections) overflows=\(cycles) revocations=\(cycles) recoveredConnections=\(recoveredConnections)")
        emit("LOAD cooldown listenersStopped=true grants=0 seconds=10")
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }
    static func emit(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }

    /// Failure-only kernel establishment control. Sends no application/TLS data,
    /// never changes trust/reuse settings, and always closes its single socket.
    static func rawTCPControl(port: UInt16) async throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { emit("LOAD rawTCPControl socketErrno=\(errno)"); return }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            emit("LOAD rawTCPControl fcntlErrno=\(errno)"); return
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let connectError = result == 0 ? 0 : errno
        guard result == 0 || connectError == EINPROGRESS else {
            emit("LOAD rawTCPControl connectErrno=\(connectError)"); return
        }
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        var pollState = pollfd(fd: descriptor, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0)
        while result != 0 {
            let ready = poll(&pollState, 1, 0)
            if ready > 0 { break }
            if ready < 0 { emit("LOAD rawTCPControl pollErrno=\(errno)"); return }
            guard (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started) < UInt64(2) * 1_000_000_000 else {
                emit("LOAD rawTCPControl timeoutSeconds=2"); return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var socketError: Int32 = 0
        var errorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorSize) == 0 else {
            emit("LOAD rawTCPControl getsockoptErrno=\(errno)"); return
        }
        emit("LOAD rawTCPControl connectErrno=\(connectError) completionSOError=\(socketError) applicationBytes=0")
    }
}

private actor VolatileIntegrations: IntegrationPersistence {
    private var records: [PairingRecord] = []
    func loadRecords() -> [PairingRecord] { records }
    func saveRecords(_ records: [PairingRecord]) { self.records = records }
}
