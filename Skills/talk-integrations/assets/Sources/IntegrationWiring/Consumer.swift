import AppKit
import IntegrationContract
import Talk

// The app must own/serialize pairing, connection and event tasks; these are primitives.
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

// Run in an owned task only for grants with example.observe. Cancelling this flow closes
// its transport; the owner marks the session disconnected on return, including normal EOF.
public func observe(_ client: ExampleClient,
                    accept: @escaping @Sendable (Snapshot) async -> Void) async throws {
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
