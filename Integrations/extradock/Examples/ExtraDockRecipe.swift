import AppKit
import ExtraDockTalkContract
import Talk

/// Integration primitives for an app-owned coordinator, not a complete app.
/// Register talk-spike-consumer and forward URLs to the retained resolver AND
/// PairingDiscovery. Save consent using IntegrationStore before calling this.
/// `EndpointResolver.resolve` launches the provider when it is not running;
/// decide deliberately whether a background refresh may do that.
@MainActor
public func connectExtraDock(
    record: PairingRecord, resolver: EndpointResolver, callbackBundleID: String
) async throws -> ExtraDockDocksClient {
    guard ExtraDockRouting.providerBundleIDs.contains(record.providerBundleID),
          record.permits("extradock.docks.read"),
          record.scopes.isSubset(of: ExtraDockDocksAPI.scopes) else {
        throw TalkError.permissionDenied
    }
    let installation = try ProviderDiscovery.uniqueInstallation(
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: record.providerBundleID))
    let port = try await resolver.resolve(record: record, applicationURL: installation,
                                          callbackBundleID: callbackBundleID)
    let transport = try TalkClient(port: port, credential: record.credential)
    var actions: Set<String> = [ExtraDockDocksAPI.read]
    var events: Set<String> = []
    if record.permits("extradock.docks.control") { actions.insert(ExtraDockDocksAPI.setVisibility) }
    if record.permits("extradock.docks.observe") {
        actions.insert(ExtraDockDocksAPI.observe)
        events.insert(ExtraDockDocksAPI.changed)
    }
    let client = ExtraDockDocksClient(transport: transport, requiredActions: actions,
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
/// Every entry in the result reports its own status; `applied` describes the dock
/// after the command. If this throws after sending, reconcile with snapshot() and
/// never replay automatically.
public func setExtraDockVisibility(
    _ changes: [DockVisibilityChange], client: ExtraDockDocksClient, record: PairingRecord
) async throws -> SetDockVisibilityResult {
    guard record.permits("extradock.docks.control") else { throw TalkError.permissionDenied }
    guard !changes.isEmpty, changes.count <= ExtraDockRouting.maximumChangesPerRequest else {
        throw TalkError.invalidMessage
    }
    return try await client.setVisibility(SetDockVisibilityRequest(changes: changes), timeout: 20)
}

/// Convenience for a preset-style desired state: hidden docks are force-hidden,
/// visible docks return to their configured automatic policy.
public func extraDockDesiredState(visible: [UUID], hidden: [UUID]) -> [DockVisibilityChange] {
    hidden.map { DockVisibilityChange(dockID: $0, action: .hide) }
        + visible.map { DockVisibilityChange(dockID: $0, action: .automatic) }
}

/// The coordinator owns/cancels this task and marks disconnection on return.
/// Reject callbacks from old connections and apply revisions monotonically within
/// a provider session. A new connection's snapshot can establish a new sessionID.
public func observeExtraDocks(
    client: ExtraDockDocksClient, record: PairingRecord,
    accept: @escaping @Sendable (ExtraDocksSnapshot) async -> Void
) async throws {
    guard record.permits("extradock.docks.observe") else { throw TalkError.permissionDenied }
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
