import Foundation
import Testing
@testable import Talk

struct DeadlineTimerTests {
    @Test(.timeLimit(.minutes(1)))
    func expirationAndCancelledBeforeInstallation() async throws {
        await #expect(throws: TalkError.timedOut) {
            try await withDeadline(seconds: 0.01) { try await DeadlineTimer.sleep(seconds: 30) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await DeadlineTimer.sleep(seconds: 30)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedCancellationAndExpiryRaceCompleteExactlyOnce() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    for _ in 0..<100 {
                        let timer = Task { try await DeadlineTimer.sleep(seconds: 0.001) }
                        await Task.yield()
                        timer.cancel()
                        do { try await timer.value } catch is CancellationError { }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await withDeadline(seconds: 30) { 42 } == 42)
    }
}
