import SwiftUI

struct AutomatorSessionView: View {
    @ObservedObject var session: AutomatorSession
    @ObservedObject var model: AutomatorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.record.label ?? "Studio").font(.headline)
            Text(session.record.providerBundleID).font(.caption)
            Text(session.status).font(.callout)
            Text(session.record.scopes.sorted().joined(separator: ", ")).font(.caption)
            if let snapshot = session.snapshot { Text("Studio: \(snapshot.selectedSceneID.capitalized)") }
            HStack {
                Button(session.connected ? "Disconnect" : "Connect") {
                    if session.connected { model.disconnect(session) } else { model.connect(session) }
                }
                Spacer()
                Button("Forget pairing", role: .destructive) { model.forget(session) }
            }
        }.padding(.vertical, 8).disabled(session.busy)
    }
}
