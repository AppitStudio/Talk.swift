import AppKit

/// Passive installation discovery for an app's implemented integration library.
/// Opening a library never launches another app, requests consent, or grants access.
public enum IntegrationDiscovery {
    public enum Role: Sendable { case provider, consumer }
    public enum Availability: String, Sendable {
        case available, notInstalled, updateRequired, ambiguousInstallation, unverified
    }
    public struct Installation: Sendable {
        public let availability: Availability
        public let applicationURL: URL?
    }

    /// Call on panel appearance and workspace launch/termination notifications.
    /// Library entries must come from features the host actually implements;
    /// a discovered contract alone does not create a supported integration.
    @MainActor
    public static func installation(for identity: AppIdentity, role: Role = .provider) -> Installation {
        let scheme = role == .provider ? "talk-spike-provider" : "talk-spike-consumer"
        let candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identity.bundleID).filter {
            FileManager.default.fileExists(atPath: $0.path)
                && Bundle(url: $0)?.bundleIdentifier == identity.bundleID
        }
        let urls = Set(candidates.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        guard !urls.isEmpty else { return Installation(availability: .notInstalled, applicationURL: nil) }
        guard urls.count == 1, let url = urls.first else {
            return Installation(availability: .ambiguousInstallation, applicationURL: nil)
        }
        let bundle = Bundle(url: url)
        let types = bundle?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard bundle?.object(forInfoDictionaryKey: "TalkConnectionVersion") as? Int == 1, schemes.contains(scheme) else {
            return Installation(availability: .updateRequired, applicationURL: url)
        }
        do { try AuthenticatedAppRouting.inspect(applicationURL: url, identity: identity) }
        catch { return Installation(availability: .unverified, applicationURL: url) }
        return Installation(availability: .available, applicationURL: url)
    }
}
