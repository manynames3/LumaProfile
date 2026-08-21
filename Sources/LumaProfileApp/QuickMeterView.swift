import SwiftUI

struct QuickMeterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Quick Meter").font(.largeTitle.bold())
                    Text("Take a one-shot reading without starting a calibration session.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(
                            title: "Measurement source",
                            subtitle: "Quick Meter uses the display, meter, mode, and correction selected on the Calibrate page.",
                            symbol: "sensor.tag.radiowaves.forward"
                        )
                        Divider()
                        LabeledContent("Display", value: model.confirmedDisplay?.name ?? "Mapping not confirmed")
                        LabeledContent("Meter", value: model.selectedInstrument?.model ?? "Not detected")
                        LabeledContent("Correction", value: model.selectedCorrection?.name ?? "Meter default")
                        LabeledContent("Measurement mode", value: model.measurementMode.rawValue)
                        Text("Remove or rotate the ambient diffuser, then hang the i1Display flat against the selected screen before taking a reading.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Measure") { Task { await model.captureQuickMeasurement() } }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || model.confirmedDisplay == nil || model.selectedInstrument == nil || !model.engineProbe.isAvailable)
                            if model.isMeasuring {
                                ProgressView().controlSize(.small)
                                Button("Cancel", role: .cancel) { Task { await model.cancelMeasurement() } }
                            }
                            Spacer()
                            Button("Review Setup") { model.destination = .calibrate }
                        }
                    }.padding(8)
                }

                if let measurement = model.quickMeasurement {
                    GroupBox("Latest reading") {
                        VStack(alignment: .leading, spacing: 12) {
                            MeasurementCard(measurement: measurement)
                            ForEach(measurement.warnings, id: \.self) {
                                Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }.padding(8)
                    }
                } else if !model.engineProbe.isAvailable {
                    EmptyHardwareView(
                        title: "Calibration engine unavailable",
                        description: model.engineProbe.diagnostic,
                        symbol: "wrench.and.screwdriver",
                        refresh: { Task { await model.load() } }
                    ).frame(height: 260)
                } else if model.selectedInstrument == nil {
                    EmptyHardwareView(
                        title: "No supported meter detected",
                        description: "Connect an i1Display Pro / Plus, then refresh.",
                        symbol: "sensor",
                        refresh: { Task { await model.refreshInstruments() } }
                    ).frame(height: 260)
                }
            }
            .padding(28).frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("Quick Meter")
    }
}
