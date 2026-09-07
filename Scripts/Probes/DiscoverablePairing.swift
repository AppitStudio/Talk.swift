// Disposable AppKit validation. Anonymous pipes are control only; no credentials
// leave the process except over the SDK's pairing TLS connection.
import AppKit
import Talk

@MainActor
private final class PairingDelegate: NSObject, NSApplicationDelegate {
    let peerID: String
    let peerURL: URL
    let host = DiscoverablePairingHost()
    let discovery = PairingDiscovery()
    var candidate: PairingDiscovery.Candidate?
    var pairTask: Task<Void, Never>?
    var control: Task<Void, Never>?
    var decision: AsyncStream<Bool>.Continuation?
    var verification: String?
    var result = "idle"
    var approvals = 0
    let reader = DispatchQueue(label: "talk.validation.pairing.control")

    init(peerID: String, peerURL: URL) { self.peerID = peerID; self.peerURL = peerURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        write(["ready": true])
        control = Task {
            do {
                while !Task.isCancelled {
                    let command = try await read()
                    switch command {
                    case "start":
                        await host.stop()
                        result = "waiting"; verification = nil
                        try host.start(providerBundleID: Bundle.main.bundleIdentifier!, allowedCallbackBundleIDs: [peerID]) { [weak self] request in
                            guard let self else { throw TalkError.unavailable }
                            return try await self.approve(request)
                        }
                        write(["started": true])
                    case "discover":
                        do {
                            candidate = try await discovery.discover(applicationURL: peerURL, providerBundleID: peerID,
                                                                       callbackBundleID: Bundle.main.bundleIdentifier!)
                            write(["discovered": true])
                        } catch { write(["discovered": false, "error": (error as? TalkError)?.rawValue ?? "other"]) }
                    case "connect":
                        guard let candidate else { throw TalkError.invalidMessage }
                        result = "connecting"
                        pairTask = Task {
                            do {
                                let record = try await discovery.connect(to: candidate, callbackBundleID: Bundle.main.bundleIdentifier!) { verification = $0 }
                                result = record.scopes == ["read"] && record.providerBundleID == peerID ? "paired" : "invalid"
                            } catch { result = (error as? TalkError)?.rawValue ?? "cancelled" }
                        }
                        write(["connecting": true])
                    case "allow", "deny":
                        decision?.yield(command == "allow"); decision?.finish(); decision = nil
                        write(["decided": true])
                    case "cancel":
                        pairTask?.cancel()
                        await host.stop()
                        write(["cancelled": true])
                    case "state":
                        write(["result": result, "code": verification ?? "", "pending": decision != nil,
                               "discoverable": host.isDiscoverable, "approvals": approvals])
                    case "stop":
                        pairTask?.cancel()
                        await host.stop()
                        write(["stopped": true])
                        NSApp.terminate(nil)
                        return
                    default: throw TalkError.invalidMessage
                    }
                }
            } catch {
                write(["failed": true])
                NSApp.terminate(nil)
            }
        }
    }

    func approve(_ request: DiscoverablePairingHost.Request) async throws -> PairingRecord {
        verification = request.verificationCode
        approvals += 1
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        decision = continuation
        defer { decision = nil }
        let allowed = await withTaskCancellationHandler {
            for await value in stream { return value }
            return false
        } onCancel: { continuation.finish() }
        try Task.checkCancellation()
        guard allowed else { throw TalkError.permissionDenied }
        return PairingRecord(credential: try PairingCredential(), providerBundleID: Bundle.main.bundleIdentifier!, scopes: ["read"])
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls.prefix(4) { host.receive(url); discovery.receive(url) }
    }
    func applicationWillTerminate(_ notification: Notification) { control?.cancel(); pairTask?.cancel() }
    func write(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(10)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
    func read() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            reader.async {
                do {
                    var bytes = Data()
                    while bytes.count < 64 {
                        guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else { throw TalkError.disconnected }
                        if byte == Data([10]), let command = String(data: bytes, encoding: .utf8) {
                            continuation.resume(returning: command); return
                        }
                        bytes.append(byte)
                    }
                    throw TalkError.invalidMessage
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@main private enum DiscoverablePairingProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { exit(1) }
        let app = NSApplication.shared
        let delegate = PairingDelegate(peerID: CommandLine.arguments[1], peerURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        withExtendedLifetime(delegate) { app.run() }
    }
}
