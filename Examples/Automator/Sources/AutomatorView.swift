import SwiftUI

struct AutomatorView: View {
    @ObservedObject var model: AutomatorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Talk Automator", systemImage: "bolt.horizontal.circle.fill").font(.largeTitle.bold())
            Text("Start a focus session. Let Studio follow along.").font(.title3).foregroundStyle(.secondary)
            AutomatorConnectionView(model: model)
            GroupBox("Your automation") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Automatically update Studio when my focus session changes", isOn: $model.automationEnabled)
                    Text("Session starts → Focus scene\nSession ends → Available scene")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(model.focusActive ? "End focus session" : "Start focus session", action: model.toggleFocus)
                            .buttonStyle(.borderedProminent).disabled(model.busy || model.paired == false)
                        Spacer()

                    }
                }.padding(12)
            }
            Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
            if model.log.isEmpty == false {
                GroupBox("Recent activity") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in Text(line).font(.callout) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(height: 110)
                }
            }
            Text("Automations run while this app is open. No cloud or background daemon.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 620, minHeight: 540)
    }
}
