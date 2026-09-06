import AppKit
// Prints only installation hints for the four synthetic example identities.
for bundle in ["dev.talk.examples.paired.studio", "dev.talk.examples.paired.automator", "dev.talk.examples.paired.studio.sandbox", "dev.talk.examples.paired.automator.sandbox"] {
    let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundle)
    print(bundle)
    for url in urls.sorted(by: { $0.path < $1.path }) {
        let parts = url.path.components(separatedBy: "/LocalBuild/")
        print("  " + (parts.count == 2 ? "LocalBuild/" + parts[1] : "outside-validation-root"))
    }
}
