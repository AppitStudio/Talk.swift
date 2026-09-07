import AppKit

/// Public endpoint hints only. A valid nonce correlates a callback; it does not
/// authenticate its sender. The paired TLS credential authenticates the socket.
@MainActor
public final class EndpointResolver {
    private var pending: [UUID: AsyncThrowingStream<UInt16, any Error>.Continuation] = [:]
    public init() {}

    public func resolve(record: PairingRecord, applicationURL: URL, callbackBundleID: String) async throws -> UInt16 {
        guard pending.count < 4 else { throw TalkError.busy }
        let requestID = UUID()
        var components = URLComponents()
        components.scheme = "talk-spike-provider"
        components.host = "connect"
        components.queryItems = [URLQueryItem(name: "request", value: requestID.uuidString),
                                 URLQueryItem(name: "pairing", value: record.credential.id.uuidString),
                                 URLQueryItem(name: "callback", value: callbackBundleID)]
        guard let url = components.url else { throw TalkError.unavailable }
        let (ports, continuation) = AsyncThrowingStream<UInt16, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pending[requestID] = continuation
        defer { pending.removeValue(forKey: requestID)?.finish() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        // Launch completion is not service readiness. The matching callback is.
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if error != nil { continuation.finish(throwing: TalkError.unavailable) }
        }
        return try await withDeadline(seconds: 15) {
            for try await port in ports { return port }
            throw CancellationError()
        }
    }

    public func receive(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "talk-spike-consumer", components.host == "endpoint",
              let items = components.queryItems, items.count == 2,
              let rawID = items.first(where: { $0.name == "request" })?.value,
              let id = UUID(uuidString: rawID),
              let rawPort = items.first(where: { $0.name == "port" })?.value,
              let port = UInt16(rawPort), port > 0 else { return }
        if let continuation = pending.removeValue(forKey: id) {
            continuation.yield(port)
            continuation.finish()
        }
    }

    /// Replies with a public port hint for an existing grant. The default can
    /// route to any valid, uniquely running callback app; an optional allowlist
    /// restricts routing. Possession of the saved TLS key still gates access.
    public static func reply(to url: URL, pairingID: UUID, port: UInt16, allowedCallbackBundleIDs: Set<String>? = nil) {
        guard let reply = response(to: url, pairingID: pairingID, port: port, allowedCallbackBundleIDs: allowedCallbackBundleIDs),
              let applicationURL = uniqueRunningCallback(
                NSRunningApplication.runningApplications(withBundleIdentifier: reply.callback).map(\.bundleURL)) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open([reply.url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if let error {
                // Opt-in, bounded diagnostics; never include URLs or error text.
                TransportDiagnostics.record("callback open-failed code=\((error as NSError).code)")
            }
        }
    }

    static func response(to url: URL, pairingID: UUID, port: UInt16,
                         allowedCallbackBundleIDs: Set<String>? = nil) -> (url: URL, callback: String)? {
        guard port > 0,
              let fields = PairingRouting.fields(url, scheme: "talk-spike-provider", host: "connect",
                                                 names: ["pairing", "request", "callback"]),
              fields["pairing"] == pairingID.uuidString,
              let request = fields["request"], UUID(uuidString: request) != nil,
              let callback = fields["callback"],
              PairingRouting.allowsCallback(callback, allowlist: allowedCallbackBundleIDs) else { return nil }
        return (PairingRouting.url(scheme: "talk-spike-consumer", host: "endpoint",
                                  fields: ["request": request, "port": String(port)]), callback)
    }

    /// Count processes, not paths: two running copies at one URL are still
    /// ambiguous. Endpoint hints must not be sent to an arbitrary first match.
    static func uniqueRunningCallback(_ applications: [URL?]) -> URL? {
        guard applications.count == 1 else { return nil }
        return applications[0]
    }
}
