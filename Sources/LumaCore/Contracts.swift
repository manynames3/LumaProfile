import Foundation

public struct EngineProbe: Codable, Hashable, Sendable {
    public var isAvailable: Bool
    public var version: String?
    public var directory: URL?
    public var toolStatus: [String: Bool]
    public var diagnostic: String

    public init(
        isAvailable: Bool,
        version: String? = nil,
        directory: URL? = nil,
        toolStatus: [String: Bool] = [:],
        diagnostic: String
    ) {
        self.isAvailable = isAvailable
        self.version = version
        self.directory = directory
        self.toolStatus = toolStatus
        self.diagnostic = diagnostic
    }
}

public protocol CalibrationEngine: Sendable {
    func probe() async -> EngineProbe
    func discoverInstruments() async throws -> [InstrumentDescriptor]
    func validateDisplayMapping(for display: PhysicalDisplay) async throws
    func measure(_ request: SpotMeasurementRequest) async throws -> Measurement
    /// Takes readings back to back until `onReading` returns `false`.
    func measureContinuously(
        _ request: SpotMeasurementRequest,
        onReading: @escaping @Sendable (Measurement) async -> Bool
    ) async throws
    func calibrate(_ request: CalibrationRequest) -> AsyncThrowingStream<CalibrationEvent, Error>
    func characterize(_ request: CharacterizationRequest) -> AsyncThrowingStream<CharacterizationEvent, Error>
    func buildProfile(_ request: ProfileBuildRequest) async throws -> ICCProfileArtifact
    func verify(_ request: VerificationRequest) -> AsyncThrowingStream<VerificationEvent, Error>
    func restoreActiveProfileCalibration(for display: PhysicalDisplay, sessionDirectory: URL) async throws
    func acknowledgeUserAction(id: String) async throws
    func cancelCurrentOperation() async
}

extension CalibrationEngine {
    /// Fallback for engines without a persistent meter session.
    public func measureContinuously(
        _ request: SpotMeasurementRequest,
        onReading: @escaping @Sendable (Measurement) async -> Bool
    ) async throws {
        while true {
            let measurement = try await measure(request)
            guard await onReading(measurement) else { return }
        }
    }
}

public protocol ProfileInstaller: Sendable {
    func currentProfile(for display: PhysicalDisplay) async throws -> URL?
    func prepareActivation(
        profileURL: URL,
        for display: PhysicalDisplay,
        expectedCurrentProfileURL: URL?
    ) async throws -> ProfileInstallationRecord
    func activate(_ record: ProfileInstallationRecord, for display: PhysicalDisplay) async throws
    func rollback(_ record: ProfileInstallationRecord, for display: PhysicalDisplay) async throws
}

/// Which of a session's two recorded profiles to show for a visual comparison.
public enum ProfileComparisonSide: String, Sendable {
    case before
    case after
}

/// Temporarily switches a display between the Before and After profiles an
/// activation recorded, without ending the activation or deleting either file.
public protocol ProfileComparisonSwitching: Sendable {
    func showComparison(
        _ side: ProfileComparisonSide,
        record: ProfileInstallationRecord,
        for display: PhysicalDisplay
    ) async throws
}

/// An installation error that means ColorSync may have changed the active
/// association and the workflow must retain this record until rollback is
/// verified.
public protocol ProfileInstallationRecoveryProviding: Error, Sendable {
    var recoveryRecord: ProfileInstallationRecord { get }
}

public protocol DisplayInventory: Sendable {
    func displays() async throws -> [PhysicalDisplay]
}

public protocol SessionStore: Sendable {
    func create(_ session: CalibrationSession) async throws -> URL
    func save(_ session: CalibrationSession) async throws
    func load(id: UUID) async throws -> CalibrationSession
    func list() async throws -> [CalibrationSession]
    func append(event: CalibrationEvent, sessionID: UUID) async throws
    func sessionDirectory(for id: UUID) async -> URL
}

public struct ProcessRequest: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectoryURL: URL
    public var environment: [String: String]
    public var timeout: Duration?
    public var standardInput: Data?

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String] = [:],
        timeout: Duration? = nil,
        standardInput: Data? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.timeout = timeout
        self.standardInput = standardInput
    }
}

public struct ProcessResult: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var startedAt: Date
    public var endedAt: Date
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(
        executableURL: URL,
        arguments: [String],
        startedAt: Date,
        endedAt: Date,
        exitCode: Int32,
        stdout: Data,
        stderr: Data
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public protocol ProcessExecuting: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

public enum InteractiveProcessEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case prompt(identifier: String, message: String)
    case exited(Int32)
}

public protocol InteractiveProcessSession: Sendable {
    var events: AsyncThrowingStream<InteractiveProcessEvent, Error> { get async }
    func start(_ request: ProcessRequest) async throws
    func respond(toPrompt identifier: String, with response: Data) async throws
    func cancel() async
}

public protocol DisplayControlService: Sendable {
    var isAvailable: Bool { get }
}
