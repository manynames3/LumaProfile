import Foundation

public struct CalibrationWorkflowRequest: Sendable {
    public var display: PhysicalDisplay
    public var instrument: InstrumentDescriptor
    public var target: CalibrationTarget
    public var correction: DisplayCorrection?
    public var measurementMode: MeasurementMode
    public var setupMeasurement: Measurement?
    public var characterization: CharacterizationPreset
    public var profileModel: ProfileModel
    public var profileDescription: String

    public init(
        display: PhysicalDisplay,
        instrument: InstrumentDescriptor,
        target: CalibrationTarget,
        correction: DisplayCorrection? = nil,
        measurementMode: MeasurementMode = .auto,
        setupMeasurement: Measurement? = nil,
        characterization: CharacterizationPreset = .fast,
        profileModel: ProfileModel = .shaperMatrix,
        profileDescription: String
    ) {
        self.display = display
        self.instrument = instrument
        self.target = target
        self.correction = correction
        self.measurementMode = measurementMode
        self.setupMeasurement = setupMeasurement
        self.characterization = characterization
        self.profileModel = profileModel
        self.profileDescription = profileDescription
    }
}

public enum CalibrationWorkflowUpdate: Sendable {
    case sessionCreated(CalibrationSession, directory: URL)
    case event(CalibrationEvent)
    case sessionUpdated(CalibrationSession)
}

public enum CalibrationWorkflowError: LocalizedError, Sendable {
    case alreadyRunning
    case invalidDisplayMapping
    case missingCalibrationArtifact
    case missingMeasurementArtifact
    case missingProfileArtifact
    case missingProfileHash
    case profileArtifactChanged
    case missingProfileBaseline
    case missingInstallationRecord
    case missingDisplay
    case missingInstrument
    case missingTarget
    case missingVerificationReport
    case activationRequiresCompletedSession
    case activationRecoveryRequired
    case baselineProfileAssociationChanged
    case engineUnavailable(String)
    case instrumentUnavailable(String)
    case protectedStatePersistenceFailed(operationFailure: String, persistenceFailure: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "A calibration is already running."
        case .invalidDisplayMapping:
            "Confirm a positive engine display number for the selected macOS display before calibration."
        case .missingCalibrationArtifact:
            "Calibration finished without producing a usable calibration artifact."
        case .missingMeasurementArtifact:
            "Characterization finished without producing measurement data."
        case .missingProfileArtifact:
            "This session has no complete generated ICC profile to activate."
        case .missingProfileHash:
            "The generated ICC profile has no recorded SHA-256 identity and cannot be activated safely. Generate a new profile."
        case .profileArtifactChanged:
            "The generated ICC profile no longer matches its recorded SHA-256. It was not installed or activated."
        case .missingProfileBaseline:
            "This session did not capture the display profile that was active before calibration. Start a new calibration before activating a profile."
        case .missingInstallationRecord:
            "This session has no active installation to roll back."
        case .missingDisplay:
            "The session no longer identifies its calibrated display."
        case .missingInstrument:
            "The session no longer identifies the meter used for calibration."
        case .missingTarget:
            "The session no longer contains its calibration target."
        case .missingVerificationReport:
            "Verification ended without producing a complete result. The generated profile was not left active."
        case .activationRequiresCompletedSession:
            "Only a completed calibration profile can be activated."
        case .activationRecoveryRequired:
            "This session already has an incomplete or active profile operation. Restore the Before profile before trying again."
        case .baselineProfileAssociationChanged:
            "The selected display's ColorSync profile association changed after this session began. LumaProfile did not replace it; review the current profile before recovery."
        case .engineUnavailable(let diagnostic):
            diagnostic
        case .instrumentUnavailable(let diagnostic):
            diagnostic
        case .protectedStatePersistenceFailed(let operationFailure, let persistenceFailure):
            "The display operation failed (\(operationFailure)), and LumaProfile could not finish saving its recovery state (\(persistenceFailure)). Keep LumaProfile open and retry Restore Before."
        }
    }
}

/// Runs the product-level calibration pipeline. Argyll command construction and
/// parsing remain entirely behind `CalibrationEngine`.
public actor CalibrationWorkflow {
    private let engine: any CalibrationEngine
    private let installer: any ProfileInstaller
    private let store: any SessionStore
    private var runningTask: Task<Void, Never>?

    public init(
        engine: any CalibrationEngine,
        installer: any ProfileInstaller,
        store: any SessionStore
    ) {
        self.engine = engine
        self.installer = installer
        self.store = store
    }

    public var isRunning: Bool { runningTask != nil }

    public func run(
        _ request: CalibrationWorkflowRequest
    ) -> AsyncThrowingStream<CalibrationWorkflowUpdate, Error> {
        guard runningTask == nil else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: CalibrationWorkflowError.alreadyRunning)
            }
        }

        let stream = AsyncThrowingStream<CalibrationWorkflowUpdate, Error> { continuation in
            runningTask = Task {
                await execute(request, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.cancel() }
            }
        }
        return stream
    }

    /// Activates a generated candidate only after a separate, explicit UI action,
    /// then measures an independent verification set. Normal calibration runs do
    /// not call this operation.
    public func activateAndVerify(
        session: CalibrationSession
    ) -> AsyncThrowingStream<CalibrationWorkflowUpdate, Error> {
        guard runningTask == nil else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: CalibrationWorkflowError.alreadyRunning)
            }
        }

        let stream = AsyncThrowingStream<CalibrationWorkflowUpdate, Error> { continuation in
            runningTask = Task {
                await executeActivationAndVerification(session, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.cancel() }
            }
        }
        return stream
    }

    public func cancel() async {
        runningTask?.cancel()
        await engine.cancelCurrentOperation()
    }

    public func acknowledgeUserAction(id: String) async throws {
        try await engine.acknowledgeUserAction(id: id)
    }

    /// Converts sessions left in a live stage by a previous process into an
    /// honest recovery state. It deliberately does not touch a display on app
    /// launch because the operator must first have a still-valid display map.
    public func reconcileInterruptedSessions() async throws -> [CalibrationSession] {
        var sessions = try await store.list()
        for index in sessions.indices where !Self.isTerminal(sessions[index].state) {
            sessions[index].state = .interrupted
            let interruptionMessage =
                "The previous LumaProfile process ended before display restoration was confirmed. Use Restore Before after reconnecting the same display topology."
            sessions[index].failureMessage = interruptionMessage
            if sessions[index].activationVerificationAttempt?.status == .inProgress {
                sessions[index].activationVerificationAttempt?.status = .failed
                sessions[index].activationVerificationAttempt?.finishedAt = persistenceTimestamp()
                sessions[index].activationVerificationAttempt?.errorMessage = interruptionMessage
                sessions[index].activationVerificationAttempt?.restoredBeforeProfile = nil
                sessions[index].activationVerificationAttempt?.restoredBeforeProfileAt = nil
                sessions[index].verification = nil
                sessions[index].verificationAssessment = nil
            }
            sessions[index].updatedAt = Date()
            try await store.append(
                event: .warning(sessions[index].failureMessage ?? "Interrupted session requires recovery."),
                sessionID: sessions[index].id
            )
            try await store.save(sessions[index])
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Recovers either a journaled activation or a generation-only interrupted
    /// VideoLUT. Generation recovery never changes the ColorSync association.
    public func restoreBefore(session original: CalibrationSession) async throws -> CalibrationSession {
        if original.installation != nil {
            return try await rollback(session: original)
        }
        guard original.state == .interrupted else {
            throw CalibrationWorkflowError.missingInstallationRecord
        }
        guard let display = original.display else {
            throw CalibrationWorkflowError.missingDisplay
        }
        guard let baseline = original.profileBaseline,
              baseline.displayFingerprint == display.fingerprint else {
            throw CalibrationWorkflowError.missingProfileBaseline
        }
        let currentProfile = try await installer.currentProfile(for: display)
        guard sameProfileAssociation(currentProfile, baseline.activeProfileURL) else {
            throw CalibrationWorkflowError.baselineProfileAssociationChanged
        }
        let directory = await store.sessionDirectory(for: original.id)
        try await engine.restoreActiveProfileCalibration(for: display, sessionDirectory: directory)

        var session = original
        session.state = .cancelled
        session.failureMessage = nil
        session.updatedAt = Date()
        try await store.append(
            event: .message("Reloaded the calibration for the unchanged Before profile after the interrupted run."),
            sessionID: session.id
        )
        try await store.append(event: .stageChanged(.cancelled), sessionID: session.id)
        try await store.save(session)
        return session
    }

    public func rollback(session original: CalibrationSession) async throws -> CalibrationSession {
        guard let record = original.installation else {
            throw CalibrationWorkflowError.missingInstallationRecord
        }
        guard let display = original.display else {
            throw CalibrationWorkflowError.missingDisplay
        }
        var session = original

        // Write ahead before either ColorSync or the display VideoLUT changes.
        // If the process dies during restoration, the next launch must see an
        // explicit recovery obligation instead of a stale `.active` record.
        session.installation?.activationStatus = .restorationRequired
        session.updatedAt = Date()
        do {
            try await store.save(session)
            try await store.append(
                event: .message("Restore Before started after saving a durable recovery marker."),
                sessionID: session.id
            )
        } catch let persistenceError {
            throw CalibrationWorkflowError.protectedStatePersistenceFailed(
                operationFailure: "Restore Before was stopped before changing the display because its recovery marker could not be secured",
                persistenceFailure: persistenceError.localizedDescription
            )
        }

        do {
            try await installer.rollback(record, for: display)
            let directory = await store.sessionDirectory(for: original.id)
            try await engine.restoreActiveProfileCalibration(for: display, sessionDirectory: directory)
        } catch let restoreError {
            session.state = .interrupted
            session.failureMessage = "Restore Before failed: \(restoreError.localizedDescription)"
            session.installation?.activationStatus = .restorationRequired
            session.activationVerificationAttempt?.restoredBeforeProfile = false
            session.activationVerificationAttempt?.restoredBeforeProfileAt = nil
            session.updatedAt = Date()
            do {
                // The durable state is authoritative; journal records follow it.
                try await store.save(session)
                try await store.append(
                    event: .warning(session.failureMessage ?? "Restore Before failed and still requires review."),
                    sessionID: session.id
                )
                try await store.append(event: .stageChanged(.interrupted), sessionID: session.id)
            } catch let persistenceError {
                throw CalibrationWorkflowError.protectedStatePersistenceFailed(
                    operationFailure: restoreError.localizedDescription,
                    persistenceFailure: persistenceError.localizedDescription
                )
            }
            throw restoreError
        }
        session.installation = nil
        if session.activationVerificationAttempt != nil {
            session.activationVerificationAttempt?.restoredBeforeProfile = true
            session.activationVerificationAttempt?.restoredBeforeProfileAt = persistenceTimestamp()
        }
        let recoveredInterruptedAttempt = session.state == .interrupted
        if recoveredInterruptedAttempt {
            // Activation starts only from a completed generated candidate. Once
            // its retained recovery record has been rolled back successfully,
            // the candidate remains complete and inactive rather than staying
            // mislabeled as needing recovery.
            session.state = .completed
            session.failureMessage = nil
        }
        session.updatedAt = Date()
        try await store.append(
            event: .message("Restored the profile that was active before this calibration."),
            sessionID: session.id
        )
        if recoveredInterruptedAttempt {
            try await store.append(event: .stageChanged(.completed), sessionID: session.id)
        }
        try await store.save(session)
        return session
    }

    private func execute(
        _ request: CalibrationWorkflowRequest,
        continuation: AsyncThrowingStream<CalibrationWorkflowUpdate, Error>.Continuation
    ) async {
        var session = CalibrationSession(
            state: .preflighting,
            display: request.display,
            instrument: request.instrument,
            target: request.target,
            correction: request.correction,
            measurementMode: request.measurementMode,
            characterizationPreset: request.characterization,
            plannedCharacterizationPatchCount: request.characterization.requestedPatchCount,
            profileModel: request.profileModel,
            setupMeasurement: request.setupMeasurement
        )
        var didCreateSession = false
        var calibrationMayHaveChangedDisplay = false
        var sessionDirectory: URL?

        defer { runningTask = nil }

        do {
            guard (request.display.argyllDisplayIndex ?? 0) > 0 else {
                throw CalibrationWorkflowError.invalidDisplayMapping
            }
            let probe = await engine.probe()
            guard probe.isAvailable else {
                throw CalibrationWorkflowError.engineUnavailable(probe.diagnostic)
            }
            try await requireConnectedHardware(
                display: request.display,
                instrument: request.instrument,
                unavailableMessage: "The selected i1Display is no longer available at the same USB instrument index. Reconnect it, close i1Profiler/ccProfiler or other meter software, refresh meters, and select it again."
            )
            session.environment = EnvironmentSnapshot(
                engineVersion: probe.version,
                engineDirectory: probe.directory,
                toolStatus: probe.toolStatus,
                engineDiagnostic: probe.diagnostic,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
            session.profileBaseline = DisplayProfileBaseline(
                displayFingerprint: request.display.fingerprint,
                activeProfileURL: try await installer.currentProfile(for: request.display),
                capturedAt: persistenceTimestamp()
            )

            let directory = try await store.create(session)
            sessionDirectory = directory
            didCreateSession = true
            continuation.yield(.sessionCreated(session, directory: directory))
            try await emit(
                .message("Preflight complete. The selected display and meter are locked to this session."),
                session: &session,
                continuation: continuation
            )
            let effortName = CalibrationEffort.matching(
                calibrationQuality: request.target.quality,
                characterizationPreset: request.characterization
            )?.rawValue ?? request.characterization.rawValue
            try await emit(
                .message(
                    "Measurement effort: \(effortName), with \(request.characterization.requestedPatchCount) characterization patches. Calibration and optional verification use additional readings."
                ),
                session: &session,
                continuation: continuation
            )

            try Task.checkCancellation()
            try await emit(.stageChanged(.calibrating), session: &session, continuation: continuation)
            let calibrationRequest = CalibrationRequest(
                sessionDirectory: directory,
                display: request.display,
                instrument: request.instrument,
                target: request.target,
                correction: request.correction,
                mode: request.measurementMode
            )
            calibrationMayHaveChangedDisplay = true
            try await consume(
                engine.calibrate(calibrationRequest),
                session: &session,
                continuation: continuation
            )
            guard let calibrationURL = artifactURL(
                in: session,
                matching: ["calibration"],
                extensions: ["cal"]
            ) else {
                throw CalibrationWorkflowError.missingCalibrationArtifact
            }

            try Task.checkCancellation()
            try await requireConnectedHardware(
                display: request.display,
                instrument: request.instrument,
                unavailableMessage: "The selected i1Display disconnected after calibration. Reconnect it and start a new run; the display's prior calibration will be restored safely."
            )
            try await emit(.stageChanged(.characterizing), session: &session, continuation: continuation)
            let characterizationRequest = CharacterizationRequest(
                sessionDirectory: directory,
                display: request.display,
                instrument: request.instrument,
                calibrationURL: calibrationURL,
                preset: request.characterization,
                patchGeometry: request.target.patchGeometry,
                correction: request.correction,
                mode: request.measurementMode
            )
            try await consume(
                engine.characterize(characterizationRequest),
                session: &session,
                continuation: continuation
            )
            if let actualPatchCount = session.actualCharacterizationPatchCount {
                let plannedPatchCount = request.characterization.requestedPatchCount
                if actualPatchCount == plannedPatchCount {
                    try await emit(
                        .message("Measured all \(actualPatchCount) characterization patches."),
                        session: &session,
                        continuation: continuation
                    )
                } else {
                    try await emit(
                        .warning(
                            "ArgyllCMS generated \(actualPatchCount) characterization patches, not the planned \(plannedPatchCount). The actual count is retained with this session."
                        ),
                        session: &session,
                        continuation: continuation
                    )
                }
            }
            guard let measurementURL = artifactURL(
                in: session,
                matching: ["measurement", "characterization"],
                extensions: ["ti3"]
            ) else {
                throw CalibrationWorkflowError.missingMeasurementArtifact
            }

            try Task.checkCancellation()
            try await emit(.stageChanged(.buildingProfile), session: &session, continuation: continuation)
            let outputURL = directory.appending(path: profileFilename(for: request))
            let profileRequest = ProfileBuildRequest(
                sessionDirectory: directory,
                measurementURL: measurementURL,
                calibrationURL: calibrationURL,
                outputURL: outputURL,
                model: request.profileModel,
                displayName: request.display.name,
                description: request.profileDescription,
                metadata: [
                    "displayFingerprint": request.display.fingerprint,
                    "instrumentID": request.instrument.id,
                    "target": request.target.name,
                    "characterizationPatches": String(
                        session.actualCharacterizationPatchCount
                            ?? request.characterization.requestedPatchCount
                    ),
                    "characterizationPreset": request.characterization.rawValue,
                    "calibrationQuality": request.target.quality.rawValue,
                    "measurementEffort": effortName,
                ]
            )
            let profile = try await engine.buildProfile(profileRequest)
            session.profileGenerationCompletedAt = persistenceTimestamp()
            try await emit(
                .artifactCreated(SessionArtifact(kind: "ICC profile", url: profile.url, sha256: profile.sha256)),
                session: &session,
                continuation: continuation
            )

            // A calibration run is deliberately generation-only. Argyll loads
            // temporary VideoLUT calibration while measuring, so reload the
            // already-associated profile before presenting the candidate.
            try await engine.restoreActiveProfileCalibration(
                for: request.display,
                sessionDirectory: directory
            )
            calibrationMayHaveChangedDisplay = false
            try await emit(
                .message("The generated profile is inactive. LumaProfile left the ColorSync association unchanged, and calibration was reloaded from the profile currently associated with the selected display."),
                session: &session,
                continuation: continuation
            )

            try Task.checkCancellation()
            try await emit(.stageChanged(.completed), session: &session, continuation: continuation)
            continuation.finish()
        } catch {
            if Task.isCancelled || error is CancellationError {
                if didCreateSession {
                    try? await emit(.stageChanged(.cancelling), session: &session, continuation: continuation)
                    let calibrationRestored = await restoreDisplayCalibrationIfNeeded(
                        calibrationMayHaveChangedDisplay,
                        display: request.display,
                        sessionDirectory: sessionDirectory
                    )
                    let profileRestored = await rollbackInstalledProfile(
                        session: &session,
                        display: request.display
                    )
                    let cleanupSucceeded = calibrationRestored && profileRestored
                    let terminalStage: WorkflowStage = cleanupSucceeded ? .cancelled : .interrupted
                    let warning: String?
                    if cleanupSucceeded {
                        session.failureMessage = nil
                        warning = nil
                    } else {
                        var failures: [String] = []
                        if !calibrationRestored {
                            failures.append("the previously active display calibration could not be reloaded")
                        }
                        if !profileRestored {
                            failures.append("the Before profile could not be restored")
                        }
                        session.failureMessage = "Calibration was cancelled, but \(failures.joined(separator: " and "))."
                        warning = session.failureMessage
                    }
                    do {
                        try await persistProtectedTerminalState(
                            terminalStage,
                            warning: warning,
                            session: &session,
                            continuation: continuation
                        )
                    } catch let persistenceError {
                        continuation.yield(.sessionUpdated(session))
                        continuation.finish(throwing: CalibrationWorkflowError.protectedStatePersistenceFailed(
                            operationFailure: "Calibration cancellation",
                            persistenceFailure: persistenceError.localizedDescription
                        ))
                        return
                    }
                }
                continuation.finish()
                return
            }
            let calibrationRestored = await restoreDisplayCalibrationIfNeeded(
                calibrationMayHaveChangedDisplay,
                display: request.display,
                sessionDirectory: sessionDirectory
            )
            let profileRestored = await rollbackInstalledProfile(
                session: &session,
                display: request.display
            )
            let cleanupSucceeded = calibrationRestored && profileRestored
            let terminalStage: WorkflowStage = cleanupSucceeded ? .failed : .interrupted
            var failureDetails = [error.localizedDescription]
            if !calibrationRestored {
                failureDetails.append("The previously active display calibration could not be reloaded.")
            }
            if !profileRestored {
                failureDetails.append("The Before profile could not be restored.")
            }
            session.failureMessage = failureDetails.joined(separator: " ")
            if didCreateSession {
                do {
                    try await persistProtectedTerminalState(
                        terminalStage,
                        warning: session.failureMessage,
                        session: &session,
                        continuation: continuation
                    )
                } catch let persistenceError {
                    continuation.yield(.sessionUpdated(session))
                    continuation.finish(throwing: CalibrationWorkflowError.protectedStatePersistenceFailed(
                        operationFailure: error.localizedDescription,
                        persistenceFailure: persistenceError.localizedDescription
                    ))
                    return
                }
            }
            continuation.finish(throwing: error)
        }
    }

    private func executeActivationAndVerification(
        _ original: CalibrationSession,
        continuation: AsyncThrowingStream<CalibrationWorkflowUpdate, Error>.Continuation
    ) async {
        var session = original
        defer { runningTask = nil }

        guard original.state == .completed else {
            continuation.finish(throwing: CalibrationWorkflowError.activationRequiresCompletedSession)
            return
        }
        guard original.installation == nil else {
            continuation.finish(throwing: CalibrationWorkflowError.activationRecoveryRequired)
            return
        }
        guard let display = original.display else {
            continuation.finish(throwing: CalibrationWorkflowError.missingDisplay)
            return
        }
        guard let instrument = original.instrument else {
            continuation.finish(throwing: CalibrationWorkflowError.missingInstrument)
            return
        }
        guard let target = original.target else {
            continuation.finish(throwing: CalibrationWorkflowError.missingTarget)
            return
        }
        guard let baseline = original.profileBaseline,
              baseline.displayFingerprint == display.fingerprint else {
            continuation.finish(throwing: CalibrationWorkflowError.missingProfileBaseline)
            return
        }
        guard let profileArtifact = artifact(
            in: original,
            matching: ["icc profile"],
            extensions: ["icc", "icm"]
        ) else {
            continuation.finish(throwing: CalibrationWorkflowError.missingProfileArtifact)
            return
        }
        let profileURL = profileArtifact.url

        session.activationVerificationAttempt = ActivationVerificationAttempt(
            startedAt: persistenceTimestamp()
        )
        session.verification = nil
        session.verificationAssessment = nil
        session.failureMessage = nil
        session.updatedAt = Date()
        do {
            try await store.save(session)
            continuation.yield(.sessionUpdated(session))
        } catch {
            continuation.finish(throwing: error)
            return
        }

        do {
            try validateProfileArtifactIdentity(profileArtifact)
        } catch {
            if let index = session.artifacts.firstIndex(where: { $0.id == profileArtifact.id }) {
                session.artifacts[index].isComplete = false
            }
            session.activationVerificationAttempt?.status = .failed
            session.activationVerificationAttempt?.finishedAt = persistenceTimestamp()
            session.activationVerificationAttempt?.errorMessage = error.localizedDescription
            session.activationVerificationAttempt?.restoredBeforeProfile = true
            session.activationVerificationAttempt?.restoredBeforeProfileAt = persistenceTimestamp()
            session.failureMessage = error.localizedDescription
            try? await emit(.warning(error.localizedDescription), session: &session, continuation: continuation)
            try? await emit(.stageChanged(.failed), session: &session, continuation: continuation)
            continuation.finish(throwing: error)
            return
        }

        do {
            let probe = await engine.probe()
            guard probe.isAvailable else {
                throw CalibrationWorkflowError.engineUnavailable(probe.diagnostic)
            }
            try await requireConnectedHardware(
                display: display,
                instrument: instrument,
                unavailableMessage: "Reconnect the i1Display used for this session before activating and verifying the generated profile."
            )

            try await emit(.stageChanged(.installingProfile), session: &session, continuation: continuation)
            try await activate(
                profileURL: profileURL,
                display: display,
                session: &session,
                continuation: continuation
            )

            try Task.checkCancellation()
            try await requireConnectedHardware(
                display: display,
                instrument: instrument,
                unavailableMessage: "The i1Display disconnected before verification. LumaProfile will restore the Before profile; reconnect the meter before trying again."
            )
            session.activationVerificationAttempt?.verificationStartedAt = persistenceTimestamp()
            try await emit(.stageChanged(.verifying), session: &session, continuation: continuation)
            let verificationRequest = VerificationRequest(
                sessionDirectory: profileURL.deletingLastPathComponent(),
                display: display,
                instrument: instrument,
                profileURL: session.installation?.installedProfileURL ?? profileURL,
                target: target,
                correction: session.correction,
                mode: session.measurementMode ?? .auto
            )
            try await consume(
                engine.verify(verificationRequest),
                session: &session,
                continuation: continuation
            )
            try Task.checkCancellation()
            guard session.verification != nil,
                  session.verificationAssessment != nil else {
                throw CalibrationWorkflowError.missingVerificationReport
            }
            session.activationVerificationAttempt?.status = .verified
            session.activationVerificationAttempt?.finishedAt = persistenceTimestamp()
            session.activationVerificationAttempt?.errorMessage = nil
            session.activationVerificationAttempt?.restoredBeforeProfile = false
            session.activationVerificationAttempt?.restoredBeforeProfileAt = nil
            try await emit(.stageChanged(.completed), session: &session, continuation: continuation)
            continuation.finish()
        } catch {
            let wasCancelled = Task.isCancelled || error is CancellationError
            session.activationVerificationAttempt?.status = wasCancelled ? .cancelled : .failed
            session.activationVerificationAttempt?.finishedAt = persistenceTimestamp()
            session.activationVerificationAttempt?.errorMessage = wasCancelled
                ? "Activation and verification were cancelled."
                : error.localizedDescription
            session.activationVerificationAttempt?.restoredBeforeProfile = nil
            session.activationVerificationAttempt?.restoredBeforeProfileAt = nil
            session.verification = nil
            session.verificationAssessment = nil
            session.updatedAt = Date()
            try? await store.save(session)
            continuation.yield(.sessionUpdated(session))

            let rollbackSucceeded = await rollbackInstalledProfile(session: &session, display: display)
            session.activationVerificationAttempt?.restoredBeforeProfile = rollbackSucceeded
            session.activationVerificationAttempt?.restoredBeforeProfileAt = rollbackSucceeded
                ? persistenceTimestamp()
                : nil
            let terminalStage: WorkflowStage
            let warning: String
            if rollbackSucceeded {
                terminalStage = .completed
                warning = wasCancelled
                    ? "Activation and verification were cancelled. The Before profile was restored; the generated profile remains available and inactive."
                    : "Activation or verification failed: \(error.localizedDescription) The Before profile was restored."
            } else {
                terminalStage = .interrupted
                session.failureMessage = "\(error.localizedDescription) Automatic rollback or calibration reload failed; use Restore Before from session history."
                warning = session.failureMessage ?? error.localizedDescription
            }
            do {
                try await persistProtectedTerminalState(
                    terminalStage,
                    warning: warning,
                    session: &session,
                    continuation: continuation
                )
            } catch let persistenceError {
                continuation.yield(.sessionUpdated(session))
                continuation.finish(throwing: CalibrationWorkflowError.protectedStatePersistenceFailed(
                    operationFailure: error.localizedDescription,
                    persistenceFailure: persistenceError.localizedDescription
                ))
                return
            }
            if wasCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    private func activate(
        profileURL: URL,
        display: PhysicalDisplay,
        session: inout CalibrationSession,
        continuation: AsyncThrowingStream<CalibrationWorkflowUpdate, Error>.Continuation
    ) async throws {
        guard let baseline = session.profileBaseline,
              baseline.displayFingerprint == display.fingerprint else {
            throw CalibrationWorkflowError.missingProfileBaseline
        }

        var record = try await installer.prepareActivation(
            profileURL: profileURL,
            for: display,
            expectedCurrentProfileURL: baseline.activeProfileURL
        )
        record.activationStatus = .activationPending
        record.activatedAt = nil
        session.installation = record
        session.updatedAt = Date()

        // This atomic save is deliberately before the ColorSync mutation. If it
        // fails, activation is not attempted and the existing association remains.
        try await store.save(session)
        continuation.yield(.sessionUpdated(session))
        try await emit(
            .message("Activation recovery data was saved before changing the selected display profile."),
            session: &session,
            continuation: continuation
        )

        do {
            try await installer.activate(record, for: display)
        } catch {
            if let recoverable = error as? any ProfileInstallationRecoveryProviding {
                record = recoverable.recoveryRecord
                record.activationStatus = .restorationRequired
                session.installation = record
            } else {
                session.installation = nil
            }
            session.updatedAt = Date()
            try await store.save(session)
            continuation.yield(.sessionUpdated(session))
            throw error
        }

        record.activationStatus = .active
        record.activatedAt = persistenceTimestamp()
        session.installation = record
        session.activationVerificationAttempt?.profileActivatedAt = record.activatedAt
        session.updatedAt = Date()
        try await store.save(session)
        continuation.yield(.sessionUpdated(session))
        try await emit(
            .message("The After profile is now active on \(display.name)."),
            session: &session,
            continuation: continuation
        )
    }

    private func restoreDisplayCalibrationIfNeeded(
        _ needed: Bool,
        display: PhysicalDisplay,
        sessionDirectory: URL?
    ) async -> Bool {
        guard needed else { return true }
        guard let sessionDirectory else { return false }
        let engine = self.engine
        let restoration = Task.detached {
            try await engine.restoreActiveProfileCalibration(
                for: display,
                sessionDirectory: sessionDirectory
            )
        }
        do {
            try await restoration.value
            return true
        } catch {
            return false
        }
    }

    private func persistenceTimestamp() -> Date {
        let now = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: (now * 1_000).rounded(.down) / 1_000)
    }

    private func validateProfileArtifactIdentity(_ artifact: SessionArtifact) throws {
        guard let expectedHash = artifact.sha256, expectedHash.count == 64 else {
            throw CalibrationWorkflowError.missingProfileHash
        }
        let actualHash = try LumaSHA256.hexDigest(of: artifact.url)
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw CalibrationWorkflowError.profileArtifactChanged
        }
    }

    private func sameProfileAssociation(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            true
        case (.some(let lhs), .some(let rhs)):
            lhs.resolvingSymlinksInPath().standardizedFileURL
                == rhs.resolvingSymlinksInPath().standardizedFileURL
        default:
            false
        }
    }

    private static func isTerminal(_ stage: WorkflowStage) -> Bool {
        switch stage {
        case .idle, .completed, .cancelled, .failed, .interrupted:
            true
        default:
            false
        }
    }

    private func requireConnectedHardware(
        display: PhysicalDisplay,
        instrument: InstrumentDescriptor,
        unavailableMessage: String
    ) async throws {
        try await engine.validateDisplayMapping(for: display)
        let currentInstruments = try await engine.discoverInstruments()
        guard currentInstruments.contains(where: {
            $0.id == instrument.id
                && $0.model == instrument.model
                && $0.isI1D3Family
        }) else {
            throw CalibrationWorkflowError.instrumentUnavailable(unavailableMessage)
        }
    }

    private func consume(
        _ events: AsyncThrowingStream<CalibrationEvent, Error>,
        session: inout CalibrationSession,
        continuation: AsyncThrowingStream<CalibrationWorkflowUpdate, Error>.Continuation
    ) async throws {
        for try await event in events {
            try Task.checkCancellation()
            // A child engine stream completes one pipeline operation. Only the
            // workflow itself may mark the overall session completed.
            if case .stageChanged(.completed) = event { continue }
            try await emit(event, session: &session, continuation: continuation)
        }
    }

    private func emit(
        _ event: CalibrationEvent,
        session: inout CalibrationSession,
        continuation: AsyncThrowingStream<CalibrationWorkflowUpdate, Error>.Continuation
    ) async throws {
        apply(event, to: &session)
        session.updatedAt = Date()
        try await store.append(event: event, sessionID: session.id)
        try await store.save(session)
        continuation.yield(.event(event))
        continuation.yield(.sessionUpdated(session))
    }

    private func apply(_ event: CalibrationEvent, to session: inout CalibrationSession) {
        switch event {
        case .stageChanged(let stage):
            session.state = stage
        case .artifactCreated(let artifact):
            if !session.artifacts.contains(where: { $0.url == artifact.url }) {
                session.artifacts.append(artifact)
            }
        case .verificationCompleted(let report):
            session.verification = report
            let targetGamma: Double?
            if case .gamma(let gamma) = session.target?.transferFunction {
                targetGamma = gamma
            } else {
                targetGamma = nil
            }
            let criteria = VerificationCriteria.applicationDefault
            session.verificationAssessment = criteria.assessment(
                for: report.metrics,
                targetLuminance: session.target?.luminanceCDM2,
                targetGamma: targetGamma,
                evaluatedAt: persistenceTimestamp()
            )
        case .progress(let completed, let total):
            if session.state == .generatingPatchSet,
               session.actualCharacterizationPatchCount == nil,
               completed == 0,
               let total,
               total > 0 {
                session.actualCharacterizationPatchCount = total
            }
        default:
            break
        }
    }

    private func rollbackInstalledProfile(
        session: inout CalibrationSession,
        display: PhysicalDisplay
    ) async -> Bool {
        guard let record = session.installation else { return true }
        do {
            try await installer.rollback(record, for: display)
            let directory = await store.sessionDirectory(for: session.id)
            try await engine.restoreActiveProfileCalibration(for: display, sessionDirectory: directory)
            session.installation = nil
            return true
        } catch {
            session.installation?.activationStatus = .restorationRequired
            return false
        }
    }

    /// Cleanup outcomes are safety-critical. Save the complete session first;
    /// only then append the human-readable journal records and publish the state.
    /// A persistence error is propagated so the app can remain open and fail closed.
    private func persistProtectedTerminalState(
        _ stage: WorkflowStage,
        warning: String?,
        session: inout CalibrationSession,
        continuation: AsyncThrowingStream<CalibrationWorkflowUpdate, Error>.Continuation
    ) async throws {
        session.state = stage
        session.updatedAt = Date()
        try await store.save(session)
        if let warning {
            try await store.append(event: .warning(warning), sessionID: session.id)
            continuation.yield(.event(.warning(warning)))
        }
        try await store.append(event: .stageChanged(stage), sessionID: session.id)
        continuation.yield(.event(.stageChanged(stage)))
        continuation.yield(.sessionUpdated(session))
    }

    private func artifactURL(
        in session: CalibrationSession,
        matching terms: [String],
        extensions: [String]
    ) -> URL? {
        artifact(in: session, matching: terms, extensions: extensions)?.url
    }

    private func artifact(
        in session: CalibrationSession,
        matching terms: [String],
        extensions: [String]
    ) -> SessionArtifact? {
        session.artifacts.last { artifact in
            let kind = artifact.kind.lowercased()
            let ext = artifact.url.pathExtension.lowercased()
            return artifact.isComplete
                && terms.contains(where: { kind.contains($0) })
                && extensions.contains(ext)
        }
    }

    private func profileFilename(for request: CalibrationWorkflowRequest) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let display = request.display.name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let target = request.target.name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return "\(display)-\(target).icc"
    }
}
