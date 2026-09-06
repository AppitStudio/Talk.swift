import Foundation
import Testing
@testable import Talk

struct DiscoveryAndCredentialTests {
    @Test func unavailableMetadataPreservesCandidate() {
        let url = URL(fileURLWithPath: "/unavailable/Synthetic Studio.app")
        let candidate = ProviderDiscovery.candidate(at: url)
        #expect(candidate.url == url)
        #expect(candidate.bundleID == nil)
        #expect(candidate.name == "Synthetic Studio")
        #expect(candidate.metadataStatus == .unavailable)
    }

    @Test func deniedManifestAndUnsafePathsAreDistinct() {
        let url = URL(fileURLWithPath: "/unavailable/Synthetic.app")
        let denied = ProviderDiscovery.candidate(at: url, metadata: ["TalkContract": "Contract.talk.json"]) { _ in throw CocoaError(.fileReadNoPermission) }
        #expect(denied.metadataStatus == .unavailable)
        let unsafe = ProviderDiscovery.candidate(at: url, metadata: ["TalkContract": "../private.json"]) { _ in
            Issue.record("Unsafe resource path was read"); return Data()
        }
        #expect(unsafe.metadataStatus == .invalid)
        let malformed = ProviderDiscovery.candidate(at: url, metadata: ["TalkContract": "Contract.talk.json"]) { _ in Data("{}".utf8) }
        #expect(malformed.metadataStatus == .invalid)
    }

    @Test(.timeLimit(.minutes(1)))
    func timedOutKeychainOperationCannotBeDuplicated() async throws {
        let operations = KeychainOperations()
        // A synthetic blocking system call; no real credentials or Keychain changes.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        await #expect(throws: TalkError.credentialOperationPending) {
            try await operations.perform(key: "synthetic", timeout: 0.02) { gate.wait(); return nil }
        }
        await #expect(throws: TalkError.credentialOperationPending) {
            try await operations.perform(key: "synthetic") { Issue.record("Unresolved operation retried"); return nil }
        }
    }
}
