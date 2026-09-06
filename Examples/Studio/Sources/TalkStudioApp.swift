import SwiftUI

@main
struct TalkStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    var body: some SwiftUI.Scene {
        WindowGroup("Talk Studio", id: "studio") {
            ScrollView { StudioView(model: delegate.model) }
                .frame(minWidth: 580, idealWidth: 660, minHeight: 520, idealHeight: 580)
        }
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
