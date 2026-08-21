import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    @State private var isImportingCorrection = false

    var body: some View {
        Group {
            if let session = model.workflowSession {
                WorkflowView(model: model, session: session)
            } else {
                setupView
            }
        }
        .navigationTitle("Display Calibration")
        .fileImporter(
            isPresented: $isImportingCorrection,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.importCorrection(from: url) }
        }
    }

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Create a trusted display profile").font(.largeTitle.bold())
                    Text("Choose the exact display and meter, set a target, adjust the panel, then follow the guided measurement run.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                if !model.engineProbe.isAvailable { engineUnavailableBanner }
                setupStepper
                Group {
                    switch model.setupStep {
                    case .hardware:
                        hardwareSection
                    case .target:
                        targetSection
                    case .prepare:
                        VStack(spacing: 20) {
                            preparationChecklistSection
                            adjustmentSection
                        }
                    case .review:
                        preflightSection
                    }
                }
                .id(model.setupStep)
                setupNavigation
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }

    private var setupStepper: some View {
        HStack(spacing: 0) {
            ForEach(Array(CalibrationSetupStep.allCases.enumerated()), id: \.element) { index, step in
                HStack(spacing: 8) {
                    Image(systemName: step.rawValue < model.setupStep.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle.fill")
                        .foregroundStyle(step.rawValue <= model.setupStep.rawValue ? Color.accentColor : .secondary)
                    Text(step.title)
                        .font(.subheadline.weight(step == model.setupStep ? .semibold : .regular))
                        .foregroundStyle(step.rawValue <= model.setupStep.rawValue ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Step \(step.rawValue + 1), \(step.title)\(step == model.setupStep ? ", current" : "")")
                if index < CalibrationSetupStep.allCases.count - 1 {
                    Divider().frame(width: 24)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var setupNavigation: some View {
        HStack {
            if model.setupStep != .hardware {
                Button("Back") { model.moveToPreviousSetupStep() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            Spacer()
            if model.setupStep != .review {
                Button("Continue") { model.moveToNextSetupStep() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .disabled(!canContinueSetup)
            }
        }
    }

    private var canContinueSetup: Bool {
        switch model.setupStep {
        case .hardware: model.hardwareStepReady
        case .target: true
        case .prepare: model.preparationStepReady
        case .review: false
        }
    }

    private var engineUnavailableBanner: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Calibration engine unavailable").font(.headline)
                    Text(model.engineStatusSummary).foregroundStyle(.secondary)
                    Button("Open Settings") { model.destination = .settings }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hardwareSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Display and meter",
                    subtitle: "Identification and mapping are explicit to prevent measuring the wrong screen.",
                    symbol: "display"
                )
                Divider()
                Picker("macOS display", selection: $model.selectedDisplayID) {
                    Text("Choose a display").tag(String?.none)
                    ForEach(model.displays) { display in
                        Text("\(display.name) · \(display.widthPixels) × \(display.heightPixels)")
                            .tag(Optional(display.id))
                    }
                }
                .onChange(of: model.selectedDisplayID) { _, _ in model.selectedDisplayChanged() }
                .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)

                if model.selectedDisplay != nil {
                    LabeledContent("Measurement screen") {
                        Text(model.displayMappingSummary)
                            .foregroundStyle(model.selectedEngineDisplay == nil ? .orange : .secondary)
                            .lineLimit(2)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Button("Identify This Display", systemImage: "rectangle.inset.filled.and.person.filled") {
                        model.identifySelectedDisplay()
                    }
                    .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || model.selectedDisplay == nil || (Int(model.displayNumber) ?? 0) <= 0)
                    if model.displayIdentified {
                        Label("Identifier shown", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption.weight(.medium))
                    }
                    Spacer()
                }
                Text("A large identifier appears on the screen LumaProfile will measure. Confirm it is the physical display you selected.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("I confirmed this number identifies \(model.selectedDisplay?.name ?? "the selected display")", isOn: $model.displayMappingConfirmed)
                    .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || !model.displayIdentified || model.selectedEngineDisplay == nil)

                Divider()
                Picker("Meter", selection: $model.selectedInstrumentID) {
                    Text("Choose an i1D3 meter").tag(String?.none)
                    ForEach(model.instruments) { instrument in
                        Text(instrument.serialNumber.map { "\(instrument.model) · \($0)" } ?? instrument.model)
                            .tag(Optional(instrument.id))
                    }
                }
                .onChange(of: model.selectedInstrumentID) { _, _ in model.selectedInstrumentChanged() }
                .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
                HStack {
                    Label(
                        model.instruments.isEmpty ? "No supported USB meter detected" : "Meter ready — connection will be rechecked before every run",
                        systemImage: model.instruments.isEmpty ? "cable.connector.slash" : "cable.connector"
                    )
                        .font(.caption).foregroundStyle(model.instruments.isEmpty ? .orange : .secondary)
                    Spacer()
                    Button("Refresh Meters") { Task { await model.refreshInstruments() } }
                        .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || !model.engineProbe.isAvailable)
                }

                DisclosureGroup("Advanced display mapping and correction") {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.engineDisplays.isEmpty {
                            Picker("Detected engine display", selection: $model.displayNumber) {
                                Text("Choose by number and description").tag("")
                                ForEach(model.engineDisplays) { display in
                                    Text("\(display.index) · \(display.description)").tag(String(display.index))
                                }
                            }
                        }
                        TextField("Engine display number", text: $model.displayNumber)
                            .frame(maxWidth: 260)
                        Text("LumaProfile suggests a mapping when it can do so unambiguously. Identification and confirmation remain required; macOS screen order is never assumed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()
                        Picker("Display correction", selection: $model.selectedCorrectionID) {
                            Text("None / meter default").tag(UUID?.none)
                            ForEach(model.corrections) { correction in
                                Text("\(correction.name) (\(correction.kind.rawValue.uppercased()))")
                                    .tag(Optional(correction.id))
                            }
                        }
                        .onChange(of: model.selectedCorrectionID) { _, _ in model.selectedCorrectionChanged() }
                        HStack {
                            Text(model.selectedCorrection?.provenance ?? "Use a correction only when its display technology and meter match.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Import CCSS / CCMX…") { isImportingCorrection = true }
                        }
                        if !model.correctionCompatibilityIssues.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.correctionCompatibilityIssues, id: \.self) { issue in
                                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                Toggle("I verified this correction is appropriate for this display and meter", isOn: $model.correctionCompatibilityConfirmed)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 10)
                }
                .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments)
            }
            .padding(8)
        }
    }

    private var targetSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Calibration target",
                    subtitle: "Choose an intent first; advanced controls remain visible and reviewable.",
                    symbol: "scope"
                )
                Divider()
                Picker("Preset", selection: $model.targetChoice) {
                    ForEach(TargetChoice.allCases) { choice in Text(choice.title).tag(choice) }
                }
                .pickerStyle(.segmented)

                if model.targetChoice == .custom { customTargetEditor }
                else { LabeledContent("Target", value: model.targetSummary) }

                Picker("Measurement effort", selection: $model.calibrationEffort) {
                    ForEach(CalibrationEffort.allCases, id: \.self) { effort in
                        Text("\(effort.rawValue) · \(effort.characterizationPatchCount)")
                            .tag(effort)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Fewer patches · quicker")
                    Spacer()
                    Text("More patches · slower")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                Text(model.calibrationEffort.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The listed count covers characterization patches. Calibration adds its own readings, and verification is a separate optional pass after explicit activation. Time varies by meter mode, display behavior, and prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Advanced profile options") {
                    Picker("ICC profile model", selection: $model.profileModel) {
                        ForEach(ProfileModel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .padding(.top, 8)
                    Text("Shaper + Matrix is the recommended default for predictable macOS display behavior. LUT profiles are an expert option.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = model.currentTarget.displayModeNote {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var customTargetEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Text("White point")
                Picker("", selection: $model.customWhitePoint) {
                    ForEach(CustomWhitePoint.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
            }
            if model.customWhitePoint == .temperature {
                GridRow {
                    Text("Temperature")
                    HStack {
                        Slider(value: $model.customTemperature, in: 4000...10000, step: 50)
                        Text("\(Int(model.customTemperature)) K").monospacedDigit().frame(width: 72)
                    }
                }
            }
            if model.customWhitePoint == .chromaticity {
                GridRow {
                    Text("Chromaticity")
                    HStack {
                        Text("x")
                        TextField("x", value: $model.customChromaticityX, format: .number.precision(.fractionLength(4))).frame(width: 80)
                        Text("y")
                        TextField("y", value: $model.customChromaticityY, format: .number.precision(.fractionLength(4))).frame(width: 80)
                    }
                }
            }
            GridRow {
                Toggle("Luminance", isOn: $model.customLuminanceEnabled)
                HStack {
                    Slider(value: $model.customLuminance, in: 60...300, step: 1).disabled(!model.customLuminanceEnabled)
                    Text("\(Int(model.customLuminance)) cd/m²").monospacedDigit().frame(width: 94)
                }
            }
            GridRow {
                Text("Tone response")
                HStack {
                    Picker("", selection: $model.customTransfer) {
                        ForEach(CustomTransferFunction.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                    if model.customTransfer == .gamma {
                        Stepper(value: $model.customGamma, in: 1.6...2.6, step: 0.1) {
                            Text(String(format: "%.1f", model.customGamma)).monospacedDigit()
                        }
                    }
                }
            }
            GridRow {
                Text("Black point")
                Picker("", selection: $model.customBlackPoint) {
                    Text("Native").tag(BlackPointMode.native)
                    Text("Optimize").tag(BlackPointMode.optimize)
                }.labelsHidden()
            }
            GridRow {
                Text("Patch size")
                HStack {
                    Text("W")
                    Slider(value: $model.customPatchWidth, in: 0.1...1, step: 0.05)
                    Text("\(Int(model.customPatchWidth * 100))%").monospacedDigit().frame(width: 42)
                    Text("H")
                    Slider(value: $model.customPatchHeight, in: 0.1...1, step: 0.05)
                    Text("\(Int(model.customPatchHeight * 100))%").monospacedDigit().frame(width: 42)
                }
            }
            GridRow {
                Text("Patch position")
                HStack {
                    Text("X")
                    Slider(value: $model.customPatchHorizontalPosition, in: 0...1, step: 0.05)
                    Text("\(Int(model.customPatchHorizontalPosition * 100))%").monospacedDigit().frame(width: 42)
                    Text("Y")
                    Slider(value: $model.customPatchVerticalPosition, in: 0...1, step: 0.05)
                    Text("\(Int(model.customPatchVerticalPosition * 100))%").monospacedDigit().frame(width: 42)
                }
            }
        }
    }

    private var preparationChecklistSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Prepare the display",
                    subtitle: "These conditions keep the measurements stable and repeatable.",
                    symbol: "checklist"
                )
                Divider()
                Toggle("Display has warmed up and stabilized", isOn: $model.displayWarmedUp)
                Toggle("Ambient lighting will remain stable", isOn: $model.stableLighting)
                Toggle("HDR, Night Shift, True Tone, auto-brightness, and dynamic contrast are off", isOn: $model.dynamicFeaturesDisabled)
                Toggle("Display picture mode and hardware controls are ready", isOn: $model.displayControlsReady)
                Label(
                    model.preparationStepReady ? "Display preparation complete" : "Complete all four items before review",
                    systemImage: model.preparationStepReady ? "checkmark.circle.fill" : "info.circle"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(model.preparationStepReady ? .green : .secondary)
            }
            .padding(8)
        }
    }

    private var adjustmentSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Check brightness and white point",
                    subtitle: "A quick reading helps you adjust the monitor before the longer profiling run.",
                    symbol: "sun.max"
                )
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.adjustmentStatus.isReady ? "checkmark.circle.fill" : "dial.medium")
                        .foregroundStyle(model.adjustmentStatus.isReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.adjustmentStatus.title).font(.headline)
                        Text(model.adjustmentStatus.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(model.preCalibrationMeasurement == nil ? "Measure White" : "Measure Again") {
                        Task { await model.captureQuickMeasurement(forAdjustment: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || model.confirmedDisplay == nil || model.selectedInstrument == nil)
                    if model.isMeasuring {
                        ProgressView().controlSize(.small)
                        Button("Cancel", role: .cancel) { Task { await model.cancelMeasurement() } }
                    }
                    Spacer()
                    Text("Target: \(model.targetSummary)").font(.subheadline).foregroundStyle(.secondary)
                }
                if let measurement = model.preCalibrationMeasurement {
                    MeasurementCard(measurement: measurement)
                    ForEach(model.adjustmentGuidance, id: \.self) { guidance in
                        Label(guidance, systemImage: "dial.medium")
                    }
                } else {
                    Text("Recommended, but optional. Remove the ambient diffuser and hang the meter flat near the center of the confirmed display. When you choose Measure White, LumaProfile presents a full-screen RGB-white surface before triggering the meter and keeps it visible through the reading. A Cancel Reading control remains at the lower-right edge. This reading is saved as the measured Before white point for the results comparison.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var preflightSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Review and start",
                    subtitle: "LumaProfile will generate a profile without switching macOS to it.",
                    symbol: "checklist"
                )
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
                    GridRow {
                        Text("Display").foregroundStyle(.secondary)
                        Text(model.selectedDisplay?.name ?? "Not selected")
                    }
                    GridRow {
                        Text("Meter").foregroundStyle(.secondary)
                        Text(model.selectedInstrument?.model ?? "Not selected")
                    }
                    GridRow {
                        Text("Target").foregroundStyle(.secondary)
                        Text(model.targetSummary)
                    }
                    GridRow {
                        Text("Run").foregroundStyle(.secondary)
                        Text("\(model.calibrationEffort.rawValue) · \(model.calibrationEffort.characterizationPatchCount) characterization patches")
                    }
                    GridRow {
                        Text("Activation").foregroundStyle(.secondary)
                        Text("Manual after generation")
                    }
                }
                .textSelection(.enabled)

                Divider()
                ForEach(Array(model.preflightItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top) {
                        Image(systemName: item.1 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(item.1 ? .green : .orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text("\(item.0): \(item.1 ? "Ready" : "Needs attention")")
                            if !item.1 { Text(item.2).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }

                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isPreflightReady ? "Ready to calibrate" : "Complete the checklist to continue").font(.headline)
                        Text("Calibration leaves the ColorSync profile association unchanged. Argyll temporarily adjusts the display VideoLUT during measurement, then LumaProfile restores the active profile's calibration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start \(model.calibrationEffort.rawValue) Calibration") {
                        Task { await model.startCalibration() }
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isPreflightReady)
                }
            }
            .padding(8)
        }
    }
}

private struct WorkflowView: View {
    @ObservedObject var model: AppModel
    var session: CalibrationSession

    private var stages: [WorkflowStage] {
        if model.isActivationRunning {
            return [.installingProfile, .verifying, .completed]
        }
        return [.calibrating, .characterizing, .buildingProfile, .completed]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workflowTitle).font(.largeTitle.bold())
                        Text(model.statusMessage).font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isWorkflowRunning {
                        Button("Cancel", role: .destructive) { Task { await model.cancelCalibration() } }
                    }
                }

                if let action = model.requiredAction {
                    GroupBox {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "hand.raised.fill").font(.title).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your action is required").font(.headline)
                                Text(action.message)
                                HStack {
                                    Button("Continue") { Task { await model.continueRequiredAction() } }.buttonStyle(.borderedProminent)
                                    Button("Cancel Calibration", role: .destructive) { Task { await model.cancelCalibration() } }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        if let total = model.progressTotal, total > 0 {
                            ProgressView(value: Double(model.progressCompleted), total: Double(total))
                            Text("\(model.progressCompleted) of \(total) \(progressUnit)").font(.caption).foregroundStyle(.secondary)
                        } else if model.isWorkflowRunning { ProgressView() }
                        HStack(spacing: 0) {
                            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                                stageNode(stage)
                                if index < stages.count - 1 { Divider().frame(width: 34) }
                            }
                        }
                    }.padding(8)
                }

                if session.state == .completed
                    || session.state == .failed
                    || session.state == .cancelled
                    || session.state == .interrupted {
                    resultSection
                }

                DisclosureGroup("Session log (\(model.logs.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.logs) { record in
                            HStack(alignment: .firstTextBaseline) {
                                Text(record.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(record.level).font(.caption.weight(.semibold)).frame(width: 84, alignment: .leading)
                                Text(record.message).textSelection(.enabled)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
            .padding(28).frame(maxWidth: 920, alignment: .leading)
        }
    }

    private var workflowTitle: String {
        if model.isActivationRunning { return "Activating After profile" }
        return switch session.state {
        case .completed: "Profile complete"
        case .failed: "Calibration failed"
        case .cancelled: "Calibration cancelled"
        case .interrupted: "Profile recovery required"
        default: "Calibration in progress"
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                if session.state == .completed {
                    if let attempt = session.activationVerificationAttempt,
                       attempt.status == .failed || attempt.status == .cancelled {
                        Label(
                            attempt.restoredBeforeProfile == true
                                ? "After attempt did not complete — Before restored"
                                : "After attempt did not complete — profile state needs review",
                            systemImage: attempt.restoredBeforeProfile == true
                                ? "arrow.uturn.backward.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.title2.bold())
                        .foregroundStyle(.orange)
                        if let error = attempt.errorMessage {
                            Text(error).foregroundStyle(.secondary)
                        }
                    } else if session.installation?.activationStatus == .active {
                        Label(
                            session.verification == nil
                                ? "After profile activated by this session"
                                : "After profile activated and verified by this session",
                            systemImage: session.verification == nil
                                ? "checkmark.circle.fill"
                                : "checkmark.seal.fill"
                        )
                            .font(.title2.bold())
                            .foregroundStyle(.green)
                    } else {
                        Label("Profile generated — ColorSync association unchanged", systemImage: "doc.badge.checkmark")
                            .font(.title2.bold())
                            .foregroundStyle(.green)
                    }
                } else if session.state == .cancelled {
                    Label("Calibration cancelled safely", systemImage: "xmark.circle").font(.title2.bold())
                } else if session.state == .interrupted {
                    Label("Profile recovery required", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.orange)
                    Text("LumaProfile could not confirm that Before was restored. Use Restore Before below before trying another activation.")
                } else {
                    Label("Calibration failed", systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.red)
                    if let failure = session.failureMessage { Text(failure) }
                }
                if let report = session.verification {
                    VerificationMetricsView(report: report, assessment: session.verificationAssessment)
                } else if session.state == .completed, session.installation == nil {
                    Text("The generated candidate was not activated by this session. Activate it explicitly to run measured verification.")
                        .foregroundStyle(.secondary)
                } else if session.state == .completed,
                          session.installation?.activationStatus == .active {
                    Text("This session recorded an After activation, but it does not contain a completed verification report. The current ColorSync association may have changed since then.")
                        .foregroundStyle(.secondary)
                }
                if let patchCount = session.actualCharacterizationPatchCount
                    ?? session.plannedCharacterizationPatchCount {
                    let effort = session.target.flatMap { target in
                        session.characterizationPreset.flatMap {
                            CalibrationEffort.matching(
                                calibrationQuality: target.quality,
                                characterizationPreset: $0
                            )
                        }
                    }
                    Text("Measurement effort: \(effort?.rawValue ?? session.characterizationPreset?.rawValue ?? "Recorded") · \(patchCount) characterization patches")
                        .foregroundStyle(.secondary)
                }
                if let generatedAt = session.profileGenerationCompletedAt {
                    Text("Candidate profile generated \(generatedAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.profileBaseline != nil || session.artifacts.contains(where: {
                    $0.isComplete && $0.url.pathExtension.caseInsensitiveCompare("icc") == .orderedSame
                }) {
                    ProfileBeforeAfterView(model: model, session: session)
                }
                HStack {
                    Button("New Calibration") { model.beginAnotherCalibration() }.buttonStyle(.borderedProminent)
                    if session.activationVerificationAttempt?.status == .failed
                        || session.activationVerificationAttempt?.status == .cancelled
                        || session.verificationAssessment?.rating == .needsAttention {
                        Button("Retry Quick") { model.prepareRetry(effort: .quick) }
                        Button("Retry Balanced") { model.prepareRetry(effort: .balanced) }
                    }
                    Button("View in History") { model.destination = .history }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func stageNode(_ stage: WorkflowStage) -> some View {
        let currentIndex = stages.firstIndex(of: session.state) ?? -1
        let index = stages.firstIndex(of: stage) ?? 0
        let done = currentIndex >= index || session.state == .completed
        let active = session.state == stage
        return VStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : done ? .green : .secondary)
            Text(shortName(stage)).font(.caption).foregroundStyle(active ? .primary : .secondary)
        }.frame(maxWidth: .infinity)
    }

    private func shortName(_ stage: WorkflowStage) -> String {
        switch stage {
        case .calibrating: "Calibrate"
        case .characterizing: "Measure"
        case .buildingProfile: "Build"
        case .installingProfile: "Install"
        case .verifying: "Verify"
        case .completed: "Done"
        default: stage.rawValue
        }
    }

    private var progressUnit: String {
        switch session.state {
        case .generatingPatchSet, .awaitingMeterPlacement, .characterizing:
            "characterization patches"
        default:
            "readings"
        }
    }
}
