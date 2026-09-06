import SwiftUI

struct StudioIntegrationView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        GroupBox("Integrations") {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    ForEach(Array(model.integrations.enumerated()), id: \.element.id) { index, integration in
                        VStack(alignment: .leading) {
                            Text("\(integration.label ?? "Connection \(index + 1)") · \(integration.state.rawValue)").font(.headline)
                            Text(integration.scopes.sorted().joined(separator: ", ")).font(.caption)
                            HStack {
                                Button("Replace permissions") { model.createInvitation(replacing: integration.id) }
                                Button("Revoke access", role: .destructive) { model.revoke(integration.id) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                    }
                }.frame(height: model.paired ? 140 : 0)
                TextField("Connection label (not verified identity)", text: $model.integrationName).textFieldStyle(.roundedBorder)
                Text("New / replacement permission: Read scenes is included.").font(.caption)
                Toggle("Allow scene selection", isOn: $model.allowSelection)
                Toggle("Allow observing changes", isOn: $model.allowObservation)
                HStack {
                    Button("Create pairing code", action: model.createInvitation)
                    if !model.invitation.isEmpty { Button("Copy pairing code", action: model.copyInvitation) }
                    Button("Reload saved grants", action: model.reloadIntegrations)
                }
                if !model.invitation.isEmpty { Text("Code ready · Expires in five minutes").font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.disabled(model.busy || model.approvalPending)
    }
}
