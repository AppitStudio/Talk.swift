import SwiftUI

struct StudioConsentView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Allow this integration?", systemImage: "link.badge.plus").font(.title2.bold())
            Text("Approve only if you just pasted Studio’s code into the app you intend to connect.")
            Text("The paired app will be able to:")
            ForEach(model.consentScopes.sorted(), id: \.self) { scope in
                Label(scope, systemImage: "checkmark.shield")
            }
            Text("Approval is saved until you revoke it. This pairing verifies possession of the code, not the other app’s publisher.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Deny", role: .cancel) { model.decide(false) }
                Spacer()
                Button("Always allow") { model.decide(true) }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 440)
    }
}
