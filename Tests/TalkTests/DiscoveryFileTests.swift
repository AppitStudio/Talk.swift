import Darwin
import Foundation
import Testing
@testable import Talk

struct DiscoveryFileTests {
    private static let schema = Data(#"{"schemaVersion":1,"contractID":"dev.talk.test","contractVersion":"1.0.0","name":"Synthetic","actions":[{"id":"test.read","symbol":"read","method":"read","scope":"test.read","input":"Void","output":"Bool","mutation":false}],"types":[],"events":[]}"#.utf8)

    @Test(.timeLimit(.minutes(1)), arguments: ["fifo", "directory", "oversize", "outside-link", "missing", "regular"])
    func rejectsUnsafeManifestResources(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TalkDiscovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Synthetic.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let manifest = resources.appendingPathComponent("Contract.talk.json")
        switch kind {
        case "fifo": try #require(mkfifo(manifest.path, 0o600) == 0)
        case "directory": try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        case "oversize": try Data(repeating: 32, count: FrameCodec.maximumPayloadBytes + 1).write(to: manifest)
        case "outside-link":
            let outside = root.appendingPathComponent("outside.json")
            try Self.schema.write(to: outside)
            try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        case "regular": try Self.schema.write(to: manifest)
        default: break
        }
        let candidate = ProviderDiscovery.candidate(at: app, metadata: ["TalkContract": "Contract.talk.json"])
        #expect(candidate.url == app)
        #expect(candidate.metadataStatus == (kind == "outside-link" ? .invalid : kind == "regular" ? .available : .unavailable))
    }

    @Test(arguments: [false, true])
    func realBundleMetadataRemainsAvailable(binary: Bool) throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("TalkDiscovery-" + UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let metadata = ["CFBundleIdentifier": "dev.talk.synthetic.discovery", "CFBundleDisplayName": "Synthetic Studio", "TalkContract": "Contract.talk.json"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: binary ? .binary : .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Self.schema.write(to: resources.appendingPathComponent("Contract.talk.json"))
        let candidate = ProviderDiscovery.candidate(at: app)
        #expect(candidate.bundleID == "dev.talk.synthetic.discovery")
        #expect(candidate.name == "Synthetic Studio")
        #expect(candidate.metadataStatus == .available)
        #expect(candidate.manifest?.contractID == "dev.talk.test")
    }

    @Test(.timeLimit(.minutes(1)))
    func specialInfoPlistRemainsVisibleWithoutOpeningBundleMetadata() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("TalkDiscovery-" + UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try #require(mkfifo(app.appendingPathComponent("Contents/Info.plist").path, 0o600) == 0)
        let candidate = ProviderDiscovery.candidate(at: app)
        #expect(candidate.url == app)
        #expect(candidate.metadataStatus == .unavailable)
        #expect(candidate.bundleID == nil)
    }

    @Test @MainActor
    func callbackRequiresExactlyOneRunningProcess() {
        let first = URL(fileURLWithPath: "/synthetic/First.app")
        let second = URL(fileURLWithPath: "/synthetic/Second.app")
        #expect(EndpointResolver.uniqueRunningCallback([]) == nil)
        #expect(EndpointResolver.uniqueRunningCallback([nil]) == nil)
        #expect(EndpointResolver.uniqueRunningCallback([first]) == first)
        #expect(EndpointResolver.uniqueRunningCallback([first, second]) == nil)
        #expect(EndpointResolver.uniqueRunningCallback([first, first]) == nil)
        #expect(EndpointResolver.uniqueRunningCallback([first, nil]) == nil)
    }
}
