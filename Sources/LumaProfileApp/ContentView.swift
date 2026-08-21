import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppDestination.allCases, selection: $model.destination) { destination in
                Label(destination.rawValue, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle("LumaProfile")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Divider()
                    StatusPill(
                        title: model.engineProbe.isAvailable ? "Engine ready" : "Engine unavailable",
                        isReady: model.engineProbe.isAvailable
                    )
                    Text(model.engineStatusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch model.destination ?? .calibrate {
                case .calibrate: CalibrationView(model: model)
                case .meter: QuickMeterView(model: model)
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                case .about: AboutView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label("Refresh hardware", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing || model.isRefreshingInstruments || model.hasActiveOperation)
                }
            }
        }
        .task { await model.load() }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
}
