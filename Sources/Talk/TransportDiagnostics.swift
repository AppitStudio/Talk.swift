import Foundation
import Network
import os

/// Opt-in local validation only. Stores no endpoints, credentials, request data,
/// UUIDs or peer identities; the ring holds at most 256 fixed-shape events.
@_spi(Validation) public enum TransportDiagnostics {
    private struct State {
        var next: UInt64 = 0
        var events: [String] = []
    }
    private static let enabled = ProcessInfo.processInfo.environment["TALK_TRANSPORT_DIAGNOSTICS"] == "1"
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func identifier() -> UInt64 {
        guard enabled else { return 0 }
        return state.withLock { $0.next &+= 1; return $0.next }
    }
    static func record(_ event: @autoclosure () -> String) {
        guard enabled else { return }
        let value = event()
        state.withLock {
            if $0.events.count == 256 { $0.events.removeFirst() }
            $0.events.append(value)
        }
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
    public static func snapshot() -> [String] { state.withLock { $0.events } }
}
