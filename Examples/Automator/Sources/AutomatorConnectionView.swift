import SwiftUI

struct AutomatorConnectionView: View {
    @ObservedObject var model: AutomatorModel
    var body: some View {
        GroupBox("Studio connections") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(model.providers.count) local provider(s) discovered")
                    Spacer()
                    Button("Refresh", action: model.refreshProviders)
                    Button("Reload saved grants", action: model.reload)
                }
                if model.paired {
                    ScrollView {
                        ForEach(model.sessions) { session in AutomatorSessionView(session: session, model: model) }
                    }.frame(height: 190)
                }
                SecureField("Paste Studio’s pairing code", text: $model.pairingCode).textFieldStyle(.roundedBorder)
                Button("Pair with Studio", action: model.pair).disabled(model.pairingCode.isEmpty)
            }.padding(12)
        }.disabled(model.busy)
    }
}
