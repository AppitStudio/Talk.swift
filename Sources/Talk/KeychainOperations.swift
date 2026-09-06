import Foundation

/// Blocking Security calls are isolated from cooperative executors. A timeout
/// does not cancel a system write: keep its slot until it actually finishes.
actor KeychainOperations {
    static let shared = KeychainOperations()
    private var inFlight: Set<String> = []

    func perform(key: String, timeout: Double = 10, operation: @escaping @Sendable () throws -> Data?) async throws -> Data? {
        guard inFlight.count < 4, inFlight.insert(key).inserted else { throw TalkError.credentialOperationPending }
        let (results, continuation) = AsyncThrowingStream<Data?, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try operation() }
            Task {
                await self.finished(key)
                switch result {
                case .success(let value): continuation.yield(value); continuation.finish()
                case .failure(let error): continuation.finish(throwing: error)
                }
            }
        }
        do {
            return try await withDeadline(seconds: timeout) {
                for try await result in results { return result }
                throw CancellationError()
            }
        } catch {
            if (error as? TalkError) == .timedOut || error is CancellationError { throw TalkError.credentialOperationPending }
            throw error
        }
    }

    private func finished(_ key: String) { inFlight.remove(key) }
}
