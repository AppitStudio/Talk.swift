import AppKit
import DockFlowTalkContract
import Talk

/// Integration primitives for an app-owned coordinator, not a complete app.
/// Register talk-spike-consumer and forward URLs to the retained resolver AND
/// PairingDiscovery. Save consent using IntegrationStore before calling this.
/// Set `lockDock` to also require the contract 1.1 Lock Dock actions (DockFlow 1.89+,
/// apply scope). Against an older DockFlow that negotiation throws ContractDiagnostic:
/// call again with `lockDock: false` and hide the Lock Dock feature.
@MainActor
public func connectDockFlow(
    record: PairingRecord, resolver: EndpointResolver, callbackBundleID: String,
    lockDock: Bool = false
) async throws -> DockFlowPresetsClient {
    guard record.providerBundleID == DockFlowRouting.providerBundleID,
          record.permits("dockflow.presets.read"),
          record.scopes.isSubset(of: DockFlowPresetsAPI.scopes) else {
        throw TalkError.permissionDenied
    }
    let installation = try ProviderDiscovery.uniqueInstallation(
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: record.providerBundleID))
    let port = try await resolver.resolve(record: record, applicationURL: installation,
                                          callbackBundleID: callbackBundleID)
    let transport = try TalkClient(port: port, credential: record.credential)
    var actions: Set<String> = [DockFlowPresetsAPI.read]
    var events: Set<String> = []
    if record.permits("dockflow.presets.apply") {
        actions.insert(DockFlowPresetsAPI.apply)
        if lockDock {
            actions.insert(DockFlowPresetsAPI.relocateLockedDock)
            actions.insert(DockFlowPresetsAPI.openLockDockSettings)
        }
    }
    if record.permits("dockflow.presets.observe") {
        actions.insert(DockFlowPresetsAPI.observe)
        events.insert(DockFlowPresetsAPI.changed)
    }
    let client = DockFlowPresetsClient(transport: transport, requiredActions: actions,
                                       requiredEvents: events)
    do {
        try await client.connect()
        try Task.checkCancellation()
        return client
    } catch {
        await transport.close()
        throw error
    }
}

/// Pass the record used to create this client. The server enforces its actual scopes.
/// Bind to a deliberate user/automation trigger and serialize overlapping mutations.
/// Return accepted as "Applying"; it is not confirmation of completion. If this
/// throws after sending, reconcile with snapshot() and never replay automatically.
public func applyDockFlowPreset(
    _ id: UUID, client: DockFlowPresetsClient, record: PairingRecord
) async throws -> ApplyPresetResult {
    guard record.permits("dockflow.presets.apply") else { throw TalkError.permissionDenied }
    return try await client.applyPreset(ApplyPresetRequest(id: id), timeout: 20)
}

/// Contract 1.1: move the Dock back to its Lock Dock display. Requires a client connected
/// with `lockDock: true`. `moved` means the move started. For lockDockOff or
/// needsAccessibility, offer `client.openLockDockSettings()`. Never replay automatically.
public func relocateDockFlowLockedDock(
    client: DockFlowPresetsClient, record: PairingRecord
) async throws -> RelocateLockedDockResult {
    guard record.permits("dockflow.presets.apply") else { throw TalkError.permissionDenied }
    return try await client.relocateLockedDock()
}

/// The coordinator owns/cancels this task and marks disconnection on return.
/// Reject callbacks from old connections and apply revisions monotonically within
/// a provider session. A new connection's snapshot can establish a new sessionID.
public func observeDockFlowPresets(
    client: DockFlowPresetsClient, record: PairingRecord,
    accept: @escaping @Sendable (DockFlowPresetsSnapshot) async -> Void
) async throws {
    guard record.permits("dockflow.presets.observe") else { throw TalkError.permissionDenied }
    do {
        await accept(try await client.subscribe())
        for try await message in client.transport.events {
            try Task.checkCancellation()
            switch try client.decodeEvent(message) {
            case .changed(let snapshot): await accept(snapshot)
            }
        }
    } catch {
        await client.transport.close()
        throw error
    }
    await client.transport.close()
}
