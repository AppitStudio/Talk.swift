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
}
