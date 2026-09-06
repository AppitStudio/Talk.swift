import Foundation

/// All mutable state stays private and every access holds the lock. Only values
/// leave this container; no lock is held across an await or a caller callback.
final class TransportDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0
    private var events: [String] = []

    func identifier() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        next &+= 1
        return next
    }

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        if events.count == 256 { events.removeFirst() }
        events.append(event)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
