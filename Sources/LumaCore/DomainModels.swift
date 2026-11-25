import Foundation

public struct XYZColor: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct Chromaticity: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let d65 = Chromaticity(x: 0.3127, y: 0.3290)
}

public struct Measurement: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var xyz: XYZColor
    public var chromaticity: Chromaticity
    public var luminanceCDM2: Double
    public var correlatedColorTemperature: Double?
    public var rgbBalance: [Double]?
    public var capturedAt: Date
    public var warnings: [String]
    public var rawSource: String

    public init(
        id: UUID = UUID(),
        xyz: XYZColor,
        chromaticity: Chromaticity,
        luminanceCDM2: Double,
        correlatedColorTemperature: Double? = nil,
        rgbBalance: [Double]? = nil,
        capturedAt: Date = Date(),
        warnings: [String] = [],
        rawSource: String
    ) {
        self.id = id
        self.xyz = xyz
        self.chromaticity = chromaticity
        self.luminanceCDM2 = luminanceCDM2
        self.correlatedColorTemperature = correlatedColorTemperature
        self.rgbBalance = rgbBalance
        self.capturedAt = capturedAt
        self.warnings = warnings
        self.rawSource = rawSource
    }
}

public struct PhysicalDisplay: Codable, Hashable, Sendable, Identifiable {
    public var id: String { fingerprint }
    public var fingerprint: String
    public var cgDisplayID: UInt32
    public var name: String
    public var widthPixels: Int
    public var heightPixels: Int
    public var scale: Double
    public var isMain: Bool
    public var isMirrored: Bool
    public var isVirtual: Bool
    public var argyllDisplayIndex: Int?
    public var argyllDisplayDescription: String?
    public var userReportedMode: String?

    public init(
        fingerprint: String,
        cgDisplayID: UInt32,
        name: String,
        widthPixels: Int,
        heightPixels: Int,
        scale: Double,
        isMain: Bool,
        isMirrored: Bool,
        isVirtual: Bool,
        argyllDisplayIndex: Int? = nil,
        argyllDisplayDescription: String? = nil,
        userReportedMode: String? = nil
    ) {
        self.fingerprint = fingerprint
        self.cgDisplayID = cgDisplayID
        self.name = name
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.scale = scale
        self.isMain = isMain
        self.isMirrored = isMirrored
        self.isVirtual = isVirtual
        self.argyllDisplayIndex = argyllDisplayIndex
        self.argyllDisplayDescription = argyllDisplayDescription
        self.userReportedMode = userReportedMode
    }
}

public struct InstrumentDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var model: String
    public var serialNumber: String?
    public var capabilities: [String]
    public var isI1D3Family: Bool
    public var status: String

    public init(
        id: String,
        model: String,
        serialNumber: String? = nil,
        capabilities: [String] = [],
        isI1D3Family: Bool,
        status: String
    ) {
        self.id = id
        self.model = model
        self.serialNumber = serialNumber
        self.capabilities = capabilities
        self.isI1D3Family = isI1D3Family
        self.status = status
    }
}

public enum CorrectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ccss
    case ccmx
}

public struct DisplayCorrection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: CorrectionKind
    public var name: String
    public var sourceURL: URL
    public var importedURL: URL
    public var sha256: String
    public var importedAt: Date
    public var declaredDisplay: String?
    public var declaredInstrument: String?
    public var provenance: String

    public init(
        id: UUID = UUID(),
        kind: CorrectionKind,
        name: String,
        sourceURL: URL,
        importedURL: URL,
        sha256: String,
        importedAt: Date = Date(),
        declaredDisplay: String? = nil,
        declaredInstrument: String? = nil,
        provenance: String
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sourceURL = sourceURL
        self.importedURL = importedURL
        self.sha256 = sha256
        self.importedAt = importedAt
        self.declaredDisplay = declaredDisplay
        self.declaredInstrument = declaredInstrument
        self.provenance = provenance
    }
}

public enum WhitePointTarget: Codable, Hashable, Sendable {
    case d65
    case native
    case temperature(kelvin: Double)
    case chromaticity(Chromaticity)
}

public enum TransferFunction: Codable, Hashable, Sendable {
    case gamma(Double)
    case sRGB
    case bt1886
}

public enum BlackPointMode: String, Codable, CaseIterable, Hashable, Sendable {
    case native
    case optimize
}

public enum CalibrationQuality: String, Codable, CaseIterable, Hashable, Sendable {
    case quick = "Quick"
    case medium = "Standard"
    case high = "High"
}

public struct PatchGeometry: Codable, Hashable, Sendable {
    public var widthFraction: Double
    public var heightFraction: Double
    public var horizontalPosition: Double
    public var verticalPosition: Double

    public init(
        widthFraction: Double = 0.25,
        heightFraction: Double = 0.25,
        horizontalPosition: Double = 0.5,
        verticalPosition: Double = 0.5
    ) {
        self.widthFraction = widthFraction
        self.heightFraction = heightFraction
        self.horizontalPosition = horizontalPosition
        self.verticalPosition = verticalPosition
    }
}

public struct CalibrationTarget: Codable, Hashable, Sendable {
    public var name: String
    public var whitePoint: WhitePointTarget
    public var luminanceCDM2: Double?
    public var transferFunction: TransferFunction
    public var blackPointMode: BlackPointMode
    public var quality: CalibrationQuality
    public var correctionID: UUID?
    public var patchGeometry: PatchGeometry
    public var displayModeNote: String?

    public init(
        name: String,
        whitePoint: WhitePointTarget,
        luminanceCDM2: Double?,
        transferFunction: TransferFunction,
        blackPointMode: BlackPointMode = .native,
        quality: CalibrationQuality = .medium,
        correctionID: UUID? = nil,
        patchGeometry: PatchGeometry = PatchGeometry(),
        displayModeNote: String? = nil
    ) {
        self.name = name
        self.whitePoint = whitePoint
        self.luminanceCDM2 = luminanceCDM2
        self.transferFunction = transferFunction
        self.blackPointMode = blackPointMode
        self.quality = quality
        self.correctionID = correctionID
        self.patchGeometry = patchGeometry
        self.displayModeNote = displayModeNote
    }

    public static let photography = CalibrationTarget(
        name: "sRGB / D65 / 120 / Gamma 2.2",
        whitePoint: .d65,
        luminanceCDM2: 120,
        transferFunction: .gamma(2.2)
    )
    public static let webSRGB = CalibrationTarget(
        name: "sRGB / D65 / 120 / sRGB TRC",
        whitePoint: .d65,
        luminanceCDM2: 120,
        transferFunction: .sRGB
    )
    public static let videoGamma24 = CalibrationTarget(
        name: "Rec.709 / D65 / 100 / Gamma 2.4",
        whitePoint: .d65,
        luminanceCDM2: 100,
        transferFunction: .gamma(2.4),
        displayModeNote: "This target does not clamp the monitor's native gamut."
    )
    public static let videoBT1886 = CalibrationTarget(
        name: "Rec.709 / D65 / 100 / BT.1886-style",
        whitePoint: .d65,
        luminanceCDM2: 100,
        transferFunction: .bt1886,
        blackPointMode: .optimize,
        displayModeNote: "This target does not clamp the monitor's native gamut."
    )
    public static let presets = [photography, webSRGB, videoGamma24, videoBT1886]
}

public enum CharacterizationPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case fast = "Fast"
    case standard = "Standard"
    case high = "High"
    case reference = "Reference"

    public var requestedPatchCount: Int {
        switch self {
        case .fast: 119
        case .standard: 220
        case .high: 478
        case .reference: 1_024
        }
    }
}

public enum CalibrationEffort: String, Codable, CaseIterable, Hashable, Sendable {
    case quick = "Quick"
    case balanced = "Balanced"
    case detailed = "Detailed"
    case reference = "Reference"

    public var calibrationQuality: CalibrationQuality {
        switch self {
        case .quick: .quick
        case .balanced: .medium
        case .detailed, .reference: .high
        }
    }

    public var characterizationPreset: CharacterizationPreset {
        switch self {
        case .quick: .fast
        case .balanced: .standard
        case .detailed: .high
        case .reference: .reference
        }
    }

    public var characterizationPatchCount: Int {
        characterizationPreset.requestedPatchCount
    }

    public var detail: String {
        switch self {
        case .quick:
            "Shortest run. Fewer patches and lighter refinement trade some profile detail for speed."
        case .balanced:
            "Recommended for most displays: broader sampling with standard calibration refinement."
        case .detailed:
            "A longer run with more color patches and higher refinement for more profile detail."
        case .reference:
            "Expert option. The longest run, intended for demanding work rather than routine calibration."
        }
    }

    public static func matching(
        calibrationQuality: CalibrationQuality,
        characterizationPreset: CharacterizationPreset
    ) -> CalibrationEffort? {
        allCases.first {
            $0.calibrationQuality == calibrationQuality
                && $0.characterizationPreset == characterizationPreset
        }
    }
}

public enum ProfileModel: String, Codable, CaseIterable, Hashable, Sendable {
    case matrix = "Matrix"
    case shaperMatrix = "Shaper + Matrix"
    case lut = "LUT / Table"
}

public enum MeasurementMode: String, Codable, CaseIterable, Hashable, Sendable {
    case auto = "Auto"
    case refresh = "Refresh"
    case nonRefresh = "Non-refresh"
}

public struct SpotMeasurementRequest: Sendable {
    public var instrument: InstrumentDescriptor
    public var display: PhysicalDisplay?
    public var correction: DisplayCorrection?
    public var mode: MeasurementMode

    public init(
        instrument: InstrumentDescriptor,
        display: PhysicalDisplay? = nil,
        correction: DisplayCorrection? = nil,
        mode: MeasurementMode = .auto
    ) {
        self.instrument = instrument
        self.display = display
        self.correction = correction
        self.mode = mode
    }
}

public struct CalibrationRequest: Sendable {
    public var sessionDirectory: URL
    public var display: PhysicalDisplay
    public var instrument: InstrumentDescriptor
    public var target: CalibrationTarget
    public var correction: DisplayCorrection?
    public var mode: MeasurementMode

    public init(
        sessionDirectory: URL,
        display: PhysicalDisplay,
        instrument: InstrumentDescriptor,
        target: CalibrationTarget,
        correction: DisplayCorrection? = nil,
        mode: MeasurementMode = .auto
    ) {
        self.sessionDirectory = sessionDirectory
        self.display = display
        self.instrument = instrument
        self.target = target
        self.correction = correction
        self.mode = mode
    }
}

public struct CharacterizationRequest: Sendable {
    public var sessionDirectory: URL
    public var display: PhysicalDisplay
    public var instrument: InstrumentDescriptor
    public var calibrationURL: URL
    public var preset: CharacterizationPreset
    public var patchGeometry: PatchGeometry
    public var correction: DisplayCorrection?
    public var mode: MeasurementMode

    public init(
        sessionDirectory: URL,
        display: PhysicalDisplay,
        instrument: InstrumentDescriptor,
        calibrationURL: URL,
        preset: CharacterizationPreset,
        patchGeometry: PatchGeometry = PatchGeometry(),
        correction: DisplayCorrection? = nil,
        mode: MeasurementMode = .auto
    ) {
        self.sessionDirectory = sessionDirectory
        self.display = display
        self.instrument = instrument
        self.calibrationURL = calibrationURL
        self.preset = preset
        self.patchGeometry = patchGeometry
        self.correction = correction
        self.mode = mode
    }
}

public struct ProfileBuildRequest: Sendable {
    public var sessionDirectory: URL
    public var measurementURL: URL
    public var calibrationURL: URL
    public var outputURL: URL
    public var model: ProfileModel
    public var displayName: String
    public var description: String
    public var metadata: [String: String]

    public init(
        sessionDirectory: URL,
        measurementURL: URL,
        calibrationURL: URL,
        outputURL: URL,
        model: ProfileModel,
        displayName: String,
        description: String,
        metadata: [String: String] = [:]
    ) {
        self.sessionDirectory = sessionDirectory
        self.measurementURL = measurementURL
        self.calibrationURL = calibrationURL
        self.outputURL = outputURL
        self.model = model
        self.displayName = displayName
        self.description = description
        self.metadata = metadata
    }
}

public struct VerificationRequest: Sendable {
    public var sessionDirectory: URL
    public var display: PhysicalDisplay
    public var instrument: InstrumentDescriptor
    public var profileURL: URL
    public var target: CalibrationTarget
    public var correction: DisplayCorrection?
    public var mode: MeasurementMode

    public init(
        sessionDirectory: URL,
        display: PhysicalDisplay,
        instrument: InstrumentDescriptor,
        profileURL: URL,
        target: CalibrationTarget,
        correction: DisplayCorrection? = nil,
        mode: MeasurementMode = .auto
    ) {
        self.sessionDirectory = sessionDirectory
        self.display = display
        self.instrument = instrument
        self.profileURL = profileURL
        self.target = target
        self.correction = correction
        self.mode = mode
    }
}

public enum WorkflowStage: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case preflighting
    case awaitingMeterPlacement
    case adjustingDisplay
    case calibrating
    case generatingPatchSet
    case characterizing
    case buildingProfile
    case installingProfile
    case verifying
    case completed
    case cancelling
    case cancelled
    case failed
    case interrupted
}

public struct SessionArtifact: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: String
    public var url: URL
    public var sha256: String?
    public var isComplete: Bool

    public init(id: UUID = UUID(), kind: String, url: URL, sha256: String? = nil, isComplete: Bool = true) {
        self.id = id
        self.kind = kind
        self.url = url
        self.sha256 = sha256
        self.isComplete = isComplete
    }
}

public struct LogRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var level: String
    public var message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public struct UserActionRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

public enum CalibrationEvent: Sendable {
    case stageChanged(WorkflowStage)
    case message(String)
    case measurement(Measurement)
    case progress(completed: Int, total: Int?)
    case userActionRequired(UserActionRequest)
    case artifactCreated(SessionArtifact)
    case verificationCompleted(VerificationReport)
    case warning(String)
    case technicalLog(LogRecord)
}

public typealias CharacterizationEvent = CalibrationEvent
public typealias VerificationEvent = CalibrationEvent

public struct ICCProfileArtifact: Codable, Hashable, Sendable {
    public var url: URL
    public var model: ProfileModel
    public var sizeBytes: Int64
    public var sha256: String?
    public var validationMessages: [String]

    public init(
        url: URL,
        model: ProfileModel,
        sizeBytes: Int64,
        sha256: String? = nil,
        validationMessages: [String] = []
    ) {
        self.url = url
        self.model = model
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.validationMessages = validationMessages
    }
}

public struct VerificationMetrics: Codable, Hashable, Sendable {
    public var averageDeltaE2000: Double
    public var percentile95DeltaE2000: Double
    public var maximumDeltaE2000: Double
    public var whitePointDeltaE2000: Double
    public var measuredWhite: Chromaticity
    public var luminanceCDM2: Double
    public var blackLevelCDM2: Double?
    public var contrastRatio: Double?
    public var measuredGamma: Double?
    public var gammaRMSError: Double?
    public var measuredCorrelatedColorTemperature: Double?
    public var targetWhite: Chromaticity?
    public var targetLuminanceCDM2: Double?
    public var targetTransferFunction: TransferFunction?
    public var toneResponseRMSError: Double?
    public var warnings: [String]

    public init(
        averageDeltaE2000: Double,
        percentile95DeltaE2000: Double,
        maximumDeltaE2000: Double,
        whitePointDeltaE2000: Double,
        measuredWhite: Chromaticity,
        luminanceCDM2: Double,
        blackLevelCDM2: Double?,
        contrastRatio: Double?,
        measuredGamma: Double?,
        gammaRMSError: Double?,
        measuredCorrelatedColorTemperature: Double? = nil,
        targetWhite: Chromaticity? = nil,
        targetLuminanceCDM2: Double? = nil,
        targetTransferFunction: TransferFunction? = nil,
        toneResponseRMSError: Double? = nil,
        warnings: [String] = []
    ) {
        self.averageDeltaE2000 = averageDeltaE2000
        self.percentile95DeltaE2000 = percentile95DeltaE2000
        self.maximumDeltaE2000 = maximumDeltaE2000
        self.whitePointDeltaE2000 = whitePointDeltaE2000
        self.measuredWhite = measuredWhite
        self.luminanceCDM2 = luminanceCDM2
        self.blackLevelCDM2 = blackLevelCDM2
        self.contrastRatio = contrastRatio
        self.measuredGamma = measuredGamma
        self.gammaRMSError = gammaRMSError
        self.measuredCorrelatedColorTemperature = measuredCorrelatedColorTemperature
        self.targetWhite = targetWhite
        self.targetLuminanceCDM2 = targetLuminanceCDM2
        self.targetTransferFunction = targetTransferFunction
        self.toneResponseRMSError = toneResponseRMSError
        self.warnings = warnings
    }
}

public struct VerificationReport: Codable, Hashable, Sendable {
    public var metrics: VerificationMetrics
    public var rawOutput: String
    public var measuredAt: Date

    public init(metrics: VerificationMetrics, rawOutput: String, measuredAt: Date = Date()) {
        self.metrics = metrics
        self.rawOutput = rawOutput
        self.measuredAt = measuredAt
    }
}

public struct DisplayProfileBaseline: Codable, Hashable, Sendable {
    public var displayFingerprint: String
    public var activeProfileURL: URL?
    public var capturedAt: Date

    public init(
        displayFingerprint: String,
        activeProfileURL: URL?,
        capturedAt: Date = Date()
    ) {
        self.displayFingerprint = displayFingerprint
        self.activeProfileURL = activeProfileURL
        self.capturedAt = capturedAt
    }
}

public enum ProfileActivationStatus: String, Codable, Hashable, Sendable {
    case activationPending
    case active
    case restorationRequired
}

public struct ProfileInstallationRecord: Codable, Hashable, Sendable {
    public var displayFingerprint: String
    public var installedProfileURL: URL
    public var previousProfileURL: URL?
    public var installedAt: Date
    public var activationStatus: ProfileActivationStatus
    public var activatedAt: Date?

    public init(
        displayFingerprint: String,
        installedProfileURL: URL,
        previousProfileURL: URL?,
        installedAt: Date = Date(),
        activationStatus: ProfileActivationStatus = .active,
        activatedAt: Date? = nil
    ) {
        self.displayFingerprint = displayFingerprint
        self.installedProfileURL = installedProfileURL
        self.previousProfileURL = previousProfileURL
        self.installedAt = installedAt
        self.activationStatus = activationStatus
        self.activatedAt = activatedAt ?? (activationStatus == .active ? installedAt : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case displayFingerprint
        case installedProfileURL
        case previousProfileURL
        case installedAt
        case activationStatus
        case activatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayFingerprint = try container.decode(String.self, forKey: .displayFingerprint)
        installedProfileURL = try container.decode(URL.self, forKey: .installedProfileURL)
        previousProfileURL = try container.decodeIfPresent(URL.self, forKey: .previousProfileURL)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        activationStatus = try container.decodeIfPresent(
            ProfileActivationStatus.self,
            forKey: .activationStatus
        ) ?? .active
        activatedAt = try container.decodeIfPresent(Date.self, forKey: .activatedAt)
            ?? (activationStatus == .active ? installedAt : nil)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayFingerprint, forKey: .displayFingerprint)
        try container.encode(installedProfileURL, forKey: .installedProfileURL)
        try container.encodeIfPresent(previousProfileURL, forKey: .previousProfileURL)
        try container.encode(installedAt, forKey: .installedAt)
        try container.encode(activationStatus, forKey: .activationStatus)
        try container.encodeIfPresent(activatedAt, forKey: .activatedAt)
    }
}

public struct EnvironmentSnapshot: Codable, Hashable, Sendable {
    public var engineVersion: String?
    public var engineDirectory: URL?
    public var toolStatus: [String: Bool]
    public var engineDiagnostic: String
    public var operatingSystem: String
    public var appVersion: String?

    public init(
        engineVersion: String?,
        engineDirectory: URL?,
        toolStatus: [String: Bool],
        engineDiagnostic: String,
        operatingSystem: String,
        appVersion: String? = nil
    ) {
        self.engineVersion = engineVersion
        self.engineDirectory = engineDirectory
        self.toolStatus = toolStatus
        self.engineDiagnostic = engineDiagnostic
        self.operatingSystem = operatingSystem
        self.appVersion = appVersion
    }
}

/// Durable outcome of the latest explicit activation-and-verification request.
///
/// A generated profile remains a valid candidate when a later activation attempt
/// fails or is cancelled. Keeping that attempt separate from `WorkflowStage`
/// prevents a recovered attempt from looking like a profile that was never tried.
public enum ActivationVerificationAttemptStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case inProgress
    case verified
    /// The profile was activated and left active without a verification pass.
    case activated
    case failed
    case cancelled
}

public struct ActivationVerificationAttempt: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var status: ActivationVerificationAttemptStatus
    public var startedAt: Date
    public var profileActivatedAt: Date?
    public var verificationStartedAt: Date?
    public var finishedAt: Date?
    public var errorMessage: String?

    /// `nil` means the attempt is still running or recovery could not be
    /// confirmed. `true` means the Before profile was retained or restored;
    /// `false` means the generated After profile remains active after success.
    public var restoredBeforeProfile: Bool?
    public var restoredBeforeProfileAt: Date?

    public init(
        id: UUID = UUID(),
        status: ActivationVerificationAttemptStatus = .inProgress,
        startedAt: Date = Date(),
        profileActivatedAt: Date? = nil,
        verificationStartedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil,
        restoredBeforeProfile: Bool? = nil,
        restoredBeforeProfileAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.profileActivatedAt = profileActivatedAt
        self.verificationStartedAt = verificationStartedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.restoredBeforeProfile = restoredBeforeProfile
        self.restoredBeforeProfileAt = restoredBeforeProfileAt
    }
}

public struct CalibrationSession: Codable, Hashable, Sendable, Identifiable {
    public static let schemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var state: WorkflowStage
    public var display: PhysicalDisplay?
    public var instrument: InstrumentDescriptor?
    public var target: CalibrationTarget?
    public var correction: DisplayCorrection?
    public var measurementMode: MeasurementMode?
    public var characterizationPreset: CharacterizationPreset?
    public var plannedCharacterizationPatchCount: Int?
    public var actualCharacterizationPatchCount: Int?
    public var profileModel: ProfileModel?
    public var environment: EnvironmentSnapshot?
    public var profileBaseline: DisplayProfileBaseline?
    /// Optional white-patch reading captured before calibration. This is a
    /// setup comparison, not a full pre-calibration color-accuracy report.
    public var setupMeasurement: Measurement?
    public var artifacts: [SessionArtifact]
    public var profileGenerationCompletedAt: Date?
    public var activationVerificationAttempt: ActivationVerificationAttempt?
    public var verification: VerificationReport?
    public var verificationAssessment: VerificationAssessment?
    public var installation: ProfileInstallationRecord?
    public var failureMessage: String?

    public init(
        schemaVersion: Int = CalibrationSession.schemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        state: WorkflowStage = .idle,
        display: PhysicalDisplay? = nil,
        instrument: InstrumentDescriptor? = nil,
        target: CalibrationTarget? = nil,
        correction: DisplayCorrection? = nil,
        measurementMode: MeasurementMode? = nil,
        characterizationPreset: CharacterizationPreset? = nil,
        plannedCharacterizationPatchCount: Int? = nil,
        actualCharacterizationPatchCount: Int? = nil,
        profileModel: ProfileModel? = nil,
        environment: EnvironmentSnapshot? = nil,
        profileBaseline: DisplayProfileBaseline? = nil,
        setupMeasurement: Measurement? = nil,
        artifacts: [SessionArtifact] = [],
        profileGenerationCompletedAt: Date? = nil,
        activationVerificationAttempt: ActivationVerificationAttempt? = nil,
        verification: VerificationReport? = nil,
        verificationAssessment: VerificationAssessment? = nil,
        installation: ProfileInstallationRecord? = nil,
        failureMessage: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.display = display
        self.instrument = instrument
        self.target = target
        self.correction = correction
        self.measurementMode = measurementMode
        self.characterizationPreset = characterizationPreset
        self.plannedCharacterizationPatchCount = plannedCharacterizationPatchCount
        self.actualCharacterizationPatchCount = actualCharacterizationPatchCount
        self.profileModel = profileModel
        self.environment = environment
        self.profileBaseline = profileBaseline
        self.setupMeasurement = setupMeasurement
        self.artifacts = artifacts
        self.profileGenerationCompletedAt = profileGenerationCompletedAt
        self.activationVerificationAttempt = activationVerificationAttempt
        self.verification = verification
        self.verificationAssessment = verificationAssessment
        self.installation = installation
        self.failureMessage = failureMessage
    }
}
