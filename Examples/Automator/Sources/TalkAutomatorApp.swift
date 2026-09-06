import SwiftUI

@main
struct TalkAutomatorApp: App {
    @NSApplicationDelegateAdaptor(AutomatorAppDelegate.self) private var delegate
    var body: some Scene {
        Window("Talk Automator", id: "automator") { AutomatorView(model: delegate.model) }
            .defaultSize(width: 700, height: 680)
    }
}
