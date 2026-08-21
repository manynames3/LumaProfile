import Foundation

public struct CalibrationEngineUnavailableError: LocalizedError, Sendable {
    public var diagnostic: String

    public init(diagnostic: String = "No compatible calibration engine was found.") {
        self.diagnostic = diagnostic
    }

    public var errorDescription: String? { diagnostic }
}

/// A non-crashing fallback used while the external engine or meter is absent.
public struct UnavailableCalibrationEngine: CalibrationEngine, Sendable {
    public var diagnostic: String

    public init(diagnostic: String = "Install or select a compatible calibration engine in Settings.") {
        self.diagnostic = diagnostic
    }

    public func probe() async -> EngineProbe {
        EngineProbe(isAvailable: false, diagnostic: diagnostic)
    }

    public func discoverInstruments() async throws -> [InstrumentDescriptor] { [] }

    public func validateDisplayMapping(for display: PhysicalDisplay) async throws {
        throw CalibrationEngineUnavailableError(diagnostic: diagnostic)
    }

    public func measure(_ request: SpotMeasurementRequest) async throws -> Measurement {
        throw CalibrationEngineUnavailableError(diagnostic: diagnostic)
    }

    public func calibrate(_ request: CalibrationRequest) -> AsyncThrowingStream<CalibrationEvent, Error> {
        failedStream()
    }

    public func characterize(_ request: CharacterizationRequest) -> AsyncThrowingStream<CharacterizationEvent, Error> {
        failedStream()
    }

    public func buildProfile(_ request: ProfileBuildRequest) async throws -> ICCProfileArtifact {
        throw CalibrationEngineUnavailableError(diagnostic: diagnostic)
    }

    public func verify(_ request: VerificationRequest) -> AsyncThrowingStream<VerificationEvent, Error> {
        failedStream()
    }

    public func restoreActiveProfileCalibration(
        for display: PhysicalDisplay,
        sessionDirectory: URL
    ) async throws {
        throw CalibrationEngineUnavailableError(diagnostic: diagnostic)
    }

    public func acknowledgeUserAction(id: String) async throws {
        throw CalibrationEngineUnavailableError(diagnostic: diagnostic)
    }

    public func cancelCurrentOperation() async {}

    private func failedStream() -> AsyncThrowingStream<CalibrationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CalibrationEngineUnavailableError(diagnostic: diagnostic))
        }
    }
}
