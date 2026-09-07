import AppKit

/// Public routing hints only. This channel does not establish peer identity.
enum PairingRouting {
    typealias Sender = @MainActor (URL, URL) -> Void
    typealias Callback = @MainActor (String) -> URL?

    static func url(scheme: String, host: String, fields: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Callers use fixed valid schemes/hosts and bounded strings.
        return components.url!
    }

    static func fields(_ url: URL, scheme: String, host: String, names: Set<String>) -> [String: String]? {
        guard url.absoluteString.utf8.count <= 2048,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == scheme, c.host == host, c.user == nil, c.password == nil, c.port == nil,
              c.path.isEmpty, c.fragment == nil, let items = c.queryItems, items.count == names.count,
              Set(items.map(\.name)) == names,
              items.allSatisfy({ $0.value != nil && ($0.value?.utf8.count ?? 0) <= 512 }) else { return nil }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
    }

    static func validBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }
    }

    @MainActor static func callback(_ bundleID: String) -> URL? {
        EndpointResolver.uniqueRunningCallback(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.bundleURL))
    }

    @MainActor static func send(_ url: URL, to application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        // The matching callback, bounded by the caller's deadline, is readiness.
        // Do not log URLs or OS error descriptions.
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, _ in }
    }
}
