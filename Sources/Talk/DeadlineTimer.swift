import Foundation

/// A cancelled timeout promptly releases its dispatch timer. On the validated
/// macOS runtime, cancelled Task.sleep calls retained timer allocations until
/// their original deadlines, growing with throughput despite bounded live work.
/// All mutable fields are protected by lock; neither the source nor continuation
/// escapes. Dispatch sources support cancellation from any thread.
final class DeadlineTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var source: (any DispatchSourceTimer)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false

    static func sleep(seconds: Double) async throws {
        guard seconds.isFinite, seconds > 0, seconds <= 86_400 else { throw TalkError.invalidMessage }
        try await DeadlineTimer().wait(seconds: seconds)
    }

    private func wait(seconds: Double) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                self.source = timer
                self.continuation = continuation
                timer.setEventHandler { [weak self] in self?.finish(.success(())) }
                timer.schedule(deadline: .now() + seconds)
                // Resume before exposing the source to cancellation. Cancelling
                // a never-resumed dispatch source would violate its lifecycle.
                timer.resume()
                lock.unlock()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let timer = source
        let waiting = continuation
        source = nil
        continuation = nil
        lock.unlock()
        timer?.cancel()
        waiting?.resume(with: result)
    }
}
