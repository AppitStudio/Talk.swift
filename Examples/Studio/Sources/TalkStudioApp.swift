import SwiftUI

@main
struct TalkStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    var body: some SwiftUI.Scene {
        WindowGroup("Talk Studio", id: "studio") {
            StudioView(model: delegate.model)
                .frame(idealWidth: 660, idealHeight: 580)
        }
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
