import AppKit
import Combine
import StudioContract
import Talk

@MainActor
final class AutomatorModel: ObservableObject {
    @Published var pairingCode = ""
    @Published var automationEnabled = true
    @Published private(set) var providers: [ProviderDiscovery.Candidate] = []
    @Published private(set) var sessions: [AutomatorSession] = []
    @Published private(set) var status = "Starting…"
    @Published private(set) var busy = false
    @Published private(set) var focusActive = false
    @Published private(set) var log: [String] = []
    var paired: Bool { !sessions.isEmpty }
    private let resolver = EndpointResolver()
    private var operation: Task<Void, Never>?
    private var started = false
    private let bundleID = Bundle.main.bundleIdentifier ?? "dev.talk.examples.paired.automator"
    private lazy var store = IntegrationStore(persistence: CredentialStore(service: bundleID + ".pairing"))
    deinit { operation?.cancel() }

    func start() async {
        guard !started else { return }
        started = true; busy = true
        defer { busy = false }
        refreshProviders()
        do {
            let records = try await store.reload()
            sessions = records.map { AutomatorSession(record: $0, resolver: resolver, callbackBundleID: bundleID) }
            status = paired ? "Saved integrations restored. Connect individually or start a focus session." : "Create a pairing code in Studio to begin."
        } catch { status = error.localizedDescription }
    }
    func refreshProviders() { providers = ProviderDiscovery.installed() }
    func handleURL(_ url: URL) { resolver.receive(url) }
    func pair() {
        run {
            let invitation = try PairingInvitation.parse(self.pairingCode)
            self.pairingCode = ""
            self.status = "Waiting for approval in Studio…"
            let record = try await PairingClient.pair(using: invitation)
            guard record.permits(StudioAPI.read), record.scopes.isSubset(of: StudioAPI.scopes) else { throw TalkError.permissionDenied }
            if let old = record.replacesID, let session = self.sessions.first(where: { $0.id == old }) {
                guard session.record.providerBundleID == record.providerBundleID else { throw TalkError.permissionDenied }
                await session.disconnect()
            }
            try await self.store.insert(record)
            self.sessions.removeAll { $0.id == record.replacesID }
            let session = AutomatorSession(record: record, resolver: self.resolver, callbackBundleID: self.bundleID)
            self.sessions.append(session)
            try await session.connect()
            self.status = "Integration saved. Each connection has independent permissions."
        }
    }
    func connect(_ session: AutomatorSession) {
        run {
            try await session.connect()
            self.status = "Connected with saved permission."
        }
    }
    func disconnect(_ session: AutomatorSession) {
        run {
            await session.disconnect()
            self.status = "Disconnected. Permission saved for reconnect."
        }
    }
    func forget(_ session: AutomatorSession) {
        run {
            await session.disconnect()
            try await self.store.remove(session.id)
            self.sessions.removeAll { $0.id == session.id }
            self.status = "Local credential removed. Revoke this integration in its provider too."
        }
    }
    func reload() {
        run {
            for session in self.sessions { await session.disconnect() }
            let records = try await self.store.reload()
            self.sessions = records.map { AutomatorSession(record: $0, resolver: self.resolver, callbackBundleID: self.bundleID) }
            self.status = "Reloaded actual protected storage."
        }
    }
    func toggleFocus() {
        run {
            self.focusActive.toggle()
            guard self.automationEnabled else { return }
            let desired = self.focusActive ? "focus" : "available"
            // A failure in one integration does not prevent other providers' work.
            for session in self.sessions where session.record.permits(StudioAPI.select) {
                do { try await session.select(desired); self.append("Selected \(desired) with saved permission.") }
                catch { self.append(error.localizedDescription) }
            }
            self.status = "Focus trigger processed for connections allowed to select scenes."
        }
    }
    private func append(_ message: String) {
        log.insert(message, at: 0)
        if log.count > 12 { log.removeLast() }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do { try await work() }
            catch is CancellationError { }
            catch { status = error.localizedDescription; append(error.localizedDescription) }
        }
    }
}
