import SwiftUI

@main
struct TalkAutomatorApp: App {
    @NSApplicationDelegateAdaptor(AutomatorAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Talk Automator", id: "automator") {
            ScrollView { AutomatorView(model: delegate.model) }
                .frame(minWidth: 620, idealWidth: 700, minHeight: 540, idealHeight: 680)
        }
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
