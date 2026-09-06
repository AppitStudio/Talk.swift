import Foundation

@main
struct TimerRetention {
    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "nanoseconds"
        guard mode == "dispatch" || mode == "nanoseconds" else { exit(1) }
        let interval = Double(ProcessInfo.processInfo.environment["TALK_TIMER_SECONDS"] ?? "300") ?? 300
        guard interval >= 1, interval <= 300 else { return }
        for _ in 0..<20000 {
            let (began, begin) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    begin.yield(())
                    do {
                        if mode == "dispatch" { try await DeadlineTimer.sleep(seconds: interval) }
                        else { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                    } catch { }
                }
                for await _ in began { break }
                // Scheduling barrier gives the sleep a chance to install its timer.
                await Task.yield()
                group.cancelAll()
            }
        }
        FileHandle.standardOutput.write(Data("cancelled=20000 mode=\(mode)\n".utf8))
        try? await Task.sleep(nanoseconds: 15_000_000_000)
    }
}
