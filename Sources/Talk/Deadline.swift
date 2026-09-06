import Foundation

func withDeadline<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds.isFinite, seconds > 0, seconds <= 86_400 else { throw TalkError.invalidMessage }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await DeadlineTimer.sleep(seconds: seconds)
            throw TalkError.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw CancellationError() }
        return value
    }
}
