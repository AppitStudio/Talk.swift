import SwiftUI
import StudioContract

struct StudioView: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Talk Studio", systemImage: "square.stack.3d.up.fill")
                .font(.largeTitle.bold())
            Text("Your scenes. Connected to your automations.")
                .font(.title3).foregroundStyle(.secondary)
            GroupBox("Current scene") {
                HStack(spacing: 12) {
                    ForEach(Scene.examples) { scene in
                        Button { model.selectScene(scene.id) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: scene.symbol).font(.title)
                                Text(scene.name)
                                if model.snapshot.selectedSceneID == scene.id { Text("Selected").font(.caption.bold()) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 92)
                        }
                        .accessibilityLabel("Select \(scene.name) scene")
                        .disabled(model.busy)
                    }
                }.padding(12)
            }
            StudioIntegrationView(model: model)
            Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Label("Local example · No cloud", systemImage: "lock.shield")
                Spacer()
                Text("\(model.calls) authorized calls")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(minWidth: 580, minHeight: 520)
        .sheet(isPresented: Binding(get: { model.approvalPending }, set: { if $0 == false { model.decide(false) } })) {
            StudioConsentView(model: model)
        }
    }
}
