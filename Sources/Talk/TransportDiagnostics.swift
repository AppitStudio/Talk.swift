import Foundation
import Network

/// Opt-in local validation only. Stores no endpoints, credentials, request data,
/// UUIDs or peer identities; the ring holds at most 256 fixed-shape events.
@_spi(Validation) public enum TransportDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["TALK_TRANSPORT_DIAGNOSTICS"] == "1"
    private static let buffer = TransportDiagnosticBuffer()

    static func identifier() -> UInt64 {
        guard enabled else { return 0 }
        return buffer.identifier()
    }
    static func record(_ event: @autoclosure () -> String) {
        guard enabled else { return }
        let value = event()
        buffer.record(value)
    }
    static func error(_ error: NWError) -> String {
        switch error {
        case .posix(let code): "posix:\(code.rawValue)"
        case .dns(let code): "dns:\(code)"
        case .tls(let code): "tls:\(code)"
        case .wifiAware(let code): "wifiAware:\(code)"
        @unknown default: "unknown"
        }
    }
    public static func snapshot() -> [String] { buffer.snapshot() }
}
