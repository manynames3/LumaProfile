import AppKit
import Combine
import Foundation
import LumaCore
import UniformTypeIdentifiers

enum AppDestination: String, CaseIterable, Identifiable {
    case calibrate = "Calibrate"
    case meter = "Quick Meter"
    case history = "History"
    case settings = "Settings"
    case about = "About & Licenses"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .calibrate: "slider.horizontal.3"
        case .meter: "gauge.with.dots.needle.67percent"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

enum TargetChoice: String, CaseIterable, Codable, Identifiable {
    case photography
    case web
    case videoGamma24
    case videoBT1886
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .photography: "Photo / Design"
        case .web: "Web sRGB"
        case .videoGamma24: "Video Gamma 2.4"
        case .videoBT1886: "Video BT.1886"
        case .custom: "Custom"
        }
    }
}

enum CustomWhitePoint: String, CaseIterable, Codable, Identifiable {
    case d65 = "D65"
    case native = "Native"
    case temperature = "Temperature"
    case chromaticity = "xy Coordinates"
    var id: Self { self }
}

enum CustomTransferFunction: String, CaseIterable, Codable, Identifiable {
    case gamma = "Gamma"
    case sRGB = "sRGB"
    case bt1886 = "BT.1886"
    var id: Self { self }
}

enum CalibrationSetupStep: Int, CaseIterable, Identifiable {
    case hardware
    case target
    case prepare
    case review

    var id: Self { self }

    var title: String {
        switch self {
        case .hardware: "Display & Meter"
        case .target: "Target & Speed"
        case .prepare: "Prepare"
        case .review: "Review"
        }
    }

    var symbol: String {
        switch self {
        case .hardware: "display"
        case .target: "scope"
        case .prepare: "sun.max"
        case .review: "checklist"
        }
    }
}

private struct RememberedDisplaySetup: Codable {
    var engineDisplayIndex: Int?
    var engineDisplayDescription: String?
    var instrumentID: String?
    var correctionID: UUID?
    var targetChoice: TargetChoice
    var calibrationEffort: CalibrationEffort
    var profileModel: ProfileModel
    var customWhitePoint: CustomWhitePoint?
    var customTemperature: Double?
    var customChromaticityX: Double?
    var customChromaticityY: Double?
    var customLuminanceEnabled: Bool?
    var customLuminance: Double?
    var customTransfer: CustomTransferFunction?
    var customGamma: Double?
    var customBlackPoint: BlackPointMode?
    var customPatchWidth: Double?
    var customPatchHeight: Double?
    var customPatchHorizontalPosition: Double?
    var customPatchVerticalPosition: Double?
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

private enum AppModelHardwareError: LocalizedError {
    case meterDisconnected(String)

    var errorDescription: String? {
        switch self {
        case .meterDisconnected(let model):
            "The selected \(model) is no longer available. Reconnect it, wait a moment, then refresh meters. No profile was changed."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    typealias EngineFactory = @Sendable (URL?) -> any CalibrationEngine

    @Published var destination: AppDestination? = .calibrate
    @Published var engineProbe = EngineProbe(isAvailable: false, diagnostic: "Checking calibration engine…")
    @Published var displays: [PhysicalDisplay] = []
    @Published var instruments: [InstrumentDescriptor] = []
    @Published var engineDisplays: [ArgyllDisplayDescriptor] = []
    @Published var corrections: [DisplayCorrection] = []
    @Published var sessions: [CalibrationSession] = []
    @Published var sessionLoadIssues: [SessionLoadIssue] = []
    @Published var isRefreshing = false
    @Published var isRefreshingInstruments = false
    @Published private var protectedCleanupSessionIDs: Set<UUID> = []
    @Published private var hasUnresolvedSessionLoadIssues = false
    @Published private(set) var hasFinishedInitialRecoveryAudit = false
    @Published var setupStep: CalibrationSetupStep = .hardware

    @Published var selectedDisplayID: String?
    @Published var selectedInstrumentID: String?
    @Published var selectedCorrectionID: UUID?
    @Published var displayNumber = "" {
        didSet {
            if displayNumber != oldValue {
                displayMappingConfirmed = false
                displayIdentified = false
            }
        }
    }
    @Published var displayMappingConfirmed = false
    @Published var displayIdentified = false
    @Published var correctionCompatibilityConfirmed = false

    @Published var targetChoice: TargetChoice = .photography
    @Published var customWhitePoint: CustomWhitePoint = .d65
    @Published var customTemperature = 6500.0
    @Published var customChromaticityX = 0.3127
    @Published var customChromaticityY = 0.3290
    @Published var customLuminanceEnabled = true
    @Published var customLuminance = 120.0
    @Published var customTransfer: CustomTransferFunction = .gamma
    @Published var customGamma = 2.2
    @Published var customBlackPoint: BlackPointMode = .native
    @Published var customPatchWidth = 0.25
    @Published var customPatchHeight = 0.25
    @Published var customPatchHorizontalPosition = 0.5
    @Published var customPatchVerticalPosition = 0.5
    @Published var calibrationEffort: CalibrationEffort = .quick
    @Published var profileModel: ProfileModel = .shaperMatrix

    @Published var displayWarmedUp = false
    @Published var stableLighting = false
    @Published var dynamicFeaturesDisabled = false
    @Published var displayControlsReady = false

    @Published var quickMeasurement: LumaCore.Measurement?
    @Published var preCalibrationMeasurement: LumaCore.Measurement?
    @Published var isMeasuring = false

    @Published var workflowSession: CalibrationSession?
    @Published var workflowDirectory: URL?
    @Published var isWorkflowRunning = false
    @Published var isActivationRunning = false
    @Published var isRestoreRunning = false
    @Published var progressCompleted = 0
    @Published var progressTotal: Int?
    @Published var statusMessage = "Ready"
    @Published var requiredAction: UserActionRequest?
    @Published var logs: [LogRecord] = []

    @Published var measurementMode: MeasurementMode {
        didSet {
            guard measurementMode != oldValue else { return }
            quickMeasurement = nil
            preCalibrationMeasurement = nil
        }
    }
    @Published var explicitEnginePath: String
    @Published var alert: AppAlert?
    /// True while the live brightness and white-point gauge is taking readings.
    @Published private(set) var isLiveAdjusting = false
    let liveAdjustment = LiveAdjustmentState()
    private var liveStopRequested = false
    /// Set while a session's Before profile is temporarily shown for comparison.
    @Published private(set) var comparisonBeforeSessionID: UUID?
    @Published private(set) var isSwitchingComparison = false
    private var comparisonContext: (record: ProfileInstallationRecord, display: PhysicalDisplay)?

    private var engine: any CalibrationEngine
    private let engineFactory: EngineFactory
    private let inventory: any DisplayInventory
    private let installer: any ProfileInstaller
    private let sessionStore: FileSessionStore
    private let correctionLibrary: CorrectionLibrary
    private var workflow: CalibrationWorkflow
    private let defaults: UserDefaults
    private let displayIdentifier = DisplayIdentificationPresenter()
    private let whiteMeasurementSurface = WhiteMeasurementSurfacePresenter()
    private var measurementTask: Task<LumaCore.Measurement, Error>?
    private var restoreTask: Task<CalibrationSession, Error>?
    private var workflowActivity: NSObjectProtocol?

    private static let rememberedSetupsKey = "rememberedDisplaySetups.v1"

    init(
        engineFactory: @escaping EngineFactory = { ArgyllCalibrationEngine(explicitDirectory: $0) },
        inventory: any DisplayInventory = MacDisplayInventory(),
        installer: (any ProfileInstaller)? = nil,
        sessionStore: FileSessionStore = FileSessionStore(),
        correctionLibrary: CorrectionLibrary = CorrectionLibrary(),
        defaults: UserDefaults = .standard
    ) {
        self.engineFactory = engineFactory
        self.inventory = inventory
        self.installer = installer ?? MacProfileInstaller(inventory: inventory)
        self.sessionStore = sessionStore
        self.correctionLibrary = correctionLibrary
        self.defaults = defaults

        let storedPath = defaults.string(forKey: "engineDirectory") ?? ""
        self.explicitEnginePath = storedPath
        self.measurementMode = MeasurementMode(rawValue: defaults.string(forKey: "measurementMode") ?? "") ?? .auto
        let explicitURL = storedPath.isEmpty ? nil : URL(fileURLWithPath: storedPath, isDirectory: true)
        let engine = engineFactory(explicitURL)
        self.engine = engine
        self.workflow = CalibrationWorkflow(
            engine: engine,
            installer: self.installer,
            store: sessionStore
        )
        ApplicationRunGuard.shared.model = self
    }

    var selectedDisplay: PhysicalDisplay? {
        displays.first { $0.id == selectedDisplayID }
    }

    var hasActiveOperation: Bool {
        isWorkflowRunning || isMeasuring || isRestoreRunning || isRefreshingInstruments
    }

    var shouldGuardTermination: Bool {
        !hasFinishedInitialRecoveryAudit || hasActiveOperation || requiresProtectedCleanupReview
    }

    var requiresProtectedCleanupReview: Bool {
        hasUnresolvedSessionLoadIssues || !protectedCleanupSessionIDs.isEmpty
    }

    var engineStatusSummary: String {
        if engineProbe.isAvailable {
            return engineProbe.version.map { "Bundled ArgyllCMS \($0) is ready." }
                ?? "The bundled calibration engine is ready."
        }
        if !explicitEnginePath.isEmpty {
            return "The advanced engine override is incomplete or incompatible. Clear it to return to the bundled engine."
        }
        return "The bundled calibration engine could not be opened. Reinstall this complete LumaProfile app, or review advanced diagnostics in Settings."
    }

    var selectedInstrument: InstrumentDescriptor? {
        instruments.first { $0.id == selectedInstrumentID }
    }

    var selectedCorrection: DisplayCorrection? {
        corrections.first { $0.id == selectedCorrectionID }
    }

    var selectedEngineDisplay: ArgyllDisplayDescriptor? {
        guard let index = Int(displayNumber) else { return nil }
        return engineDisplays.first { $0.index == index }
    }

    var displayMappingSummary: String {
        guard let selectedEngineDisplay else { return "No engine display mapped" }
        return "Display \(selectedEngineDisplay.index) · \(selectedEngineDisplay.description)"
    }

    var correctionCompatibilityIssues: [String] {
        guard let correction = selectedCorrection else { return [] }
        var issues: [String] = []
        if let declaredDisplay = correction.declaredDisplay,
           let display = selectedDisplay,
           !Self.namesOverlap(declaredDisplay, display.name) {
            issues.append("The correction declares ‘\(declaredDisplay)’, but the selected display is ‘\(display.name)’.")
        }
        if let declaredInstrument = correction.declaredInstrument,
           let instrument = selectedInstrument,
           !Self.namesOverlap(declaredInstrument, instrument.model) {
            issues.append("The correction declares meter ‘\(declaredInstrument)’, but the selected meter is ‘\(instrument.model)’.")
        }
        return issues
    }

    var correctionIsReady: Bool {
        selectedCorrection == nil || correctionCompatibilityIssues.isEmpty || correctionCompatibilityConfirmed
    }

    var hardwareStepReady: Bool {
        engineProbe.isAvailable
            && confirmedDisplay != nil
            && displayIdentified
            && selectedInstrument?.isI1D3Family == true
            && correctionIsReady
    }

    var preparationStepReady: Bool {
        displayWarmedUp && stableLighting && dynamicFeaturesDisabled && displayControlsReady
    }

    var adjustmentIsReady: Bool {
        guard let measurement = preCalibrationMeasurement else { return false }
        let luminanceReady = currentTarget.luminanceCDM2.map {
            abs(measurement.luminanceCDM2 - $0) <= 5
        } ?? true
        let whiteReady: Bool
        switch currentTarget.whitePoint {
        case .d65:
            whiteReady = measurement.correlatedColorTemperature.map { abs($0 - 6_500) <= 250 } ?? true
        case .temperature(let kelvin):
            whiteReady = measurement.correlatedColorTemperature.map { abs($0 - kelvin) <= 250 } ?? true
        case .native, .chromaticity:
            whiteReady = true
        }
        return luminanceReady && whiteReady
    }

    var confirmedDisplay: PhysicalDisplay? {
        guard var display = selectedDisplay,
              displayMappingConfirmed,
              let number = Int(displayNumber), number > 0,
              let descriptor = engineDisplays.first(where: { $0.index == number })
        else { return nil }
        display.argyllDisplayIndex = number
        display.argyllDisplayDescription = descriptor.description
        return display
    }

    var currentTarget: CalibrationTarget {
        var target: CalibrationTarget
        switch targetChoice {
        case .photography: target = .photography
        case .web: target = .webSRGB
        case .videoGamma24: target = .videoGamma24
        case .videoBT1886: target = .videoBT1886
        case .custom:
            let whitePoint: WhitePointTarget = switch customWhitePoint {
            case .d65: .d65
            case .native: .native
            case .temperature: .temperature(kelvin: customTemperature)
            case .chromaticity: .chromaticity(Chromaticity(x: customChromaticityX, y: customChromaticityY))
            }
            let transfer: TransferFunction = switch customTransfer {
            case .gamma: .gamma(customGamma)
            case .sRGB: .sRGB
            case .bt1886: .bt1886
            }
            target = CalibrationTarget(
                name: "Custom target",
                whitePoint: whitePoint,
                luminanceCDM2: customLuminanceEnabled ? customLuminance : nil,
                transferFunction: transfer,
                blackPointMode: customBlackPoint,
                quality: calibrationEffort.calibrationQuality,
                patchGeometry: PatchGeometry(
                    widthFraction: customPatchWidth,
                    heightFraction: customPatchHeight,
                    horizontalPosition: customPatchHorizontalPosition,
                    verticalPosition: customPatchVerticalPosition
                )
            )
        }
        target.quality = calibrationEffort.calibrationQuality
        target.correctionID = selectedCorrection?.id
        return target
    }

    var preflightItems: [(String, Bool, String)] {
        [
            ("Saved recovery check complete", hasFinishedInitialRecoveryAudit, "Wait for LumaProfile to finish checking saved sessions. If the check failed, retry it before calibrating."),
            ("Calibration engine ready", engineProbe.isAvailable, engineProbe.diagnostic),
            ("Display selected and mapped", confirmedDisplay != nil, "Confirm the engine display number under Display Mapping."),
            ("Physical display identified", displayIdentified, "Use Show on Display and visually confirm the full-screen identifier."),
            ("i1Display Pro / Plus detected over USB", selectedInstrument?.isI1D3Family == true, "Connect a supported i1D3-family meter and refresh."),
            ("Display correction matches this setup", correctionIsReady, "Review the correction's declared display and meter before continuing."),
            ("Display warmed up", displayWarmedUp, "Allow roughly 30 minutes for the display to stabilize."),
            ("Ambient lighting stable", stableLighting, "Avoid changing daylight or direct light on the panel."),
            ("Dynamic display features off", dynamicFeaturesDisabled, "Turn off HDR, Night Shift, True Tone, auto-brightness, and dynamic contrast."),
            ("Hardware controls ready", displayControlsReady, "Use the display's intended picture mode and reset unusual color controls."),
            ("Previous profile state confirmed", !requiresProtectedCleanupReview, "Open the affected session and choose Restore Before before starting another calibration."),
        ]
    }

    var isPreflightReady: Bool {
        preflightItems.allSatisfy(\.1)
            && !hasActiveOperation
            && !isRefreshing
            && !isRefreshingInstruments
    }

    var targetSummary: String {
        let white = switch currentTarget.whitePoint {
        case .d65: "D65"
        case .native: "Native white"
        case .temperature(let kelvin): "\(Int(kelvin)) K"
        case .chromaticity(let value): String(format: "x %.4f, y %.4f", value.x, value.y)
        }
        let luminance = currentTarget.luminanceCDM2.map { "\(Int($0)) cd/m²" } ?? "Native luminance"
        let transfer = switch currentTarget.transferFunction {
        case .gamma(let value): String(format: "Gamma %.1f", value)
        case .sRGB: "sRGB TRC"
        case .bt1886: "BT.1886"
        }
        return "\(white) · \(luminance) · \(transfer)"
    }

    var adjustmentGuidance: [String] {
        guard let measurement = preCalibrationMeasurement else { return [] }
        var guidance: [String] = []
        if let targetLuminance = currentTarget.luminanceCDM2 {
            let difference = measurement.luminanceCDM2 - targetLuminance
            if abs(difference) <= 5 {
                guidance.append("Brightness is close to target. Leave it where it is.")
            } else if difference > 0 {
                guidance.append("Lower the display brightness by about \(Int(abs(difference))) cd/m², then measure again.")
            } else {
                guidance.append("Raise the display brightness by about \(Int(abs(difference))) cd/m², then measure again.")
            }
        }
        if let temperature = measurement.correlatedColorTemperature {
            switch currentTarget.whitePoint {
            case .d65, .temperature:
                let desired = customWhitePoint == .temperature && targetChoice == .custom ? customTemperature : 6500
                if abs(temperature - desired) > 250 {
                    guidance.append(temperature > desired ? "If available, warm the display's white-point control." : "If available, cool the display's white-point control.")
                } else {
                    guidance.append("White point is close enough for calibration to refine.")
                }
            default: break
            }
        }
        if guidance.isEmpty { guidance.append("The reading is usable. Continue with calibration.") }
        return guidance
    }

    var adjustmentStatus: (title: String, detail: String, isReady: Bool) {
        guard preCalibrationMeasurement != nil else {
            return (
                "Not measured yet",
                "Place the meter near the display center; Measure White opens the full-screen white surface before reading.",
                false
            )
        }
        if adjustmentIsReady {
            return (
                "Ready for calibration",
                "Brightness and white point are within the recommended setup range.",
                true
            )
        }
        return (
            "Adjustment recommended",
            "Use the display's hardware controls, then measure again.",
            false
        )
    }

    func load() async {
        guard !isRefreshing else { return }
        // Every retry is a fresh fail-closed audit. A previous successful load
        // must not authorize profile work if the current recovery read fails.
        hasFinishedInitialRecoveryAudit = false
        isRefreshing = true
        var recoveryAuditSucceeded = false
        defer {
            isRefreshing = false
            if recoveryAuditSucceeded { hasFinishedInitialRecoveryAudit = true }
        }

        async let probeTask = engine.probe()
        async let displaysTask = inventory.displays()
        async let correctionsTask = correctionLibrary.list()

        engineProbe = await probeTask
        do {
            displays = try await displaysTask
            preserveOrSelectDisplay()
        } catch {
            present(error, title: "Displays unavailable")
        }
        do {
            corrections = try await correctionsTask
            restoreRememberedSetup()
        } catch {
            present(error, title: "Corrections unavailable")
        }
        do {
            let reconciled = try await workflow.reconcileInterruptedSessions()
            protectedCleanupSessionIDs.formUnion(
                reconciled.lazy
                    .filter(Self.sessionRequiresProtectedCleanup)
                    .map(\.id)
            )
        } catch {
            present(error, title: "Recovery check unavailable")
        }
        do {
            try await reloadSessions()
            recoveryAuditSucceeded = true
        } catch {
            present(error, title: "History unavailable")
        }
        await performInstrumentRefresh()
    }

    func refreshInstruments() async {
        // User-triggered refreshes must not interleave with an engine reload.
        // load() and saveSettingsAndReloadEngine() own their full
        // probe-plus-discovery transaction through performInstrumentRefresh().
        guard !isRefreshing else { return }
        await performInstrumentRefresh()
    }

    private func performInstrumentRefresh() async {
        guard !isRefreshingInstruments, !hasActiveOperation else { return }
        isRefreshingInstruments = true
        defer { isRefreshingInstruments = false }
        guard engineProbe.isAvailable else {
            instruments = []
            selectedInstrumentID = nil
            return
        }
        do {
            instruments = try await engine.discoverInstruments().filter(\.isI1D3Family)
            if !instruments.contains(where: { $0.id == selectedInstrumentID }) {
                selectedInstrumentID = rememberedSetup()?.instrumentID.flatMap { rememberedID in
                    instruments.first(where: { $0.id == rememberedID })?.id
                } ?? instruments.first?.id
            }
        } catch {
            instruments = []
            present(error, title: "Meter discovery failed")
        }
        if let argyllEngine = engine as? ArgyllCalibrationEngine {
            engineDisplays = (try? await argyllEngine.discoverArgyllDisplays()) ?? []
        } else {
            engineDisplays = []
        }
        restoreRememberedSetup()
        suggestDisplayMapping()
    }

    func selectedDisplayChanged() {
        displayNumber = ""
        selectedInstrumentID = nil
        selectedCorrectionID = nil
        displayMappingConfirmed = false
        quickMeasurement = nil
        preCalibrationMeasurement = nil
        displayIdentified = false
        correctionCompatibilityConfirmed = false
        restoreRememberedSetup()
        suggestDisplayMapping()
    }

    func selectedInstrumentChanged() {
        correctionCompatibilityConfirmed = false
        quickMeasurement = nil
        preCalibrationMeasurement = nil
    }

    func selectedCorrectionChanged() {
        correctionCompatibilityConfirmed = false
        quickMeasurement = nil
        preCalibrationMeasurement = nil
    }

    func moveToNextSetupStep() {
        guard let next = CalibrationSetupStep(rawValue: setupStep.rawValue + 1) else { return }
        setupStep = next
    }

    func moveToPreviousSetupStep() {
        guard let previous = CalibrationSetupStep(rawValue: setupStep.rawValue - 1) else { return }
        setupStep = previous
    }

    func identifySelectedDisplay() {
        guard let display = selectedDisplay else {
            alert = AppAlert(title: "No display selected", message: "Choose a display first.")
            return
        }
        guard let number = Int(displayNumber), number > 0 else {
            alert = AppAlert(title: "Display number required", message: "Choose or enter a positive engine display number before identifying the screen.")
            return
        }
        do {
            try displayIdentifier.show(display: display, engineNumber: number)
            displayIdentified = true
        } catch {
            present(error, title: "Could not identify display")
        }
    }

    func importCorrection(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let correction = try await correctionLibrary.importFile(at: url)
            corrections = try await correctionLibrary.list()
            selectedCorrectionID = correction.id
            correctionCompatibilityConfirmed = false
        } catch {
            present(error, title: "Correction not imported")
        }
    }

    func captureQuickMeasurement(forAdjustment: Bool = false) async {
        guard !hasActiveOperation, !isRefreshing, !isRefreshingInstruments else { return }
        guard engineProbe.isAvailable else {
            alert = AppAlert(title: "Calibration engine unavailable", message: engineProbe.diagnostic)
            return
        }
        guard let instrument = selectedInstrument else {
            alert = AppAlert(title: "No supported meter", message: "Connect an i1Display Pro / Plus and refresh meter discovery.")
            return
        }
        guard let display = confirmedDisplay else {
            alert = AppAlert(title: "Display mapping required", message: "Select the macOS display and confirm its positive engine display number first.")
            return
        }

        isMeasuring = true
        beginWorkflowActivity(reason: forAdjustment ? "Measuring the setup white surface" : "Taking a display measurement")
        defer {
            measurementTask = nil
            if forAdjustment { whiteMeasurementSurface.dismiss() }
            isMeasuring = false
            endWorkflowActivity()
        }
        do {
            let request = SpotMeasurementRequest(
                instrument: instrument,
                display: display,
                correction: selectedCorrection,
                mode: measurementMode
            )
            let measurementEngine = engine
            if forAdjustment {
                displayIdentifier.dismiss()
                try whiteMeasurementSurface.show(display: display) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.cancelMeasurement()
                    }
                }
            }
            // Own the presentation delay and the engine call in one cancellable
            // task. Quit, sleep, toolbar cancellation, and the surface button
            // can therefore stop the read before spotread launches.
            let task = Task {
                if forAdjustment {
                    try await Task.sleep(for: .milliseconds(300))
                    try Task.checkCancellation()
                }
                return try await measurementEngine.measure(request)
            }
            measurementTask = task
            let measurement = try await task.value
            guard !forAdjustment || !whiteMeasurementSurface.cancelRequested else { return }
            if forAdjustment {
                preCalibrationMeasurement = measurement
            } else {
                quickMeasurement = measurement
            }
        } catch is CancellationError {
            // The operator explicitly cancelled this one-shot reading.
        } catch {
            present(error, title: "Measurement failed")
        }
    }

    /// Repeats the setup white reading on a full-screen white surface that shows
    /// a live gauge, so the operator can turn the monitor's own brightness and
    /// white-point controls toward the target before calibrating. Each completed
    /// reading replaces the saved Before white reading.
    func startLiveAdjustment() async {
        guard !hasActiveOperation, !isRefreshing, !isRefreshingInstruments else { return }
        guard engineProbe.isAvailable else {
            alert = AppAlert(title: "Calibration engine unavailable", message: engineProbe.diagnostic)
            return
        }
        guard let instrument = selectedInstrument else {
            alert = AppAlert(title: "No supported meter", message: "Connect an i1Display Pro / Plus and refresh meter discovery.")
            return
        }
        guard let display = confirmedDisplay else {
            alert = AppAlert(title: "Display mapping required", message: "Select the macOS display and confirm its positive engine display number first.")
            return
        }

        let targetTemperature: Double? = switch currentTarget.whitePoint {
        case .d65: 6_500
        case .temperature(let kelvin): kelvin
        case .native, .chromaticity: nil
        }
        liveAdjustment.begin(
            measurement: preCalibrationMeasurement,
            targetLuminance: currentTarget.luminanceCDM2,
            targetTemperature: targetTemperature
        )
        liveStopRequested = false
        isMeasuring = true
        isLiveAdjusting = true
        beginWorkflowActivity(reason: "Adjusting the display with live meter readings")
        defer {
            measurementTask = nil
            whiteMeasurementSurface.dismiss()
            isMeasuring = false
            isLiveAdjusting = false
            endWorkflowActivity()
        }
        do {
            let request = SpotMeasurementRequest(
                instrument: instrument,
                display: display,
                correction: selectedCorrection,
                mode: measurementMode
            )
            let measurementEngine = engine
            displayIdentifier.dismiss()
            try whiteMeasurementSurface.show(display: display, live: liveAdjustment) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.cancelMeasurement()
                }
            }
            var isFirstReading = true
            // Bounded so an unattended session cannot hold the meter forever.
            while !liveStopRequested, liveAdjustment.readingCount < 240 {
                let needsSettleDelay = isFirstReading
                let task = Task {
                    if needsSettleDelay {
                        try await Task.sleep(for: .milliseconds(300))
                    }
                    try Task.checkCancellation()
                    return try await measurementEngine.measure(request)
                }
                measurementTask = task
                let measurement = try await task.value
                isFirstReading = false
                guard !liveStopRequested else { break }
                preCalibrationMeasurement = measurement
                liveAdjustment.record(measurement)
            }
        } catch is CancellationError {
            // The operator finished adjusting.
        } catch {
            // Stopping cancels the read in flight; that is not a failure.
            if !liveStopRequested { present(error, title: "Live reading stopped") }
        }
    }

    func cancelMeasurement() async {
        liveStopRequested = true
        whiteMeasurementSurface.dismiss()
        measurementTask?.cancel()
        await engine.cancelCurrentOperation()
    }

    func startCalibration() async {
        await restoreAfterIfComparing()
        guard isPreflightReady,
              let display = confirmedDisplay,
              let instrument = selectedInstrument
        else {
            alert = AppAlert(title: "Preflight incomplete", message: "Complete every required preflight item before starting.")
            return
        }

        let request = CalibrationWorkflowRequest(
            display: display,
            instrument: instrument,
            target: currentTarget,
            correction: selectedCorrection,
            measurementMode: measurementMode,
            setupMeasurement: preCalibrationMeasurement,
            characterization: calibrationEffort.characterizationPreset,
            profileModel: profileModel,
            profileDescription: "\(display.name) — \(currentTarget.name) — \(CalibrationWorkflow.profileDateStamp(Date())) (LumaProfile)"
        )

        workflowSession = nil
        workflowDirectory = nil
        logs = []
        requiredAction = nil
        progressCompleted = 0
        progressTotal = nil
        statusMessage = "Starting calibration…"
        isWorkflowRunning = true
        beginWorkflowActivity(reason: "Measuring and building a display profile")
        defer {
            isWorkflowRunning = false
            endWorkflowActivity()
        }

        do {
            statusMessage = "Rechecking the meter connection…"
            try await requireSelectedInstrumentConnection(instrument)
            saveRememberedSetup(display: display, instrument: instrument)
            let stream = await workflow.run(request)
            for try await update in stream {
                apply(update)
            }
            try await reloadSessions()
        } catch {
            present(error, title: "Calibration stopped")
            try? await reloadSessions()
        }
    }

    func activateAndVerify(_ session: CalibrationSession) async {
        await restoreAfterIfComparing()
        guard hasFinishedInitialRecoveryAudit else {
            alert = AppAlert(
                title: "Recovery check incomplete",
                message: "LumaProfile has not finished checking saved sessions. Retry the recovery check before activating a profile."
            )
            return
        }
        guard !requiresProtectedCleanupReview else {
            alert = AppAlert(
                title: "Restore Before first",
                message: "LumaProfile has not confirmed the previous profile state. Open the affected session and choose Restore Before before another activation."
            )
            return
        }
        guard !hasActiveOperation, !isRefreshing, !isRefreshingInstruments else { return }

        workflowSession = session
        progressCompleted = 0
        progressTotal = nil
        requiredAction = nil
        statusMessage = "Preparing profile activation…"
        isWorkflowRunning = true
        isActivationRunning = true
        beginWorkflowActivity(reason: "Activating and verifying a display profile")
        defer {
            isActivationRunning = false
            isWorkflowRunning = false
            endWorkflowActivity()
        }

        do {
            guard let instrument = session.instrument else {
                throw CalibrationWorkflowError.missingInstrument
            }
            statusMessage = "Rechecking the meter connection…"
            try await requireSelectedInstrumentConnection(instrument)
            let stream = await workflow.activateAndVerify(session: session)
            for try await update in stream {
                apply(update)
            }
            try await reloadSessions()
        } catch {
            present(error, title: "Profile activation stopped")
            try? await reloadSessions()
        }
    }

    func continueRequiredAction() async {
        guard let action = requiredAction else { return }
        do {
            try await workflow.acknowledgeUserAction(id: action.id)
            requiredAction = nil
            statusMessage = "Continuing…"
        } catch {
            present(error, title: "Could not continue")
        }
    }

    func cancelCalibration() async {
        statusMessage = "Cancelling safely…"
        await workflow.cancel()
    }

    func prepareForTermination() async -> Bool {
        guard hasActiveOperation else { return !requiresProtectedCleanupReview }
        let wasWorkflowRunning = isWorkflowRunning
        statusMessage = "Stopping safely before quitting…"
        if isRestoreRunning {
            // Profile restoration is already the safe terminal action. Do not
            // cancel it halfway through; wait briefly and cancel Quit if it has
            // not finished.
            for _ in 0..<150 {
                guard isRestoreRunning else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return !hasActiveOperation && !requiresProtectedCleanupReview
        } else if isMeasuring {
            await cancelMeasurement()
        } else {
            await workflow.cancel()
        }
        for _ in 0..<150 {
            guard await workflow.isRunning || hasActiveOperation else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let workflowReachedSafeTerminalState = !wasWorkflowRunning || {
            guard let state = workflowSession?.state else { return true }
            return Self.isTerminalSessionState(state) && state != .interrupted
        }()
        return !(await workflow.isRunning)
            && !hasActiveOperation
            && !requiresProtectedCleanupReview
            && workflowReachedSafeTerminalState
    }

    func handleSystemWillSleep() async {
        guard hasActiveOperation else { return }
        if isRestoreRunning {
            statusMessage = "Mac sleep detected — Restore Before will resume when the Mac wakes."
            return
        }
        statusMessage = "Mac sleep detected — cancellation requested; recovery will continue after wake."
        if isMeasuring {
            await cancelMeasurement()
        } else {
            await workflow.cancel()
        }
    }

    func handleSystemDidWake() async {
        guard hasActiveOperation else { return }
        if isRestoreRunning {
            statusMessage = "Mac woke — finishing Restore Before…"
            return
        }
        statusMessage = "Mac woke — finishing safe cancellation…"
        if isMeasuring {
            await cancelMeasurement()
        } else {
            await workflow.cancel()
        }
    }

    func beginAnotherCalibration() {
        workflowSession = nil
        workflowDirectory = nil
        requiredAction = nil
        logs = []
        preCalibrationMeasurement = nil
        statusMessage = "Ready"
        setupStep = .hardware
    }

    func prepareRetry(effort: CalibrationEffort) {
        calibrationEffort = effort
        beginAnotherCalibration()
    }

    var isComparingBefore: Bool { comparisonBeforeSessionID != nil }

    func canCompare(_ session: CalibrationSession) -> Bool {
        session.installation?.activationStatus == .active
            && session.display != nil
            && installer is any ProfileComparisonSwitching
            && hasFinishedInitialRecoveryAudit
            && !requiresProtectedCleanupReview
            && !hasActiveOperation
            && !isRefreshing
    }

    /// Temporarily shows the session's Before or After profile on its display.
    /// The session stays recorded as activated; After is put back before any
    /// other profile-changing operation and before quitting.
    func setComparison(showBefore: Bool, for session: CalibrationSession) async {
        guard canCompare(session), !isSwitchingComparison,
              let record = session.installation,
              let display = session.display,
              let switcher = installer as? any ProfileComparisonSwitching else { return }
        if showBefore, let active = comparisonBeforeSessionID, active != session.id {
            await restoreAfterIfComparing()
        }
        isSwitchingComparison = true
        defer { isSwitchingComparison = false }
        do {
            try await switcher.showComparison(showBefore ? .before : .after, record: record, for: display)
            if showBefore {
                comparisonBeforeSessionID = session.id
                comparisonContext = (record, display)
            } else {
                comparisonBeforeSessionID = nil
                comparisonContext = nil
            }
        } catch {
            present(error, title: "Comparison not switched")
        }
    }

    /// Puts After back if a comparison left Before showing. The comparison is
    /// always considered ended afterwards so a failure cannot trap the app.
    func restoreAfterIfComparing() async {
        guard let context = comparisonContext,
              let switcher = installer as? any ProfileComparisonSwitching else {
            comparisonBeforeSessionID = nil
            comparisonContext = nil
            return
        }
        isSwitchingComparison = true
        defer { isSwitchingComparison = false }
        do {
            try await switcher.showComparison(.after, record: context.record, for: context.display)
        } catch {
            present(error, title: "After profile not restored after comparison")
        }
        comparisonBeforeSessionID = nil
        comparisonContext = nil
    }

    func rollback(_ session: CalibrationSession) async {
        await restoreAfterIfComparing()
        guard !hasActiveOperation, !isRefreshing, !isRefreshingInstruments else {
            alert = AppAlert(
                title: "Another operation is active",
                message: "Wait for the current measurement, calibration, activation, or Restore Before operation to finish."
            )
            return
        }
        // Restoration is not considered safe until the workflow confirms it.
        protectedCleanupSessionIDs.insert(session.id)
        isRestoreRunning = true
        statusMessage = "Restoring the Before profile…"
        beginWorkflowActivity(reason: "Restoring the previous display profile")
        let workflow = self.workflow
        let task = Task { try await workflow.restoreBefore(session: session) }
        restoreTask = task
        defer {
            restoreTask = nil
            isRestoreRunning = false
            endWorkflowActivity()
        }
        do {
            workflowSession = try await task.value
            protectedCleanupSessionIDs.remove(session.id)
            statusMessage = "Before profile restored"
            do {
                try await reloadSessions()
            } catch {
                present(error, title: "History not refreshed")
            }
        } catch is CancellationError {
            protectedCleanupSessionIDs.insert(session.id)
            alert = AppAlert(
                title: "Restore Before still needs review",
                message: "The restoration task was interrupted. Reopen the session and confirm the active profile before continuing."
            )
            try? await reloadSessions()
        } catch {
            protectedCleanupSessionIDs.insert(session.id)
            statusMessage = "Restore Before failed: \(error.localizedDescription)"
            present(error, title: "Restore Before failed")
            try? await reloadSessions()
        }
    }

    func saveSettingsAndReloadEngine() async {
        guard !hasActiveOperation, !isRefreshing, !isRefreshingInstruments else {
            alert = AppAlert(
                title: "Settings locked during an active operation",
                message: "Finish or safely cancel the current operation before changing or reloading the calibration engine."
            )
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        defaults.set(measurementMode.rawValue, forKey: "measurementMode")
        defaults.set(explicitEnginePath, forKey: "engineDirectory")
        quickMeasurement = nil
        preCalibrationMeasurement = nil

        let url = explicitEnginePath.isEmpty ? nil : URL(fileURLWithPath: explicitEnginePath, isDirectory: true)
        engine = engineFactory(url)
        workflow = CalibrationWorkflow(engine: engine, installer: installer, store: sessionStore)
        engineProbe = await engine.probe()
        await performInstrumentRefresh()
    }

    func removeCorrection(_ correction: DisplayCorrection) async {
        guard !hasActiveOperation, !isRefreshing, !isRefreshingInstruments else {
            alert = AppAlert(
                title: "Correction is in use",
                message: "Finish or safely cancel the current operation before removing a display correction."
            )
            return
        }
        do {
            try await correctionLibrary.remove(correction)
            if selectedCorrectionID == correction.id {
                selectedCorrectionID = nil
                correctionCompatibilityConfirmed = false
            }
            corrections = try await correctionLibrary.list()
        } catch {
            present(error, title: "Correction not removed")
        }
    }

    func deleteSession(_ session: CalibrationSession) async {
        guard !hasActiveOperation else { return }
        guard session.state != .interrupted,
              session.activationVerificationAttempt?.status != .inProgress,
              session.installation == nil else {
            alert = AppAlert(
                title: "Session retained for safety",
                message: "This session may still be needed to identify or restore a display profile. Restore Before, or finish the active operation, before deleting its record."
            )
            return
        }
        do {
            try await sessionStore.remove(id: session.id)
            if workflowSession?.id == session.id { beginAnotherCalibration() }
            try await reloadSessions()
        } catch {
            present(error, title: "Session not deleted")
        }
    }

    func revealSession(_ session: CalibrationSession) async {
        let directory = await sessionStore.sessionDirectory(for: session.id)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func revealLocalData() async {
        let root = await sessionStore.rootDirectory.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func exportReport(for session: CalibrationSession) {
        let panel = NSSavePanel()
        panel.title = "Export Calibration Report"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = reportFilename(for: session)

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        do {
            let report = calibrationReport(for: session)
            guard let data = report.data(using: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            try data.write(to: outputURL, options: .atomic)
            alert = AppAlert(
                title: "Report exported",
                message: "The plain-text report includes calibration results and artifact filenames, without raw logs or absolute home-folder paths."
            )
        } catch {
            present(error, title: "Report not exported")
        }
    }

    func copyDiagnostics(for session: CalibrationSession? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func sanitized(_ value: String) -> String {
            value.replacingOccurrences(of: home, with: "~")
        }

        var lines = [
            "LumaProfile diagnostics",
            "App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "source build")",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Engine: \(engineProbe.version ?? "unavailable")",
            "Engine status: \(sanitized(engineProbe.diagnostic))",
            "Displays detected: \(displays.count)",
            "Supported meters detected: \(instruments.count)",
        ]
        if let session {
            lines.append(contentsOf: [
                "Session: \(session.id.uuidString)",
                "Session state: \(session.state.rawValue)",
                "Display: \(session.display?.name ?? "not recorded")",
                "Meter: \(session.instrument?.model ?? "not recorded")",
                "Target: \(session.target?.name ?? "not recorded")",
                "Updated: \(session.updatedAt.formatted(.iso8601))",
                "Failure: \(sanitized(session.failureMessage ?? "none"))",
                "Artifacts: \(session.artifacts.map { $0.url.lastPathComponent }.joined(separator: ", "))",
            ])
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        alert = AppAlert(title: "Diagnostics copied", message: "A privacy-reduced diagnostic summary is on the clipboard. It omits raw measurements and replaces your home-folder path with ~.")
    }

    private func calibrationReport(for session: CalibrationSession) -> String {
        var lines: [String] = [
            "LumaProfile Calibration Report",
            "Exported: \(reportDate(Date()))",
            "Session: \(session.id.uuidString)",
            "",
            "SUMMARY",
            "Display: \(reportValue(session.display?.name ?? "Not recorded"))",
            "Meter: \(reportValue(session.instrument?.model ?? "Not recorded"))",
            "Target: \(reportValue(session.target?.name ?? "Not recorded"))",
            "Target details: \(targetDescription(session.target))",
            "Measurement effort: \(session.characterizationPreset?.rawValue ?? "Not recorded")",
            "Characterization patches: \(patchCountDescription(session))",
            "Profile model: \(session.profileModel?.rawValue ?? "Not recorded")",
            "Correction: \(reportValue(session.correction?.name ?? "Meter default"))",
            "Session record: \(session.state.rawValue.capitalized)",
        ]

        if let generatedAt = session.profileGenerationCompletedAt {
            lines.append("Generated candidate: Complete — \(reportDate(generatedAt))")
        } else if session.artifacts.contains(where: {
            $0.isComplete && ["icc", "icm"].contains($0.url.pathExtension.lowercased())
        }) {
            lines.append("Generated candidate: Complete — completion time was not recorded by this historical session")
        } else {
            lines.append("Generated candidate: Not completed")
        }
        if let failure = session.failureMessage, !failure.isEmpty {
            lines.append("Session note: \(reportValue(failure))")
        }

        lines.append(contentsOf: [
            "",
            "BEFORE — SETUP",
            "Profile active at start: \(profileFilename(session.profileBaseline?.activeProfileURL))",
        ])
        if let measurement = session.setupMeasurement {
            lines.append(contentsOf: measurementLines(measurement))
        } else {
            lines.append("White setup reading: Not captured")
        }

        lines.append(contentsOf: ["", "AFTER — ACTIVATION AND VERIFICATION"])
        lines.append(contentsOf: activationOutcomeLines(session))
        if let report = session.verification {
            lines.append(contentsOf: verificationLines(
                report,
                assessment: session.verificationAssessment
            ))
        } else {
            lines.append("Verification: No completed After measurement")
        }

        lines.append(contentsOf: ["", "ARTIFACTS"])
        if session.artifacts.isEmpty {
            lines.append("No artifacts recorded")
        } else {
            for artifact in session.artifacts {
                let completeness = artifact.isComplete ? "complete" : "incomplete"
                lines.append(
                    "- \(reportValue(artifact.kind)): \(reportValue(artifact.url.lastPathComponent)) (\(completeness))"
                )
            }
        }

        lines.append(contentsOf: [
            "",
            "PRIVACY",
            "This report omits raw calibration logs, raw ArgyllCMS output, meter serial numbers, file hashes, and absolute home-folder paths.",
            "Artifact entries contain filenames only.",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    private func activationOutcomeLines(_ session: CalibrationSession) -> [String] {
        guard let attempt = session.activationVerificationAttempt else {
            if session.verification != nil {
                let activeState = session.installation == nil
                    ? "Current profile state was not recorded in the newer outcome format."
                    : "A generated candidate is recorded as installed."
                return [
                    "Activation: Completed by a historical LumaProfile version",
                    "Outcome: Verification data is available. \(activeState)",
                ]
            }
            if let installation = session.installation {
                return [
                    "Activation: Recorded by a historical LumaProfile version",
                    "Currently installed candidate: \(profileFilename(installation.installedProfileURL))",
                    "Outcome: Detailed verification and restoration status was not recorded.",
                ]
            }
            return [
                "Activation: Not attempted",
                "Outcome: The generated candidate remained inactive; the Before profile was left in use.",
            ]
        }

        var lines = ["Attempt started: \(reportDate(attempt.startedAt))"]
        if let activatedAt = attempt.profileActivatedAt {
            lines.append("After profile activated: \(reportDate(activatedAt))")
        }
        if let verificationStartedAt = attempt.verificationStartedAt {
            lines.append("Verification started: \(reportDate(verificationStartedAt))")
        }
        if let finishedAt = attempt.finishedAt {
            lines.append("Attempt finished: \(reportDate(finishedAt))")
        }

        let outcome: String
        switch attempt.status {
        case .inProgress:
            outcome = "Incomplete — no durable terminal activation result was recorded."
        case .verified:
            if attempt.restoredBeforeProfile == true {
                outcome = "Verified successfully; the Before profile was later restored."
            } else {
                outcome = "Verified successfully; the generated After profile remains active."
            }
        case .failed:
            if attempt.restoredBeforeProfile == true {
                outcome = "Failed; the Before profile was restored and the generated candidate remains inactive."
            } else if attempt.restoredBeforeProfile == false {
                outcome = "Failed; restoration was not confirmed. Recovery may still be required."
            } else {
                outcome = "Failed; the active-profile outcome could not be confirmed."
            }
        case .cancelled:
            if attempt.restoredBeforeProfile == true {
                outcome = "Cancelled; the Before profile was restored and the generated candidate remains inactive."
            } else if attempt.restoredBeforeProfile == false {
                outcome = "Cancelled; restoration was not confirmed. Recovery may still be required."
            } else {
                outcome = "Cancelled; the active-profile outcome could not be confirmed."
            }
        }
        lines.append("Outcome: \(outcome)")
        if let restoredAt = attempt.restoredBeforeProfileAt {
            lines.append("Before profile restored: Yes — \(reportDate(restoredAt))")
        } else if let restored = attempt.restoredBeforeProfile {
            lines.append("Before profile restored: \(restored ? "Yes" : "No")")
        } else {
            lines.append("Before profile restored: Unconfirmed")
        }
        if let installation = session.installation {
            lines.append("Currently installed candidate: \(profileFilename(installation.installedProfileURL))")
        }
        if let error = attempt.errorMessage, !error.isEmpty {
            lines.append("Attempt note: \(reportValue(error))")
        }
        return lines
    }

    private func verificationLines(
        _ report: VerificationReport,
        assessment: VerificationAssessment?
    ) -> [String] {
        let metrics = report.metrics
        var lines = [
            "Verification measured: \(reportDate(report.measuredAt))",
            "Average ΔE2000: \(reportNumber(metrics.averageDeltaE2000))",
            "95th-percentile ΔE2000: \(reportNumber(metrics.percentile95DeltaE2000))",
            "Maximum ΔE2000: \(reportNumber(metrics.maximumDeltaE2000))",
            "White-point ΔE2000: \(reportNumber(metrics.whitePointDeltaE2000))",
            "Measured white xy: \(reportNumber(metrics.measuredWhite.x, places: 4)), \(reportNumber(metrics.measuredWhite.y, places: 4))",
            "Luminance: \(reportNumber(metrics.luminanceCDM2)) cd/m²",
        ]
        if let black = metrics.blackLevelCDM2 {
            lines.append("Black level: \(reportNumber(black, places: 3)) cd/m²")
        }
        if let contrast = metrics.contrastRatio {
            lines.append("Contrast ratio: \(reportNumber(contrast, places: 0)):1")
        }
        if let temperature = metrics.measuredCorrelatedColorTemperature {
            lines.append("Correlated color temperature: \(reportNumber(temperature, places: 0)) K")
        }
        if let gamma = metrics.measuredGamma {
            lines.append("Measured gamma: \(reportNumber(gamma))")
        }
        if let gammaRMS = metrics.gammaRMSError {
            lines.append("Gamma fit RMS error: \(reportNumber(gammaRMS, places: 3))")
        }
        if let toneRMS = metrics.toneResponseRMSError {
            lines.append("Tone-response RMS error: \(reportNumber(toneRMS, places: 3))")
        }

        if let assessment {
            let criteria = assessment.criteria
            lines.append("Overall rating: \(assessment.rating.rawValue)")
            lines.append("Rating criteria version: \(assessment.criteriaVersion)")
            lines.append(
                "Rating thresholds: Excellent average/max ΔE2000 below \(reportNumber(criteria.excellentAverageDeltaE))/\(reportNumber(criteria.excellentMaximumDeltaE)); Good below \(reportNumber(criteria.goodAverageDeltaE))/\(reportNumber(criteria.goodMaximumDeltaE)); white-point ΔE2000 at most \(reportNumber(criteria.maximumWhitePointDeltaE)); luminance within \(reportNumber(criteria.maximumLuminanceErrorPercent))%; gamma within \(reportNumber(criteria.maximumGammaError))."
            )
            lines.append("Rating reasons:")
            lines.append(contentsOf: assessment.reasons.map { "- \(reportValue($0))" })
        } else {
            lines.append("Overall rating: Not available for this historical session")
        }
        if !metrics.warnings.isEmpty {
            lines.append("Verification notes:")
            lines.append(contentsOf: metrics.warnings.map { "- \(reportValue($0))" })
        }
        return lines
    }

    private func measurementLines(_ measurement: LumaCore.Measurement) -> [String] {
        var lines = [
            "White setup reading: \(reportDate(measurement.capturedAt))",
            "Luminance: \(reportNumber(measurement.luminanceCDM2)) cd/m²",
            "White xy: \(reportNumber(measurement.chromaticity.x, places: 4)), \(reportNumber(measurement.chromaticity.y, places: 4))",
        ]
        if let temperature = measurement.correlatedColorTemperature {
            lines.append("Correlated color temperature: \(reportNumber(temperature, places: 0)) K")
        }
        if !measurement.warnings.isEmpty {
            lines.append("Setup reading notes:")
            lines.append(contentsOf: measurement.warnings.map { "- \(reportValue($0))" })
        }
        return lines
    }

    private func targetDescription(_ target: CalibrationTarget?) -> String {
        guard let target else { return "Not recorded" }
        let white: String
        switch target.whitePoint {
        case .d65: white = "D65"
        case .native: white = "Native white"
        case .temperature(let kelvin): white = "\(reportNumber(kelvin, places: 0)) K"
        case .chromaticity(let value):
            white = "x \(reportNumber(value.x, places: 4)), y \(reportNumber(value.y, places: 4))"
        }
        let luminance = target.luminanceCDM2.map { "\(reportNumber($0)) cd/m²" } ?? "Native luminance"
        let transfer: String
        switch target.transferFunction {
        case .gamma(let value): transfer = "Gamma \(reportNumber(value, places: 1))"
        case .sRGB: transfer = "sRGB TRC"
        case .bt1886: transfer = "BT.1886"
        }
        return "\(white); \(luminance); \(transfer)"
    }

    private func patchCountDescription(_ session: CalibrationSession) -> String {
        guard let planned = session.plannedCharacterizationPatchCount else { return "Not recorded" }
        guard let actual = session.actualCharacterizationPatchCount else { return "\(planned) planned" }
        return actual == planned ? "\(actual)" : "\(actual) measured (\(planned) planned)"
    }

    private func profileFilename(_ url: URL?) -> String {
        guard let url else { return "None recorded" }
        return reportValue(url.lastPathComponent)
    }

    private func reportDate(_ date: Date) -> String {
        date.formatted(date: .long, time: .standard)
    }

    private func reportNumber(_ value: Double, places: Int = 2) -> String {
        guard value.isFinite else { return "Unavailable" }
        return String(format: "%.*f", places, value)
    }

    private func reportValue(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return value
            .replacingOccurrences(of: home, with: "<home>")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private func reportFilename(for session: CalibrationSession) -> String {
        let displayName = session.display?.name ?? "Display"
        let safeDisplay = displayName.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        return "LumaProfile-\(safeDisplay)-\(date.string(from: session.updatedAt)).txt"
    }

    private func apply(_ update: CalibrationWorkflowUpdate) {
        switch update {
        case .sessionCreated(let session, let directory):
            workflowSession = session
            workflowDirectory = directory
        case .sessionUpdated(let session):
            workflowSession = session
            if session.state == .interrupted {
                // Only an explicit successful Restore Before clears this latch.
                // Unrelated work must never erase an unresolved profile-state warning.
                protectedCleanupSessionIDs.insert(session.id)
            }
        case .event(let event):
            switch event {
            case .stageChanged(let stage):
                statusMessage = stage.displayName
                if stage != .awaitingMeterPlacement { requiredAction = nil }
            case .message(let message):
                statusMessage = message
                logs.append(LogRecord(level: "Info", message: message))
            case .measurement(let measurement):
                logs.append(LogRecord(level: "Measurement", message: String(format: "%.1f cd/m²", measurement.luminanceCDM2)))
            case .progress(let completed, let total):
                progressCompleted = completed
                progressTotal = total
            case .userActionRequired(let action):
                requiredAction = action
                statusMessage = "Waiting for your confirmation…"
            case .artifactCreated(let artifact):
                logs.append(LogRecord(level: "Artifact", message: artifact.kind))
            case .verificationCompleted(let report):
                logs.append(LogRecord(level: "Verification", message: String(format: "Average ΔE00 %.2f", report.metrics.averageDeltaE2000)))
            case .warning(let warning):
                logs.append(LogRecord(level: "Warning", message: warning))
            case .technicalLog(let record):
                logs.append(record)
            }
        }
    }

    private func reloadSessions() async throws {
        let listing = try await sessionStore.listing()
        sessions = listing.sessions
        sessionLoadIssues = listing.issues
        // A malformed UUID-named session directory may contain an activation
        // recovery record we cannot decode. Keep all profile-changing actions
        // fail-closed until the operator repairs/removes it and reloads.
        hasUnresolvedSessionLoadIssues = !listing.issues.isEmpty
        protectedCleanupSessionIDs.formUnion(
            listing.sessions.lazy
                .filter(Self.sessionRequiresProtectedCleanup)
                .map(\.id)
        )
    }

    private static func sessionRequiresProtectedCleanup(_ session: CalibrationSession) -> Bool {
        if session.state == .interrupted { return true }
        if !isTerminalSessionState(session.state) { return true }
        if let status = session.installation?.activationStatus,
           status == .activationPending || status == .restorationRequired {
            return true
        }
        guard let attempt = session.activationVerificationAttempt else { return false }
        if attempt.status == .inProgress {
            return session.installation != nil || attempt.profileActivatedAt != nil
        }
        return (attempt.status == .failed || attempt.status == .cancelled)
            && attempt.restoredBeforeProfile != true
            && session.installation != nil
    }

    private func preserveOrSelectDisplay() {
        guard !displays.contains(where: { $0.id == selectedDisplayID }) else { return }
        selectedDisplayID = displays.first(where: \.isMain)?.id ?? displays.first?.id
        selectedDisplayChanged()
    }

    private func rememberedSetups() -> [String: RememberedDisplaySetup] {
        guard let data = defaults.data(forKey: Self.rememberedSetupsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: RememberedDisplaySetup].self, from: data)) ?? [:]
    }

    private func rememberedSetup() -> RememberedDisplaySetup? {
        guard let fingerprint = selectedDisplay?.fingerprint else { return nil }
        return rememberedSetups()[fingerprint]
    }

    private func restoreRememberedSetup() {
        displayMappingConfirmed = false
        displayIdentified = false
        correctionCompatibilityConfirmed = false
        quickMeasurement = nil
        preCalibrationMeasurement = nil

        guard let remembered = rememberedSetup() else {
            if !instruments.contains(where: { $0.id == selectedInstrumentID }) {
                selectedInstrumentID = nil
            }
            if !corrections.contains(where: { $0.id == selectedCorrectionID }) {
                selectedCorrectionID = nil
            }
            if let index = Int(displayNumber),
               engineDisplays.contains(where: { $0.index == index }) {
                // Keep the candidate number, but require identification and
                // confirmation again after every hardware refresh.
            } else {
                displayNumber = ""
            }
            return
        }
        targetChoice = remembered.targetChoice
        calibrationEffort = remembered.calibrationEffort
        profileModel = remembered.profileModel
        customWhitePoint = remembered.customWhitePoint ?? .d65
        customTemperature = remembered.customTemperature ?? 6_500
        customChromaticityX = remembered.customChromaticityX ?? 0.3127
        customChromaticityY = remembered.customChromaticityY ?? 0.3290
        customLuminanceEnabled = remembered.customLuminanceEnabled ?? true
        customLuminance = remembered.customLuminance ?? 120
        customTransfer = remembered.customTransfer ?? .gamma
        customGamma = remembered.customGamma ?? 2.2
        customBlackPoint = remembered.customBlackPoint ?? .native
        customPatchWidth = remembered.customPatchWidth ?? 0.25
        customPatchHeight = remembered.customPatchHeight ?? 0.25
        customPatchHorizontalPosition = remembered.customPatchHorizontalPosition ?? 0.5
        customPatchVerticalPosition = remembered.customPatchVerticalPosition ?? 0.5

        selectedInstrumentID = remembered.instrumentID.flatMap { rememberedID in
            instruments.first(where: { $0.id == rememberedID })?.id
        }
        selectedCorrectionID = remembered.correctionID.flatMap { rememberedID in
            corrections.first(where: { $0.id == rememberedID })?.id
        }
        displayNumber = ""
        if let index = remembered.engineDisplayIndex,
           let descriptor = engineDisplays.first(where: { $0.index == index }),
           remembered.engineDisplayDescription == nil
               || descriptor.description == remembered.engineDisplayDescription {
            displayNumber = String(index)
        }
    }

    private func saveRememberedSetup(display: PhysicalDisplay, instrument: InstrumentDescriptor) {
        var remembered = rememberedSetups()
        remembered[display.fingerprint] = RememberedDisplaySetup(
            engineDisplayIndex: display.argyllDisplayIndex,
            engineDisplayDescription: display.argyllDisplayDescription,
            instrumentID: instrument.id,
            correctionID: selectedCorrectionID,
            targetChoice: targetChoice,
            calibrationEffort: calibrationEffort,
            profileModel: profileModel,
            customWhitePoint: customWhitePoint,
            customTemperature: customTemperature,
            customChromaticityX: customChromaticityX,
            customChromaticityY: customChromaticityY,
            customLuminanceEnabled: customLuminanceEnabled,
            customLuminance: customLuminance,
            customTransfer: customTransfer,
            customGamma: customGamma,
            customBlackPoint: customBlackPoint,
            customPatchWidth: customPatchWidth,
            customPatchHeight: customPatchHeight,
            customPatchHorizontalPosition: customPatchHorizontalPosition,
            customPatchVerticalPosition: customPatchVerticalPosition
        )
        guard let data = try? JSONEncoder().encode(remembered) else { return }
        defaults.set(data, forKey: Self.rememberedSetupsKey)
    }

    private func suggestDisplayMapping() {
        guard displayNumber.isEmpty, let display = selectedDisplay else { return }

        if let knownIndex = display.argyllDisplayIndex,
           engineDisplays.contains(where: { $0.index == knownIndex }) {
            displayNumber = String(knownIndex)
            return
        }
        if displays.count == 1, engineDisplays.count == 1, let only = engineDisplays.first {
            displayNumber = String(only.index)
            return
        }

        // The engine lists each display by its product name, so a single name
        // match is unambiguous. This is only a suggestion: identification and
        // explicit confirmation are still required before any measurement.
        let named = engineDisplays.filter {
            $0.description.localizedCaseInsensitiveContains(display.name)
        }
        if named.count == 1, let match = named.first {
            displayNumber = String(match.index)
            return
        }

        let resolution = "\(display.widthPixels)x\(display.heightPixels)"
        let matches = engineDisplays.filter {
            Self.normalized($0.description).contains(resolution)
        }
        if matches.count == 1, let match = matches.first {
            displayNumber = String(match.index)
        }
    }

    private func requireSelectedInstrumentConnection(_ instrument: InstrumentDescriptor) async throws {
        let available = try await engine.discoverInstruments().filter(\.isI1D3Family)
        let isStillConnected = available.contains { candidate in
            candidate.id == instrument.id
                || (candidate.serialNumber != nil
                    && candidate.serialNumber == instrument.serialNumber
                    && Self.namesOverlap(candidate.model, instrument.model))
        }
        guard isStillConnected else { throw AppModelHardwareError.meterDisconnected(instrument.model) }
    }

    private func beginWorkflowActivity(reason: String) {
        guard workflowActivity == nil else { return }
        workflowActivity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleSystemSleepDisabled,
                .idleDisplaySleepDisabled,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled,
            ],
            reason: reason
        )
    }

    private func endWorkflowActivity() {
        guard let workflowActivity else { return }
        ProcessInfo.processInfo.endActivity(workflowActivity)
        self.workflowActivity = nil
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func namesOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return true }
        return left.contains(right) || right.contains(left)
    }

    private static func isTerminalSessionState(_ state: WorkflowStage) -> Bool {
        switch state {
        case .idle, .completed, .failed, .cancelled, .interrupted:
            true
        default:
            false
        }
    }

    private func present(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }
}

private extension WorkflowStage {
    var displayName: String {
        switch self {
        case .idle: "Ready"
        case .preflighting: "Checking setup"
        case .awaitingMeterPlacement: "Waiting for meter placement"
        case .adjustingDisplay: "Adjusting display"
        case .calibrating: "Calibrating tone response"
        case .generatingPatchSet: "Preparing color patches"
        case .characterizing: "Measuring display color"
        case .buildingProfile: "Building ICC profile"
        case .installingProfile: "Installing and activating profile"
        case .verifying: "Verifying result"
        case .completed: "Calibration complete"
        case .cancelling: "Cancelling safely"
        case .cancelled: "Calibration cancelled"
        case .failed: "Calibration failed"
        case .interrupted: "Calibration interrupted"
        }
    }
}
