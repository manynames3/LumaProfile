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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Step \(model.setupStep.rawValue + 1) of \(CalibrationSetupStep.allCases.count)").lumaEyebrow()
                    Text(model.setupStep.title).lumaDisplay()
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
            .padding(Luma.pagePadding)
            .frame(maxWidth: Luma.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var setupStepper: some View {
        HStack(spacing: 10) {
            ForEach(CalibrationSetupStep.allCases) { step in
                let reached = step.rawValue <= model.setupStep.rawValue
                VStack(alignment: .leading, spacing: 8) {
                    Capsule()
                        .fill(reached ? Luma.accent : Color.white.opacity(0.10))
                        .frame(height: 3)
                    HStack(spacing: 6) {
                        if step.rawValue < model.setupStep.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Luma.positive)
                                .accessibilityHidden(true)
                        }
                        Text(step.title)
                            .font(.system(size: 12, weight: step == model.setupStep ? .semibold : .regular))
                            .foregroundStyle(reached ? .primary : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(step.rawValue + 1), \(step.title)\(step == model.setupStep ? ", current" : "")")
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.setupStep)
    }

    private var setupNavigation: some View {
        HStack {
            if model.setupStep != .hardware {
                Button("Back") { model.moveToPreviousSetupStep() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            Spacer()
            if model.setupStep != .review {
                if let blocker = continueBlocker {
                    Label(blocker, systemImage: "arrow.up.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Luma.caution)
                }
                Button("Continue") { model.moveToNextSetupStep() }
                    .buttonStyle(.lumaPrimary)
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

    /// Says what still blocks Continue, so a disabled button is never a mystery.
    private var continueBlocker: String? {
        guard !canContinueSetup else { return nil }
        switch model.setupStep {
        case .hardware:
            return "Confirm the display and meter above to continue"
        case .prepare:
            let left = model.preparationItemsRemaining
            return "Tick \(left) more \(left == 1 ? "box" : "boxes") above to continue"
        case .target, .review:
            return nil
        }
    }

    private var engineUnavailableBanner: some View {
        LumaCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title2).foregroundStyle(Luma.caution)
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
        VStack(spacing: 16) {
        LumaCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Display",
                    subtitle: "Identify and confirm the exact screen so the wrong one is never measured.",
                    symbol: "display"
                )
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
                            .foregroundStyle(model.selectedEngineDisplay == nil ? Luma.caution : .secondary)
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
                            .foregroundStyle(Luma.positive)
                            .font(.caption.weight(.medium))
                    }
                    Spacer()
                }
                Text("A large identifier appears on the screen LumaProfile will measure. Confirm it is the physical display you selected.")
                    .lumaNote()
                Toggle("I confirmed this number identifies \(model.selectedDisplay?.name ?? "the selected display")", isOn: $model.displayMappingConfirmed)
                    .toggleStyle(.lumaChecklist)
                    .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || !model.displayIdentified || model.selectedEngineDisplay == nil)
            }
        }
        LumaCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Meter",
                    subtitle: "A supported i1Display Pro / Plus colorimeter connected over USB.",
                    symbol: "sensor"
                )
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
                        .font(.caption).foregroundStyle(model.instruments.isEmpty ? Luma.caution : .secondary)
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
                                        .foregroundStyle(Luma.caution)
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
        }
        }
    }

    private var targetSection: some View {
        LumaCard {
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
                .labelsHidden()

                if model.targetChoice == .custom { customTargetEditor }
                else { LabeledContent("Target", value: model.targetSummary) }

                Text("Measurement effort").lumaEyebrow()
                HStack(spacing: 10) {
                    ForEach(CalibrationEffort.allCases, id: \.self) { effort in
                        LumaOptionTile(
                            title: effort.rawValue,
                            value: "\(effort.characterizationPatchCount)",
                            caption: "characterization patches",
                            isSelected: model.calibrationEffort == effort
                        ) {
                            model.calibrationEffort = effort
                        }
                    }
                }
                Text(model.calibrationEffort.detail).lumaNote()
                Text("Counts cover characterization only. Calibration and optional verification add their own readings, so run time varies.")
                    .lumaNote()
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
        LumaCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    SectionHeader(
                        title: "Tick each box when it's true",
                        subtitle: "All four are needed before you can continue. They keep readings steady.",
                        symbol: "checklist"
                    )
                    Spacer()
                    if !model.preparationStepReady {
                        Button("Tick All") { model.confirmAllPreparationItems() }
                            .help("Confirms all four conditions at once.")
                    }
                }
                Divider()
                Toggle("Display has warmed up and stabilized", isOn: $model.displayWarmedUp)
                    .toggleStyle(.lumaChecklist)
                Toggle("Ambient lighting will remain stable", isOn: $model.stableLighting)
                    .toggleStyle(.lumaChecklist)
                Toggle("HDR, Night Shift, True Tone, auto-brightness, and dynamic contrast are off", isOn: $model.dynamicFeaturesDisabled)
                    .toggleStyle(.lumaChecklist)
                Toggle("Display picture mode and hardware controls are ready", isOn: $model.displayControlsReady)
                    .toggleStyle(.lumaChecklist)
                Label(
                    model.preparationStepReady
                        ? "All four confirmed. You can continue."
                        : "\(4 - model.preparationItemsRemaining) of 4 confirmed",
                    systemImage: model.preparationStepReady ? "checkmark.circle.fill" : "info.circle"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(model.preparationStepReady ? Luma.positive : .secondary)
            }
        }
    }

    private var adjustmentSection: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Check brightness and white point",
                    subtitle: "A quick reading helps you adjust the monitor before the longer profiling run.",
                    symbol: "sun.max"
                )
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.adjustmentStatus.isReady ? "checkmark.circle.fill" : "dial.medium")
                        .foregroundStyle(model.adjustmentStatus.isReady ? Luma.positive : Luma.caution)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.adjustmentStatus.title).font(.headline)
                        Text(model.adjustmentStatus.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Adjust Live") {
                        Task { await model.startLiveAdjustment() }
                    }
                    .buttonStyle(.lumaPrimary)
                    .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || model.confirmedDisplay == nil || model.selectedInstrument == nil)
                    .help("Keeps reading while you turn the monitor's own brightness and white-point controls toward the target.")
                    Button("Measure Once") {
                        Task { await model.captureQuickMeasurement(forAdjustment: true) }
                    }
                    .disabled(model.hasActiveOperation || model.isRefreshing || model.isRefreshingInstruments || model.confirmedDisplay == nil || model.selectedInstrument == nil)
                    .help("Takes a single white reading through the active profile.")
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
                    Text("Optional, recommended. Remove the ambient diffuser and hang the meter flat at the center of the confirmed display. Adjust Live shows a full-screen white surface with a live gauge; Measure Once shows the same surface with a Cancel Reading control, and saves one reading as the Before white point.")
                        .lumaNote()
                }
            }
        }
    }

    private var preflightSection: some View {
        LumaCard {
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
                let pending = model.preflightItems.filter { !$0.1 }
                if pending.isEmpty {
                    Label("All \(model.preflightItems.count) readiness checks passed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Luma.positive)
                } else {
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(Luma.caution)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.0): Needs attention")
                                Text(item.2).lumaNote()
                            }
                        }
                    }
                }

                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isPreflightReady ? "Ready to calibrate" : "Complete the checklist to continue").font(.headline)
                        Text("Your active profile is not switched. The display's calibration is adjusted temporarily during measurement, then restored.")
                            .lumaNote()
                    }
                    Spacer()
                    Button("Start \(model.calibrationEffort.rawValue) Calibration") {
                        Task { await model.startCalibration() }
                    }
                        .buttonStyle(.lumaPrimary).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isPreflightReady)
                }
            }
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
                        Text(workflowTitle).lumaDisplay()
                        Text(model.statusMessage).font(Luma.lead).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isWorkflowRunning {
                        Button("Cancel", role: .destructive) { Task { await model.cancelCalibration() } }
                    }
                }

                if let action = model.requiredAction {
                    LumaCard {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "hand.raised.fill").font(.title).foregroundStyle(Luma.caution)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your action is required").font(.headline)
                                Text(action.message)
                                HStack {
                                    Button("Continue") { Task { await model.continueRequiredAction() } }.buttonStyle(.lumaPrimary)
                                    Button("Cancel Calibration", role: .destructive) { Task { await model.cancelCalibration() } }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if model.isWorkflowRunning {
                    LumaCard {
                        VStack(alignment: .leading, spacing: 14) {
                            if let total = model.progressTotal, total > 0 {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(model.progressCompleted)").font(Luma.heroNumeral)
                                    Text("of \(total) \(progressUnit)").font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                LumaProgressBar(fraction: Double(model.progressCompleted) / Double(total))
                            } else if model.isWorkflowRunning { ProgressView().controlSize(.small) }
                            HStack(spacing: 0) {
                                ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                                    stageNode(stage)
                                    if index < stages.count - 1 { Divider().frame(width: 34) }
                                }
                            }
                        }
                    }
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
            .padding(Luma.pagePadding)
            .frame(maxWidth: Luma.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
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
        LumaCard {
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
                        .font(Luma.title)
                        .foregroundStyle(Luma.caution)
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
                            .font(Luma.title)
                            .foregroundStyle(Luma.positive)
                    } else {
                        Label("Profile generated — ColorSync association unchanged", systemImage: "doc.badge.checkmark")
                            .font(Luma.title)
                            .foregroundStyle(Luma.positive)
                    }
                } else if session.state == .cancelled {
                    Label("Calibration cancelled safely", systemImage: "xmark.circle").font(Luma.title)
                } else if session.state == .interrupted {
                    Label("Profile recovery required", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(Luma.title)
                        .foregroundStyle(Luma.caution)
                    Text("LumaProfile could not confirm that Before was restored. Use Restore Before below before trying another activation.")
                } else {
                    Label("Calibration failed", systemImage: "exclamationmark.triangle.fill").font(Luma.title).foregroundStyle(Luma.critical)
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
                    Button("New Calibration") { model.beginAnotherCalibration() }.buttonStyle(.lumaPrimary)
                    if session.activationVerificationAttempt?.status == .failed
                        || session.activationVerificationAttempt?.status == .cancelled
                        || session.verificationAssessment?.rating == .needsAttention {
                        Button("Retry Quick") { model.prepareRetry(effort: .quick) }
                        Button("Retry Balanced") { model.prepareRetry(effort: .balanced) }
                    }
                    Button("View in History") { model.destination = .history }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stageNode(_ stage: WorkflowStage) -> some View {
        let currentIndex = stages.firstIndex(of: session.state) ?? -1
        let index = stages.firstIndex(of: stage) ?? 0
        let done = currentIndex >= index || session.state == .completed
        let active = session.state == stage
        return VStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Luma.accent : done ? Luma.positive : .secondary)
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
