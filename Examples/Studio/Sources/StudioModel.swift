import AppKit
import Combine
import StudioContract
import Talk

@MainActor
final class StudioModel: ObservableObject {
    @Published private(set) var snapshot = StudioSnapshot(sessionID: UUID(), revision: 0, selectedSceneID: "available")
    @Published private(set) var status = "Starting…"
    @Published private(set) var integrations: [IntegrationStatus] = []
    @Published var integrationName = "Automator"
    private var consentLabel = "Automator"
    @Published var allowSelection = true
    @Published var allowObservation = true
    @Published private(set) var consentScopes: Set<String> = []
    var paired: Bool { !integrations.isEmpty }
    @Published private(set) var invitation = ""
    @Published private(set) var approvalPending = false
    @Published private(set) var port: UInt16?
    @Published private(set) var busy = false
    @Published private(set) var calls = 0
    private var provider: TalkProvider?
    private var endpoints: [UUID: UInt16] = [:]
    private var replacementID: UUID?
    private var pairingHost: PairingHost?
    private var approval: AsyncStream<Bool>.Continuation?
    private var operation: Task<Void, Never>?
    private var started = false
    private var ready = false
    private var queuedURLs: [URL] = []
    private let bundleID = Bundle.main.bundleIdentifier ?? "dev.talk.examples.paired.studio"
    private lazy var store = IntegrationStore(persistence: CredentialStore(service: bundleID + ".pairing"))

    deinit { operation?.cancel(); approval?.finish() }

    func start() async {
        guard started == false else { return }
        started = true
        busy = true
        defer { busy = false }
        do {
            let provider = TalkProvider(store: store, contract: StudioAPI.schema, subscriptionAction: StudioAPI.observe) { [weak self] action, payload in
                guard let self else { throw TalkError.unavailable }
                return try await self.handle(action: action, payload: payload)
            }
            self.provider = provider
            try await provider.restore()
            await refreshIntegrations()
            status = paired ? "Integrations restored with saved permissions." : "Create a pairing code to connect Talk Automator."
        } catch { status = error.localizedDescription }
        ready = true
        for url in queuedURLs { handleURL(url) }
        queuedURLs.removeAll()
    }

    func createInvitation() { createInvitation(replacing: nil) }

    func createInvitation(replacing id: UUID?) {
        run {
            guard self.integrations.count < 16 || id != nil else { throw TalkError.busy }
            guard self.integrationName.utf8.count <= 128 else { throw TalkError.invalidMessage }
            self.consentLabel = self.integrationName
            self.replacementID = id
            self.consentScopes = [StudioAPI.read]
            if self.allowSelection { self.consentScopes.insert(StudioAPI.select) }
            if self.allowObservation { self.consentScopes.insert(StudioAPI.observe) }
            await self.pairingHost?.stop()
            let host = PairingHost()
            self.pairingHost = host
            let invitation = try await host.start(providerBundleID: self.bundleID) { [weak self] in
                guard let self else { throw TalkError.unavailable }
                return try await self.authorizeIntegration()
            }
            self.invitation = try invitation.code()
            self.status = "Paste the code into Automator within five minutes."
        }
    }

    func copyInvitation() {
        guard invitation.isEmpty == false else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invitation, forType: .string)
        status = "Pairing code copied. Treat it as a temporary secret."
    }

    func decide(_ allowed: Bool) {
        approval?.yield(allowed)
        approval?.finish()
        approval = nil
        approvalPending = false
    }

    func revoke(_ id: UUID) {
        run {
            do { try await self.provider?.revoke(id) }
            catch { await self.refreshIntegrations(); throw error }
            await self.refreshIntegrations()
            self.status = "Selected integration revoked. Other connections remain available."
        }
    }

    func reloadIntegrations() {
        run {
            try await self.provider?.restore()
            await self.refreshIntegrations()
            self.status = "Reloaded actual protected storage. Inspect each integration’s state."
        }
    }

    private func refreshIntegrations() async {
        integrations = await provider?.integrations() ?? []
        endpoints = await provider?.endpoints() ?? [:]
        port = endpoints.values.first
    }

    func selectScene(_ id: String) { run { _ = try await self.updateScene(id) } }

    func handleURL(_ url: URL) {
        guard ready else {
            if queuedURLs.count < 4 { queuedURLs.append(url) }
            return
        }
        for (id, port) in endpoints {
            EndpointResolver.reply(to: url, pairingID: id, port: port,
                                   allowedCallbackBundleIDs: ["dev.talk.examples.paired.automator", "dev.talk.examples.paired.automator.sandbox"])
        }
    }

    private func authorizeIntegration() async throws -> PairingRecord {
        guard approvalPending == false else { throw TalkError.busy }
        let (decisions, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        approval = continuation
        approvalPending = true
        invitation = ""
        // Visible UI is intentional for the first explicit permission grant.
        NSApp.activate(ignoringOtherApps: true)
        let allowed = await withTaskCancellationHandler {
            for await decision in decisions { return decision }
            return false
        } onCancel: { continuation.finish() }
        approvalPending = false
        approval = nil
        try Task.checkCancellation()
        guard allowed else { status = "Pairing denied. Create a new code to try again."; throw TalkError.permissionDenied }
        guard busy == false else { throw TalkError.busy }
        busy = true
        defer { busy = false }
        let record = PairingRecord(credential: try PairingCredential(), providerBundleID: bundleID,
                                   scopes: consentScopes, replacesID: replacementID, label: consentLabel)
        guard let provider else { throw TalkError.unavailable }
        do { try await provider.approve(record) }
        catch { await refreshIntegrations(); throw error }
        await refreshIntegrations()
        status = "Integration approved. These permissions persist until revoked."
        return record
    }

    private func handle(action: String, payload: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        calls += 1
        switch action {
        case StudioAPI.read, StudioAPI.observe:
            guard payload == .null else { throw TalkError.invalidMessage }
            return try .encoding(snapshot)
        case StudioAPI.select:
            return try .encoding(await updateScene(payload.decode(SelectScene.self).id))
        default: throw TalkError.unknownAction
        }
    }

    private func updateScene(_ id: String) async throws -> StudioSnapshot {
        try Task.checkCancellation()
        guard Scene.examples.contains(where: { $0.id == id }) else { throw TalkError.invalidMessage }
        let next = StudioSnapshot(sessionID: snapshot.sessionID, revision: snapshot.revision + 1, selectedSceneID: id)
        snapshot = next
        await provider?.publish(action: StudioAPI.changed, payload: try .encoding(next))
        return next
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard busy == false else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do { try await work() }
            catch is CancellationError { }
            catch { status = error.localizedDescription }
        }
    }
}
