import SwiftUI

@main
struct TalkAutomatorApp: App {
    @NSApplicationDelegateAdaptor(AutomatorAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Talk Automator", id: "automator") {
            AutomatorView(model: delegate.model)
                .frame(idealWidth: 700, idealHeight: 680)
        }
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
