import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var isChoosingEngineDirectory = false
    @State private var correctionToRemove: DisplayCorrection?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    StatusPill(title: model.engineProbe.isAvailable ? "Ready" : "Unavailable", isReady: model.engineProbe.isAvailable)
                }
                LabeledContent("Version", value: model.engineProbe.version ?? "Not detected")
                LabeledContent("Active directory", value: model.engineProbe.directory?.path(percentEncoded: false) ?? "Bundled engine not detected")
                Text(model.engineStatusSummary).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Technical diagnostic") {
                    Text(model.engineProbe.diagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                HStack {
                    TextField("Optional override directory", text: $model.explicitEnginePath)
                        .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
                    Button("Choose Override…") { isChoosingEngineDirectory = true }
                        .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
                    Button("Clear Override") { model.explicitEnginePath = "" }
                        .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
                }
                Button(model.explicitEnginePath.isEmpty ? "Check Bundled Engine" : "Apply Advanced Override") {
                    Task { await model.saveSettingsAndReloadEngine() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
            } header: {
                Text("Bundled Calibration Engine")
            } footer: {
                Text("ArgyllCMS 3.5.0 is bundled with LumaProfile and selected automatically. Directory selection is an advanced override for development or diagnostics; choose its bin folder, not an individual executable. No administrator access is used.")
            }

            Section("Measurement") {
                Picker("Display technology mode", selection: $model.measurementMode) {
                    ForEach(MeasurementMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
                Label("Calibration leaves the ColorSync association unchanged. Argyll temporarily adjusts the display VideoLUT during measurement, and LumaProfile restores the active profile's calibration afterward. The generated ICC profile is activated only after you explicitly confirm Activate & Verify.", systemImage: "hand.raised.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save Preferences") { Task { await model.saveSettingsAndReloadEngine() } }
                    .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
            }

            Section("Corrections") {
                if model.corrections.isEmpty {
                    Text("No CCSS or CCMX corrections imported.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.corrections) { correction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(correction.name)
                                Text("\(correction.kind.rawValue.uppercased()) · \(correction.provenance)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                correctionToRemove = correction
                            }
                            .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
                        }
                    }
                }
            }

            Section("Privacy & Support") {
                Label("Measurements, profiles, and session logs stay on this Mac. LumaProfile does not upload calibration data.", systemImage: "lock.shield")
                HStack {
                    Button("Reveal Local Data") { Task { await model.revealLocalData() } }
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                }
                Text("Copied diagnostics omit raw measurements and shorten your home-folder path. Review anything you paste into a public issue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(.horizontal, 16)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $isChoosingEngineDirectory, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            model.explicitEnginePath = url.path(percentEncoded: false)
        }
        .confirmationDialog(
            "Remove this display correction?",
            isPresented: Binding(
                get: { correctionToRemove != nil },
                set: { if !$0 { correctionToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let correctionToRemove {
                Button("Remove \(correctionToRemove.name)", role: .destructive) {
                    Task { await model.removeCorrection(correctionToRemove) }
                    self.correctionToRemove = nil
                }
            }
            Button("Cancel", role: .cancel) { correctionToRemove = nil }
        } message: {
            Text("The app-managed CCSS or CCMX copy will be deleted. Past session records keep their provenance, but future runs cannot use it unless you import it again.")
        }
    }
}
