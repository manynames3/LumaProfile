import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppDestination.allCases, selection: $model.destination) { destination in
                Label(destination.rawValue, systemImage: destination.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 3)
                    .tag(destination)
            }
            .navigationTitle("LumaProfile")
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LumaProfile")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                    Text("Display calibration").lumaEyebrow()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(
                        title: model.engineProbe.isAvailable ? "Ready" : "Not ready",
                        isReady: model.engineProbe.isAvailable
                    )
                    Text(model.engineStatusSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 228)
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
            .buttonStyle(.lumaSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Luma.canvas)
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
        .preferredColorScheme(.dark)
        .task {
            model.startBlackScreenWatchdog()
            await model.load()
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
}
