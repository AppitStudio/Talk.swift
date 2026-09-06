// Disposable AppKit processes; exercise the actual EndpointResolver.reply method.
// No pairing credentials, Keychain access or production example identities.
import AppKit

@MainActor
private final class RoutingDelegate: NSObject, NSApplicationDelegate {
    private var task: Task<Void, Never>?
    private var received = 0
    private var invalid = 0
    private let callbackID: String
    private let pairingID = UUID()
    private let reader = DispatchQueue(label: "talk.validation.routing.control")

    init(callbackID: String) { self.callbackID = callbackID }

    func applicationDidFinishLaunching(_ notification: Notification) {
        write(["ready": true])
        task = Task {
            do {
                while !Task.isCancelled {
                    let operation = try await read()
                    switch operation {
                    case "state": write(["received": received, "invalid": invalid])
                    case "running":
                        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: callbackID)
                        write(["running": apps.count, "knownURLs": apps.allSatisfy { $0.bundleURL != nil },
                               "samePath": Set(apps.compactMap(\.bundleURL)).count == 1])
                    case "diagnostics": write(["events": TransportDiagnostics.snapshot()])
                    case "reply":
                        var request = URLComponents()
                        request.scheme = "talk-spike-provider"
                        request.host = "connect"
                        request.queryItems = [URLQueryItem(name: "pairing", value: pairingID.uuidString),
                                              URLQueryItem(name: "request", value: UUID().uuidString),
                                              URLQueryItem(name: "callback", value: callbackID)]
                        guard let url = request.url else { throw TalkError.invalidMessage }
                        EndpointResolver.reply(to: url, pairingID: pairingID, port: 9,
                                               allowedCallbackBundleIDs: [callbackID])
                        write(["attempted": true])
                    case "stop":
                        write(["stopped": true])
                        NSApplication.shared.terminate(nil)
                        return
                    default: throw TalkError.invalidMessage
                    }
                }
            } catch {
                write(["failed": true])
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls.prefix(4) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "talk-spike-consumer", components.host == "endpoint",
                  let items = components.queryItems, items.count == 2,
                  let request = items.first(where: { $0.name == "request" })?.value,
                  UUID(uuidString: request) != nil,
                  items.first(where: { $0.name == "port" })?.value == "9" else { invalid += 1; continue }
            received += 1
        }
    }

    func applicationWillTerminate(_ notification: Notification) { task?.cancel() }

    private func write(_ result: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        data.append(10)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func read() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            reader.async {
                do {
                    var data = Data()
                    while data.count < 64 {
                        guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else { throw TalkError.disconnected }
                        if byte == Data([10]), let operation = String(data: data, encoding: .utf8) {
                            continuation.resume(returning: operation)
                            return
                        }
                        data.append(byte)
                    }
                    throw TalkError.invalidMessage
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@main
private enum CallbackRouting {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "inventory" {
            let identity = CommandLine.arguments[2]
            let result = ["registered": NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identity).count,
                          "running": NSRunningApplication.runningApplications(withBundleIdentifier: identity).count]
            if let data = try? JSONSerialization.data(withJSONObject: result), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        guard CommandLine.arguments.count == 2 else { exit(1) }
        let app = NSApplication.shared
        let delegate = RoutingDelegate(callbackID: CommandLine.arguments[1])
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        withExtendedLifetime(delegate) { app.run() }
    }
}
