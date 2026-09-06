import SwiftUI

@main
struct TalkStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    var body: some SwiftUI.Scene {
        Window("Talk Studio", id: "studio") { StudioView(model: delegate.model) }
            .defaultSize(width: 660, height: 580)
    }
}
