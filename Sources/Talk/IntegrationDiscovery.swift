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
    ///
    /// This blocks the main actor while it reads LaunchServices and validates the
    /// selected copy's whole code signature: tens of milliseconds per app, more
    /// on a cold disk. Panels and other UI should use
    /// ``resolveInstallation(for:role:)`` instead.
    @MainActor
    public static func installation(for identity: AppIdentity, role: Role = .provider) -> Installation {
        inspectInstallation(for: identity, role: role)
    }

    /// The same passive check as ``installation(for:role:)``, run off the main
    /// actor so a panel can draw (with a "Checking…" placeholder) while it runs.
    /// It never launches the app, requests consent, or grants access. Apply the
    /// result on the main actor; a later result supersedes an earlier one, so
    /// ignore results from checks that were started before the newest one.
    public static func resolveInstallation(for identity: AppIdentity, role: Role = .provider) async -> Installation {
        await Task.detached(priority: .userInitiated) {
            inspectInstallation(for: identity, role: role)
        }.value
    }

    /// Thread-safe: LaunchServices and bundle reads, the bundle-ID-scoped
    /// running-application query (never the workspace-wide list), and a static
    /// code-signature check.
    nonisolated static func inspectInstallation(for identity: AppIdentity, role: Role) -> Installation {
        let scheme = role == .provider ? "talk-spike-provider" : "talk-spike-consumer"
        let candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identity.bundleID).filter {
            FileManager.default.fileExists(atPath: $0.path)
                && Bundle(url: $0)?.bundleIdentifier == identity.bundleID
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleID)
        let url: URL
        do {
            url = try select(installed: candidates, running: running.map(\.bundleURL), canonicalDirectories: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            ])
        } catch TalkError.ambiguousProvider {
            return Installation(availability: .ambiguousInstallation, applicationURL: nil)
        } catch {
            return Installation(availability: .notInstalled, applicationURL: nil)
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

    /// A running app is the user's selected copy. Otherwise prefer one normal
    /// installation over dormant build/archive copies. Never choose between two
    /// running or two canonical installations, and never fall back after a
    /// selected copy fails signature/version validation.
    static func select(installed: [URL], running: [URL?], canonicalDirectories: [URL]) throws -> URL {
        func normalize(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
        guard running.count <= 1 else { throw TalkError.ambiguousProvider }
        if running.count == 1 {
            guard let url = running[0] else { throw TalkError.unavailable }
            return normalize(url)
        }
        let urls = Set(installed.map(normalize))
        let roots = Set(canonicalDirectories.map(normalize))
        let canonical = urls.filter { roots.contains($0.deletingLastPathComponent()) }
        if canonical.count > 1 { throw TalkError.ambiguousProvider }
        if let url = canonical.first { return url }
        guard urls.count <= 1 else { throw TalkError.ambiguousProvider }
        guard let url = urls.first else { throw TalkError.unavailable }
        return url
    }
}
