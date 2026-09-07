import AppKit
import IntegrationContract
import Talk

// The app must own/serialize pairing, connection and event tasks; these are primitives.
// Discover/Connect use a retained PairingDiscovery and explicit comparison UI; see
// references/pairing.md. Forward incoming URLs to both discovery and the resolver.
// Reload the consumer store at startup. Close the old session before saving replacement.
public func saveReceivedGrant(_ record: PairingRecord, expectedProviderBundleID: String,
                              store: IntegrationStore) async throws {
    guard record.providerBundleID == expectedProviderBundleID,
          record.permits("example.view"), record.scopes.isSubset(of: ExampleAPI.scopes) else {
        throw TalkError.permissionDenied
    }
    try Task.checkCancellation()
    try await store.insert(record)
}

// Keep resolver alive and route incoming URLs to resolver.receive(_:) in the app delegate.
@MainActor
public func connectSaved(_ record: PairingRecord, resolver: EndpointResolver,
                         callbackBundleID: String) async throws -> ExampleClient {
    let installation = try ProviderDiscovery.uniqueInstallation(
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: record.providerBundleID))
    let port = try await resolver.resolve(record: record, applicationURL: installation,
                                          callbackBundleID: callbackBundleID)
    let transport = try TalkClient(port: port, credential: record.credential)
    let client = ExampleClient(transport: transport)
    do {
        try await client.connect()
        try Task.checkCancellation()
        return client
    } catch {
        await transport.close()
        throw error
    }
}

// Run in one owned task with the same grant used to connect this client. Even a read-only
// session consumes stream termination to detect remote closure. Only an observe grant
// subscribes or decodes updates. The owner guards accept/end callbacks by session generation
// and marks disconnected on return/error, including normal EOF. Do not add another iterator.
public func runSession(_ client: ExampleClient, grant: PairingRecord,
                       accept: @escaping @Sendable (Snapshot) async -> Void) async throws {
    do {
        guard grant.permits("example.view") else { throw TalkError.permissionDenied }
        try Task.checkCancellation()
        let receivesChanges = grant.permits("example.observe")
        await accept(try await (receivesChanges ? client.subscribe() : client.snapshot()))
        for try await message in client.transport.events {
            try Task.checkCancellation()
            guard receivesChanges else { continue }
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
