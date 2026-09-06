import AppKit
import Darwin

public enum ProviderDiscovery {
    /// Installation hints are never identity. Reject duplicates; a move can
    /// recover after LaunchServices exposes exactly one currently existing URL.
    public static func uniqueInstallation(_ urls: [URL]) throws -> URL {
        let candidates = Set(urls.map(\.standardizedFileURL))
        guard candidates.count <= 1 else { throw TalkError.ambiguousProvider }
        guard let url = candidates.first, FileManager.default.fileExists(atPath: url.path) else { throw TalkError.unavailable }
        return url
    }

    public enum MetadataStatus: String, Sendable { case unavailable, missing, invalid, available }
    public struct Candidate: Identifiable, Sendable {
        public let url: URL
        public let bundleID: String?
        public let name: String
        public let manifest: ProviderManifest?
        public let metadataStatus: MetadataStatus
        public var id: URL { url }
    }

    @MainActor
    public static func installed() -> [Candidate] {
        guard let url = URL(string: "talk-spike-provider://discover") else { return [] }
        return Array(Set(NSWorkspace.shared.urlsForApplications(toOpen: url).map(\.standardizedFileURL)))
            .sorted { $0.path < $1.path }.map { candidate(at: $0) }
    }

    /// Public metadata is an untrusted hint; unreadable candidates remain visible.
    static func candidate(at url: URL, metadata: [String: Any]? = nil,
                          read: (URL) throws -> Data = boundedRead) -> Candidate {
        // Bundle.infoDictionary can itself read an untrusted special file.
        // Use the same descriptor checks for both metadata resources.
        let info = metadata ?? (try? boundedRead(url.appendingPathComponent("Contents/Info.plist", isDirectory: false)))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        var status: MetadataStatus = info == nil ? .unavailable : .missing
        var manifest: ProviderManifest?
        if let path = info?["TalkContract"] as? String {
            if path != "Contract.talk.json" { status = .invalid }
            else {
                let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true).resolvingSymlinksInPath()
                let file = resources.appendingPathComponent(path, isDirectory: false).resolvingSymlinksInPath()
                if file.deletingLastPathComponent().path != resources.path { status = .invalid }
                else {
                    do {
                        let data = try read(file)
                        do { manifest = try ProviderManifest.parse(data); status = .available }
                        catch { status = .invalid }
                    } catch { status = .unavailable }
                }
            }
        }
        return Candidate(url: url, bundleID: info?["CFBundleIdentifier"] as? String,
                         name: info?["CFBundleDisplayName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                         manifest: manifest, metadataStatus: status)
    }

    private static func boundedRead(_ url: URL) throws -> Data {
        // Open without waiting for a FIFO writer, then validate the actual
        // descriptor. A path-only precheck would race replacement. This is a
        // byte/type bound, not a deadline for slow regular-file filesystems.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TalkError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size >= 0, attributes.st_size <= FrameCodec.maximumPayloadBytes else {
            throw TalkError.invalidFrame
        }
        let data = try handle.read(upToCount: FrameCodec.maximumPayloadBytes + 1) ?? Data()
        guard data.count <= FrameCodec.maximumPayloadBytes else { throw TalkError.invalidFrame }
        return data
    }
}
