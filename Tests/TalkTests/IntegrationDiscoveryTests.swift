import Foundation
import Testing
@testable import Talk

struct IntegrationDiscoveryTests {
    let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let installed = URL(fileURLWithPath: "/Applications/Provider.app")
    let archived = URL(fileURLWithPath: "/tmp/ArchivedProvider.app")

    @Test func runningCopyWinsWithoutDeletingArchives() throws {
        #expect(try IntegrationDiscovery.select(installed: [installed, archived], running: [archived], canonicalDirectories: [root]) == archived)
    }
    @Test func canonicalInstallationWinsOverDormantArchives() throws {
        #expect(try IntegrationDiscovery.select(installed: [installed, archived], running: [], canonicalDirectories: [root]) == installed)
    }
    @Test func multipleRunningOrCanonicalCopiesRemainAmbiguous() {
        #expect(throws: TalkError.ambiguousProvider) {
            try IntegrationDiscovery.select(installed: [installed], running: [installed, installed], canonicalDirectories: [root])
        }
        #expect(throws: TalkError.ambiguousProvider) {
            try IntegrationDiscovery.select(installed: [installed, root.appendingPathComponent("Second.app")], running: [], canonicalDirectories: [root])
        }
        #expect(throws: TalkError.unavailable) {
            try IntegrationDiscovery.select(installed: [installed], running: [nil], canonicalDirectories: [root])
        }
    }

    // `resolveInstallation` is nonisolated: this test body is not on the main actor,
    // and it must reach the same answer as the main-actor check.
    @Test func backgroundCheckMatchesMainActorCheck() async {
        let identities = [
            AppIdentity(bundleID: "com.example.talk.not-installed-\(UUID().uuidString.prefix(8))", teamID: "ABCDE12345"),
            AppIdentity(bundleID: "com.apple.Safari", teamID: "ABCDE12345")
        ]
        for identity in identities {
            for role in [IntegrationDiscovery.Role.provider, .consumer] {
                let background = await IntegrationDiscovery.resolveInstallation(for: identity, role: role)
                let main = await MainActor.run { IntegrationDiscovery.installation(for: identity, role: role) }
                #expect(background.availability == main.availability)
                #expect(background.applicationURL == main.applicationURL)
            }
        }
        let missing = await IntegrationDiscovery.resolveInstallation(for: identities[0])
        #expect(missing.availability == .notInstalled)
        #expect(missing.applicationURL == nil)
    }

    @Test func backgroundCheckDoesNotWaitForTheMainActor() async throws {
        // The main actor stays busy until the background check reports back: a check
        // that needed the main actor could not finish first.
        let identity = AppIdentity(bundleID: "com.example.talk.not-installed", teamID: "ABCDE12345")
        let finished = Atomic(false)
        let check = Task.detached { () -> IntegrationDiscovery.Availability in
            let result = await IntegrationDiscovery.resolveInstallation(for: identity)
            finished.set(true)
            return result.availability
        }
        let finishedWhileMainBusy = await MainActor.run { () -> Bool in
            let deadline = Date().addingTimeInterval(10)
            while !finished.get() && Date() < deadline { usleep(1_000) }
            return finished.get()
        }
        #expect(finishedWhileMainBusy)
        #expect(await check.value == .notInstalled)
    }
}

private final class Atomic<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}
