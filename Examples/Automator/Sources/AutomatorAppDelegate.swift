import AppKit
import Talk

@MainActor
final class AutomatorAppDelegate: NSObject, NSApplicationDelegate {
    let model = AutomatorModel()
    private var startup: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        startup = Task { await model.start() }
    }
    func applicationWillTerminate(_ notification: Notification) { startup?.cancel() }
    func application(_ application: NSApplication, open urls: [URL]) { for url in urls.prefix(4) { model.handleURL(url) } }
}
