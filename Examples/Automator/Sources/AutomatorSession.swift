import AppKit
import Combine
import StudioContract
import Talk

@MainActor
final class AutomatorSession: ObservableObject, Identifiable {
    let record: PairingRecord
    nonisolated var id: UUID { record.credential.id }
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Saved permission"
    @Published private(set) var snapshot: StudioSnapshot?
    private var client: StudioClient?
    private var eventTask: Task<Void, Never>?
    private let resolver: EndpointResolver
    private let callbackBundleID: String
    init(record: PairingRecord, resolver: EndpointResolver, callbackBundleID: String) {
        self.record = record; self.resolver = resolver; self.callbackBundleID = callbackBundleID
    }
    deinit { eventTask?.cancel() }

    func connect() async throws {
        guard !busy else { throw TalkError.busy }
        busy = true
        defer { busy = false }
        await disconnect()
        status = "Connecting…"
        do {
            let url = try ProviderDiscovery.uniqueInstallation(NSWorkspace.shared.urlsForApplications(withBundleIdentifier: record.providerBundleID))
            let port = try await resolver.resolve(record: record, applicationURL: url, callbackBundleID: callbackBundleID)
            let transport = try TalkClient(port: port, credential: record.credential)
            let next = StudioClient(transport: transport)
            do {
                try await next.connect()
                accept(try await (record.permits(StudioAPI.observe) ? next.subscribe() : next.snapshot()))
                client = next
                connected = true
                status = "Connected with saved permission"
                eventTask = Task { [weak self] in
                    do {
                        for try await event in transport.events {
                            try Task.checkCancellation()
                            switch try next.decodeEvent(event) {
                            case .changed(let value): self?.accept(value)
                            }
                        }
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled else { return }
                        self?.connected = false
                        self?.status = error.localizedDescription
                    }
                }
            } catch { await transport.close(); throw error }
        } catch { status = error.localizedDescription; throw error }
    }

    func disconnect() async {
        eventTask?.cancel(); eventTask = nil
        let old = client; client = nil; connected = false
        await old?.transport.close()
        status = "Disconnected · Permission saved"
    }

    func select(_ id: String) async throws {
        guard record.permits(StudioAPI.select) else { throw TalkError.permissionDenied }
        if !connected { try await connect() }
        guard let client else { throw TalkError.disconnected }
        // One new action after reconnect; never replay after uncertain delivery.
        accept(try await client.selectScene(SelectScene(id: id)))
    }

    private func accept(_ value: StudioSnapshot) {
        if let snapshot, snapshot.sessionID == value.sessionID, value.revision < snapshot.revision { return }
        snapshot = value
    }
}
