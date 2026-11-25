import CoreGraphics
import Foundation

public typealias InteractiveProcessSessionFactory = @Sendable () -> any InteractiveProcessSession

/// Reloads every display's calibration tables from the ColorSync profile
/// macOS already associates with it. No association is changed.
public typealias SystemCalibrationReloader = @Sendable () -> Void

public final actor ArgyllCalibrationEngine: CalibrationEngine {
    private let locator: any ArgyllInstallationLocating
    private let processExecutor: any ProcessExecuting
    private let interactiveSessionFactory: InteractiveProcessSessionFactory
    private let systemCalibrationReloader: SystemCalibrationReloader?

    private var cachedVersion: ArgyllVersion?
    private var activeWorkflowID: UUID?
    private var activeOneShotTask: Task<ProcessResult, Error>?
    private var activeInteractiveSession: (any InteractiveProcessSession)?
    private var activeCancellationRequested = false

    public init(
        explicitDirectory: URL? = nil,
        processExecutor: any ProcessExecuting = OneShotProcessRunner()
    ) {
        self.locator = ArgyllInstallationLocator(explicitDirectory: explicitDirectory)
        self.processExecutor = processExecutor
        self.interactiveSessionFactory = { FoundationInteractiveProcessSession() }
        self.systemCalibrationReloader = { CGDisplayRestoreColorSyncSettings() }
    }

    public init(
        locator: any ArgyllInstallationLocating,
        processExecutor: any ProcessExecuting = OneShotProcessRunner(),
        interactiveSessionFactory: @escaping InteractiveProcessSessionFactory = {
            FoundationInteractiveProcessSession()
        },
        systemCalibrationReloader: SystemCalibrationReloader? = nil
    ) {
        self.locator = locator
        self.processExecutor = processExecutor
        self.interactiveSessionFactory = interactiveSessionFactory
        self.systemCalibrationReloader = systemCalibrationReloader
    }

    public func probe() async -> EngineProbe {
        let discovery = locator.locate()
        var toolStatus: [String: Bool] = [:]
        if let installation = discovery.installation {
            for tool in ArgyllTool.allCases {
                toolStatus[tool.rawValue] = installation.executables[tool] != nil
            }
            do {
                let invocation = try ArgyllCommandBuilder.probe(installation: installation)
                let result = try await processExecutor.run(
                    invocation.processRequest(
                        workingDirectoryURL: FileManager.default.temporaryDirectory,
                        timeout: .seconds(15)
                    )
                )
                let raw = combinedOutput(result)
                let version = ArgyllVersionParser.parse(raw)
                cachedVersion = version
                let versionDiagnostic = version.map { "Detected ArgyllCMS \($0)." }
                    ?? "The tool set was found, but its version output was not recognized."
                return EngineProbe(
                    isAvailable: version != nil,
                    version: version?.description,
                    directory: installation.directory,
                    toolStatus: toolStatus,
                    diagnostic: "\(discovery.diagnostic) \(versionDiagnostic) \(bounded(raw, limit: 2_048))"
                )
            } catch {
                return EngineProbe(
                    isAvailable: false,
                    directory: installation.directory,
                    toolStatus: toolStatus,
                    diagnostic: "\(discovery.diagnostic) Version probe failed: \(error.localizedDescription)"
                )
            }
        }

        for tool in ArgyllTool.allCases {
            toolStatus[tool.rawValue] = discovery.candidates.contains { $0.toolStatus[tool] == true }
        }
        return EngineProbe(
            isAvailable: false,
            toolStatus: toolStatus,
            diagnostic: discovery.diagnostic
        )
    }

    public func discoverInstruments() async throws -> [InstrumentDescriptor] {
        let workflowID = try beginWorkflow()
        defer { endWorkflow(workflowID) }
        let installation = try requireInstallation()
        let invocation = try ArgyllCommandBuilder.instrumentDiscovery(installation: installation)
        let result = try await runOneShot(
            invocation,
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: .seconds(20)
        )
        let raw = combinedOutput(result)
        guard result.exitCode == 0 || !raw.isEmpty else {
            throw processFailure(invocation.tool, result)
        }
        let parsed = try ArgyllInstrumentListParser.parse(raw, version: cachedVersion)
        cachedVersion = parsed.detectedVersion ?? cachedVersion
        return parsed.instruments
    }

    public func discoverArgyllDisplays() async throws -> [ArgyllDisplayDescriptor] {
        let workflowID = try beginWorkflow()
        defer { endWorkflow(workflowID) }
        let installation = try requireInstallation()
        let invocation = ArgyllInvocation(
            tool: .dispcal,
            executableURL: try installation.executable(for: .dispcal),
            arguments: ["-?"]
        )
        let result = try await runOneShot(
            invocation,
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: .seconds(20)
        )
        let raw = combinedOutput(result)
        guard result.exitCode == 0 || !raw.isEmpty else { throw processFailure(.dispcal, result) }
        return try ArgyllDisplayListParser.parse(raw, version: cachedVersion)
    }

    public func validateDisplayMapping(for display: PhysicalDisplay) async throws {
        let workflowID = try beginWorkflow()
        defer { endWorkflow(workflowID) }
        let installation = try requireInstallation()
        try await validateCurrentDisplayMapping(
            display,
            using: .dispwin,
            installation: installation,
            workingDirectory: FileManager.default.temporaryDirectory,
            recordIn: nil
        )
    }

    public func measure(_ request: SpotMeasurementRequest) async throws -> Measurement {
        let workflowID = try beginWorkflow()
        defer { endWorkflow(workflowID) }
        try validateInstrument(request.instrument)
        try validateCorrection(request.correction)
        let installation = try requireInstallation()
        let invocation = try ArgyllCommandBuilder.spotMeasurement(installation: installation, request: request)
        let result = try await runSingleSpotMeasurement(
            invocation,
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: .seconds(90)
        )
        guard result.exitCode == 0 else { throw processFailure(.spotread, result) }
        return try ArgyllSpotMeasurementParser.parse(
            combinedOutput(result),
            version: cachedVersion,
            capturedAt: result.endedAt
        ).measurement
    }

    /// Keeps one `spotread` process and one open meter for the whole run.
    /// Launching a process per reading repeats instrument start-up each time,
    /// which is most of the delay between readings.
    public func measureContinuously(
        _ request: SpotMeasurementRequest,
        onReading: @escaping @Sendable (Measurement) async -> Bool
    ) async throws {
        let workflowID = try beginWorkflow()
        defer { endWorkflow(workflowID) }
        try validateInstrument(request.instrument)
        try validateCorrection(request.correction)
        let installation = try requireInstallation()
        let invocation = try ArgyllCommandBuilder.spotMeasurement(
            installation: installation,
            request: request,
            continuous: true
        )
        guard activeInteractiveSession == nil else {
            throw ArgyllEngineError.invalidRequest("Another interactive ArgyllCMS process is active.")
        }
        let session = interactiveSessionFactory()
        activeInteractiveSession = session
        let events = await session.events
        // Output since the last trigger: at most one reading.
        var pending = Data()
        var awaitingReading = false

        do {
            try await session.start(invocation.processRequest(
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                timeout: .seconds(1_800)
            ))
            try await withTaskCancellationHandler {
                readings: for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .stdout(let data), .stderr(let data):
                        try appendSpotMeasurementOutput(data, to: &pending)
                    case .prompt(let identifier, let message):
                        guard identifier == ArgyllPromptIdentifier.takeReading.rawValue else {
                            if identifier == ArgyllPromptIdentifier.sensorPositionCorrection.rawValue {
                                throw ArgyllEngineError.invalidRequest(
                                    "Remove or rotate the i1Display ambient diffuser, place the sensor flat on the display, and try again. \(message)"
                                )
                            }
                            throw ArgyllEngineError.invalidRequest(
                                "Live readings stopped before sending input because ArgyllCMS requested another hardware action: \(message)"
                            )
                        }
                        if awaitingReading {
                            // A new prompt without a parsable reading means the
                            // meter did not measure; the parser reports why.
                            let measurement = try ArgyllSpotMeasurementParser.parse(
                                String(decoding: pending, as: UTF8.self),
                                version: cachedVersion,
                                capturedAt: Date()
                            ).measurement
                            guard await onReading(measurement) else { break readings }
                        }
                        pending.removeAll(keepingCapacity: true)
                        awaitingReading = true
                        try await session.respond(
                            toPrompt: identifier,
                            with: ArgyllPromptStateMachine.nonInteractiveAcknowledgement
                        )
                    case .exited(let status):
                        throw ArgyllEngineError.invalidRequest(
                            "The meter session ended unexpectedly (exit \(status)). Reconnect the meter and try again."
                        )
                    }
                }
            } onCancel: {
                Task { await session.cancel() }
            }
        } catch {
            await session.cancel()
            if activeCancellationRequested || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
        await session.cancel()
    }

    public nonisolated func calibrate(
        _ request: CalibrationRequest
    ) -> AsyncThrowingStream<CalibrationEvent, Error> {
        makeEventStream { workflowID, continuation in
            try await self.performCalibration(request, workflowID: workflowID, continuation: continuation)
        }
    }

    public nonisolated func characterize(
        _ request: CharacterizationRequest
    ) -> AsyncThrowingStream<CharacterizationEvent, Error> {
        makeEventStream { workflowID, continuation in
            try await self.performCharacterization(request, workflowID: workflowID, continuation: continuation)
        }
    }

    public func buildProfile(_ request: ProfileBuildRequest) async throws -> ICCProfileArtifact {
        let workflowID = try beginWorkflow()
        defer { endWorkflow(workflowID) }
        let sessionDirectory = try prepareSessionDirectory(request.sessionDirectory)
        try validateInputFile(request.measurementURL, extensions: ["ti3"])
        try validateInputFile(request.calibrationURL, extensions: ["cal"])
        try ensureOutputDoesNotExist(request.outputURL)
        let installation = try requireInstallation()
        let invocation = try ArgyllCommandBuilder.colprof(installation: installation, request: request)
        let result = try await runOneShot(
            invocation,
            workingDirectory: sessionDirectory,
            timeout: .seconds(30 * 60)
        )
        _ = try record(result, label: "profile-colprof", in: sessionDirectory)
        guard result.exitCode == 0 else { throw processFailure(.colprof, result) }

        let validationMessages = try validateICCProfile(request.outputURL)
        let values = try request.outputURL.resourceValues(forKeys: [.fileSizeKey])
        let hash = try LumaSHA256.hexDigest(of: request.outputURL)
        return ICCProfileArtifact(
            url: request.outputURL,
            model: request.model,
            sizeBytes: Int64(values.fileSize ?? 0),
            sha256: hash,
            validationMessages: validationMessages
        )
    }

    public nonisolated func verify(
        _ request: VerificationRequest
    ) -> AsyncThrowingStream<VerificationEvent, Error> {
        makeEventStream { workflowID, continuation in
            try await self.performVerification(request, workflowID: workflowID, continuation: continuation)
        }
    }

    public func restoreActiveProfileCalibration(
        for display: PhysicalDisplay,
        sessionDirectory: URL
    ) async throws {
        let workflowID = try beginWorkflow()
        defer { endWorkflow(workflowID) }
        let directory = try prepareSessionDirectory(sessionDirectory)
        let installation = try requireInstallation()
        try await validateCurrentDisplayMapping(
            display,
            using: .dispwin,
            installation: installation,
            workingDirectory: directory,
            recordIn: directory
        )
        if let systemCalibrationReloader {
            // `dispwin -L` cannot read ICC v4 profiles, which is what macOS
            // associates with most displays: on real hardware it reported
            // "ICC V4 not supported", assumed a linear table and then failed to
            // set it. ColorSync reads every profile macOS accepts, so the
            // operating system reloads the calibration instead.
            systemCalibrationReloader()
            let logs = directory.appendingPathComponent("logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let note = "\(ISO8601DateFormatter().string(from: Date())) Asked ColorSync to reload display calibration from the currently associated profiles after validating Argyll display \(display.argyllDisplayIndex ?? 0).\n"
            let noteURL = logs.appendingPathComponent("restore-videolut-colorsync.txt")
            if let handle = try? FileHandle(forWritingTo: noteURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(note.utf8))
            } else {
                try Data(note.utf8).write(to: noteURL, options: .atomic)
            }
            return
        }
        let invocation = try ArgyllCommandBuilder.restoreActiveProfileCalibration(
            installation: installation,
            display: display
        )
        let result = try await runOneShot(
            invocation,
            workingDirectory: directory,
            timeout: .seconds(60)
        )
        _ = try record(result, label: "restore-videolut-dispwin", in: directory)
        guard result.exitCode == 0 else { throw processFailure(.dispwin, result) }
    }

    public func acknowledgeUserAction(id: String) async throws {
        guard let session = activeInteractiveSession else {
            throw ArgyllEngineError.invalidRequest("There is no active ArgyllCMS prompt to acknowledge.")
        }
        try await session.respond(
            toPrompt: id,
            with: ArgyllPromptStateMachine.nonInteractiveAcknowledgement
        )
    }

    public func cancelCurrentOperation() async {
        guard activeWorkflowID != nil else { return }
        activeCancellationRequested = true
        activeOneShotTask?.cancel()
        if let session = activeInteractiveSession {
            await session.cancel()
        }
    }

    private nonisolated func makeEventStream(
        operation: @escaping @Sendable (
            UUID,
            AsyncThrowingStream<CalibrationEvent, Error>.Continuation
        ) async throws -> Void
    ) -> AsyncThrowingStream<CalibrationEvent, Error> {
        AsyncThrowingStream { continuation in
            let workflowID = UUID()
            let task = Task {
                do {
                    try await operation(workflowID, continuation)
                    continuation.finish()
                } catch {
                    if isOperationCancellation(error) {
                        continuation.yield(.stageChanged(.cancelled))
                    } else {
                        continuation.yield(.stageChanged(.failed))
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task { await self.cancelWorkflow(workflowID) }
            }
        }
    }

    private func performCalibration(
        _ request: CalibrationRequest,
        workflowID: UUID,
        continuation: AsyncThrowingStream<CalibrationEvent, Error>.Continuation
    ) async throws {
        try beginWorkflow(workflowID)
        defer { endWorkflow(workflowID) }
        continuation.yield(.stageChanged(.preflighting))
        try validateInstrument(request.instrument)
        try validateCorrection(request.correction)
        _ = try ArgyllCommandBuilder.requiredDisplayIndex(request.display)
        let sessionDirectory = try prepareSessionDirectory(request.sessionDirectory)
        let installation = try requireInstallation()
        try await validateCurrentDisplayMapping(
            request.display,
            using: .dispcal,
            installation: installation,
            workingDirectory: sessionDirectory,
            recordIn: sessionDirectory
        )
        let outputBase = sessionDirectory.appendingPathComponent("calibration", isDirectory: false)
        let calibrationURL = outputBase.appendingPathExtension("cal")
        try ensureOutputDoesNotExist(calibrationURL)

        let invocation = try ArgyllCommandBuilder.dispcal(
            installation: installation,
            request: request,
            outputBaseURL: outputBase
        )
        continuation.yield(.stageChanged(.awaitingMeterPlacement))
        continuation.yield(.message("Waiting for ArgyllCMS to request confirmed meter placement."))
        continuation.yield(.stageChanged(.calibrating))
        let result = try await runInteractive(
            invocation,
            workingDirectory: sessionDirectory,
            timeout: .seconds(2 * 60 * 60),
            continuation: continuation
        )
        _ = try record(result, label: "calibration-dispcal", in: sessionDirectory)
        guard result.exitCode == 0 else { throw processFailure(.dispcal, result) }
        try validateConsoleOutput(for: .dispcal, result: result)
        let artifact = try artifact(kind: "calibration", url: calibrationURL)
        continuation.yield(.artifactCreated(artifact))
        continuation.yield(.stageChanged(.completed))
    }

    private func performCharacterization(
        _ request: CharacterizationRequest,
        workflowID: UUID,
        continuation: AsyncThrowingStream<CalibrationEvent, Error>.Continuation
    ) async throws {
        try beginWorkflow(workflowID)
        defer { endWorkflow(workflowID) }
        continuation.yield(.stageChanged(.preflighting))
        try validateInstrument(request.instrument)
        try validateCorrection(request.correction)
        _ = try ArgyllCommandBuilder.requiredDisplayIndex(request.display)
        try validateInputFile(request.calibrationURL, extensions: ["cal"])
        let sessionDirectory = try prepareSessionDirectory(request.sessionDirectory)
        let installation = try requireInstallation()
        let base = sessionDirectory.appendingPathComponent("characterization", isDirectory: false)
        let targetURL = base.appendingPathExtension("ti1")
        let measurementURL = base.appendingPathExtension("ti3")
        try ensureOutputDoesNotExist(targetURL)
        try ensureOutputDoesNotExist(measurementURL)
        continuation.yield(.stageChanged(.generatingPatchSet))
        let targetInvocation = try ArgyllCommandBuilder.targen(
            installation: installation,
            preset: request.preset,
            outputBaseURL: base
        )
        let targetResult = try await runOneShot(
            targetInvocation,
            workingDirectory: sessionDirectory,
            timeout: .seconds(5 * 60)
        )
        _ = try record(targetResult, label: "characterization-targen", in: sessionDirectory)
        guard targetResult.exitCode == 0 else { throw processFailure(.targen, targetResult) }
        let targetArtifact = try artifact(kind: "characterization-target", url: targetURL)
        continuation.yield(.artifactCreated(targetArtifact))
        if let patchCount = try? patchCount(in: targetURL) {
            continuation.yield(.progress(completed: 0, total: patchCount))
        }

        try await validateCurrentDisplayMapping(
            request.display,
            using: .dispread,
            installation: installation,
            workingDirectory: sessionDirectory,
            recordIn: sessionDirectory
        )
        continuation.yield(.stageChanged(.awaitingMeterPlacement))
        let readInvocation = try ArgyllCommandBuilder.dispread(
            installation: installation,
            request: request,
            inputOutputBaseURL: base
        )
        continuation.yield(.stageChanged(.characterizing))
        let readResult = try await runInteractive(
            readInvocation,
            workingDirectory: sessionDirectory,
            timeout: .seconds(4 * 60 * 60),
            continuation: continuation
        )
        _ = try record(readResult, label: "characterization-dispread", in: sessionDirectory)
        guard readResult.exitCode == 0 else { throw processFailure(.dispread, readResult) }
        try validateConsoleOutput(for: .dispread, result: readResult)
        continuation.yield(.artifactCreated(try artifact(kind: "characterization-measurements", url: measurementURL)))
        continuation.yield(.stageChanged(.completed))
    }

    private func performVerification(
        _ request: VerificationRequest,
        workflowID: UUID,
        continuation: AsyncThrowingStream<CalibrationEvent, Error>.Continuation
    ) async throws {
        try beginWorkflow(workflowID)
        defer { endWorkflow(workflowID) }
        continuation.yield(.stageChanged(.preflighting))
        try validateInstrument(request.instrument)
        try validateCorrection(request.correction)
        _ = try ArgyllCommandBuilder.requiredDisplayIndex(request.display)
        try validateInputFile(request.profileURL, extensions: ["icc", "icm"])
        _ = try validateICCProfile(request.profileURL)
        let sessionDirectory = try prepareSessionDirectory(request.sessionDirectory)
        let installation = try requireInstallation()
        let base = sessionDirectory.appendingPathComponent("verification", isDirectory: false)
        let targetURL = base.appendingPathExtension("ti1")
        let measurementURL = base.appendingPathExtension("ti3")
        try ensureOutputDoesNotExist(targetURL)
        try ensureOutputDoesNotExist(measurementURL)
        continuation.yield(.stageChanged(.generatingPatchSet))
        let targetInvocation = try ArgyllCommandBuilder.verificationTargen(
            installation: installation,
            outputBaseURL: base
        )
        let targetResult = try await runOneShot(
            targetInvocation,
            workingDirectory: sessionDirectory,
            timeout: .seconds(5 * 60)
        )
        _ = try record(targetResult, label: "verification-targen", in: sessionDirectory)
        guard targetResult.exitCode == 0 else { throw processFailure(.targen, targetResult) }
        continuation.yield(.artifactCreated(try artifact(kind: "verification-target", url: targetURL)))

        try await validateCurrentDisplayMapping(
            request.display,
            using: .dispread,
            installation: installation,
            workingDirectory: sessionDirectory,
            recordIn: sessionDirectory
        )
        continuation.yield(.stageChanged(.awaitingMeterPlacement))
        let readInvocation = try ArgyllCommandBuilder.verificationDispread(
            installation: installation,
            request: request,
            inputOutputBaseURL: base
        )
        continuation.yield(.stageChanged(.verifying))
        let readResult = try await runInteractive(
            readInvocation,
            workingDirectory: sessionDirectory,
            timeout: .seconds(2 * 60 * 60),
            continuation: continuation
        )
        _ = try record(readResult, label: "verification-dispread", in: sessionDirectory)
        guard readResult.exitCode == 0 else { throw processFailure(.dispread, readResult) }
        try validateConsoleOutput(for: .dispread, result: readResult)
        continuation.yield(.artifactCreated(try artifact(kind: "verification-measurements", url: measurementURL)))

        let checkInvocation = try ArgyllCommandBuilder.profcheck(
            installation: installation,
            measurementURL: measurementURL,
            profileURL: request.profileURL
        )
        let checkResult = try await runOneShot(
            checkInvocation,
            workingDirectory: sessionDirectory,
            timeout: .seconds(15 * 60)
        )
        let checkLogs = try record(checkResult, label: "verification-profcheck", in: sessionDirectory)
        guard checkResult.exitCode == 0 else { throw processFailure(.profcheck, checkResult) }
        let report = try ArgyllVerificationParser.parse(
            profcheckOutput: combinedOutput(checkResult),
            measurementData: Data(contentsOf: measurementURL),
            target: request.target,
            version: cachedVersion,
            measuredAt: checkResult.endedAt
        )
        continuation.yield(.artifactCreated(try artifact(kind: "verification-profcheck-output", url: checkLogs.combined)))
        continuation.yield(.verificationCompleted(report))
        continuation.yield(.message(
            "Verification: average ΔE00 \(format(report.metrics.averageDeltaE2000)), "
                + "95th percentile \(format(report.metrics.percentile95DeltaE2000)), "
                + "maximum \(format(report.metrics.maximumDeltaE2000))."
        ))
        continuation.yield(.stageChanged(.completed))
    }

    private func beginWorkflow() throws -> UUID {
        let id = UUID()
        try beginWorkflow(id)
        return id
    }

    private func beginWorkflow(_ id: UUID) throws {
        guard activeWorkflowID == nil else {
            throw ArgyllEngineError.invalidRequest("Another ArgyllCMS operation is already active.")
        }
        activeWorkflowID = id
        activeCancellationRequested = false
    }

    private func endWorkflow(_ id: UUID) {
        guard activeWorkflowID == id else { return }
        activeOneShotTask = nil
        activeInteractiveSession = nil
        activeWorkflowID = nil
        activeCancellationRequested = false
    }

    private func runOneShot(
        _ invocation: ArgyllInvocation,
        workingDirectory: URL,
        timeout: Duration
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let executor = processExecutor
        let request = invocation.processRequest(workingDirectoryURL: workingDirectory, timeout: timeout)
        let task = Task { try await executor.run(request) }
        activeOneShotTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            activeOneShotTask = nil
            if activeCancellationRequested { throw CancellationError() }
            return result
        } catch {
            activeOneShotTask = nil
            if activeCancellationRequested || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func runInteractive(
        _ invocation: ArgyllInvocation,
        workingDirectory: URL,
        timeout: Duration,
        continuation: AsyncThrowingStream<CalibrationEvent, Error>.Continuation
    ) async throws -> ProcessResult {
        guard activeInteractiveSession == nil else {
            throw ArgyllEngineError.invalidRequest("Another interactive ArgyllCMS process is active.")
        }
        let session = interactiveSessionFactory()
        activeInteractiveSession = session
        let startedAt = Date()
        var stdout = Data()
        var stderr = Data()
        var stdoutParser = ArgyllConsoleStreamParser()
        var stderrParser = ArgyllConsoleStreamParser()
        var exitCode: Int32?
        let events = await session.events

        do {
            try await session.start(
                invocation.processRequest(workingDirectoryURL: workingDirectory, timeout: timeout)
            )
            try await withTaskCancellationHandler {
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .stdout(let data):
                        stdout.append(data)
                        emitConsoleEvents(
                            stdoutParser.consume(data),
                            tool: invocation.tool,
                            channel: "stdout",
                            continuation: continuation
                        )
                    case .stderr(let data):
                        stderr.append(data)
                        emitConsoleEvents(
                            stderrParser.consume(data),
                            tool: invocation.tool,
                            channel: "stderr",
                            continuation: continuation
                        )
                    case .prompt(let identifier, let message):
                        continuation.yield(.userActionRequired(UserActionRequest(id: identifier, message: message)))
                    case .exited(let status): exitCode = status
                    }
                }
            } onCancel: {
                Task { await session.cancel() }
            }
        } catch {
            await session.cancel()
            activeInteractiveSession = nil
            if activeCancellationRequested || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }

        emitConsoleEvents(
            stdoutParser.finish(),
            tool: invocation.tool,
            channel: "stdout",
            continuation: continuation
        )
        emitConsoleEvents(
            stderrParser.finish(),
            tool: invocation.tool,
            channel: "stderr",
            continuation: continuation
        )
        activeInteractiveSession = nil
        if activeCancellationRequested { throw CancellationError() }
        guard let exitCode else {
            throw ProcessExecutionError.launchFailed("The interactive process ended without an exit status.")
        }
        return ProcessResult(
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            startedAt: startedAt,
            endedAt: Date(),
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// `spotread -O` still waits for a console trigger. Keeping stdin closed causes
    /// ArgyllCMS to treat EOF as repeated input on some device-error paths, so a
    /// quick reading must use the same prompt-gated transport as calibration.
    private func runSingleSpotMeasurement(
        _ invocation: ArgyllInvocation,
        workingDirectory: URL,
        timeout: Duration
    ) async throws -> ProcessResult {
        guard activeInteractiveSession == nil else {
            throw ArgyllEngineError.invalidRequest("Another interactive ArgyllCMS process is active.")
        }
        let session = interactiveSessionFactory()
        activeInteractiveSession = session
        let startedAt = Date()
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
        var didTriggerReading = false
        let events = await session.events

        do {
            try await session.start(
                invocation.processRequest(workingDirectoryURL: workingDirectory, timeout: timeout)
            )
            try await withTaskCancellationHandler {
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .stdout(let data):
                        try appendSpotMeasurementOutput(data, to: &stdout)
                    case .stderr(let data):
                        try appendSpotMeasurementOutput(data, to: &stderr)
                    case .prompt(let identifier, let message):
                        guard identifier == ArgyllPromptIdentifier.takeReading.rawValue else {
                            if identifier == ArgyllPromptIdentifier.sensorPositionCorrection.rawValue {
                                throw ArgyllEngineError.invalidRequest(
                                    "Remove or rotate the i1Display ambient diffuser, place the sensor flat on the display, and try again. \(message)"
                                )
                            }
                            throw ArgyllEngineError.invalidRequest(
                                "Quick Meter stopped before sending input because ArgyllCMS requested another hardware action: \(message)"
                            )
                        }
                        guard !didTriggerReading else {
                            throw ArgyllEngineError.invalidRequest(
                                "The i1Display did not complete the reading. Remove the ambient diffuser, place the sensor flat on the display, and try again."
                            )
                        }
                        didTriggerReading = true
                        try await session.respond(
                            toPrompt: identifier,
                            with: ArgyllPromptStateMachine.nonInteractiveAcknowledgement
                        )
                    case .exited(let status):
                        exitCode = status
                    }
                }
            } onCancel: {
                Task { await session.cancel() }
            }
        } catch {
            await session.cancel()
            activeInteractiveSession = nil
            if activeCancellationRequested || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }

        activeInteractiveSession = nil
        if activeCancellationRequested { throw CancellationError() }
        guard let exitCode else {
            throw ProcessExecutionError.launchFailed("The interactive spot measurement ended without an exit status.")
        }
        return ProcessResult(
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            startedAt: startedAt,
            endedAt: Date(),
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func appendSpotMeasurementOutput(_ data: Data, to output: inout Data) throws {
        let maximumBytes = 1_048_576
        guard data.count <= maximumBytes, output.count <= maximumBytes - data.count else {
            throw ArgyllEngineError.invalidRequest(
                "Quick Meter stopped because ArgyllCMS produced more than 1 MiB of output without completing a reading."
            )
        }
        output.append(data)
    }

    private func requireInstallation() throws -> ArgyllInstallation {
        let discovery = locator.locate()
        guard let installation = discovery.installation else {
            throw ArgyllEngineError.engineUnavailable(discovery.diagnostic)
        }
        return installation
    }

    /// Re-enumerates Argyll's display list immediately before any indexed
    /// display operation. The UI records both the confirmed index and the exact
    /// descriptor, so a topology change fails closed instead of sending patches
    /// or VideoLUT commands to whatever display later inherited that number.
    private func validateCurrentDisplayMapping(
        _ display: PhysicalDisplay,
        using tool: ArgyllTool,
        installation: ArgyllInstallation,
        workingDirectory: URL,
        recordIn recordDirectory: URL?
    ) async throws {
        let index = try ArgyllCommandBuilder.requiredDisplayIndex(display)
        guard let expectedDescription = display.argyllDisplayDescription?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !expectedDescription.isEmpty else {
            throw ArgyllEngineError.invalidRequest(
                "The selected display's ArgyllCMS mapping was not recorded. Refresh hardware, identify the display, and confirm its engine number again."
            )
        }

        let invocation = ArgyllInvocation(
            tool: tool,
            executableURL: try installation.executable(for: tool),
            arguments: ["-?"]
        )
        let result = try await runOneShot(
            invocation,
            workingDirectory: workingDirectory,
            timeout: .seconds(20)
        )
        if let recordDirectory {
            _ = try record(result, label: "validate-display-\(tool.rawValue)", in: recordDirectory)
        }
        let raw = combinedOutput(result)
        guard result.exitCode == 0 || !raw.isEmpty else {
            throw processFailure(tool, result)
        }
        let currentDisplays = try ArgyllDisplayListParser.parse(raw, version: cachedVersion)
        guard let current = currentDisplays.first(where: { $0.index == index }) else {
            throw ArgyllEngineError.invalidRequest(
                "ArgyllCMS display \(index) is no longer present. Refresh hardware, identify the intended display, and confirm its engine number again."
            )
        }
        guard current.description == expectedDescription else {
            throw ArgyllEngineError.invalidRequest(
                "The confirmed ArgyllCMS display mapping changed from '\(expectedDescription)' to '\(current.description)'. No display command was sent; refresh hardware and identify the display again."
            )
        }
    }

    private func cancelWorkflow(_ id: UUID) async {
        guard activeWorkflowID == id else { return }
        await cancelCurrentOperation()
    }

    private func validateInstrument(_ instrument: InstrumentDescriptor) throws {
        guard instrument.isI1D3Family else {
            throw ArgyllEngineError.invalidRequest(
                "LumaProfile P0 only enables measurement for a detected i1Display/i1D3-family instrument."
            )
        }
    }

    private func validateCorrection(_ correction: DisplayCorrection?) throws {
        guard let correction else { return }
        try validateInputFile(correction.importedURL, extensions: [correction.kind.rawValue])
        let currentHash = try LumaSHA256.hexDigest(of: correction.importedURL)
        guard currentHash.caseInsensitiveCompare(correction.sha256) == .orderedSame else {
            throw ArgyllEngineError.invalidRequest(
                "The imported correction no longer matches its recorded SHA-256; re-import it before measurement."
            )
        }
    }

    private func prepareSessionDirectory(_ url: URL) throws -> URL {
        guard
            url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains(".."), !url.path.utf8.contains(0)
        else { throw ArgyllEngineError.invalidRequest("A session directory must be an absolute local path without traversal.") }
        let standardized = url.standardizedFileURL
        try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        let values = try standardized.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard
            FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            values.isSymbolicLink != true
        else { throw ArgyllEngineError.invalidRequest("The session working directory is unavailable.") }
        return standardized
    }

    private func validateInputFile(_ url: URL, extensions: Set<String>) throws {
        guard
            url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains(".."),
            extensions.contains(url.pathExtension.lowercased()),
            !url.path.utf8.contains(0)
        else { throw ArgyllEngineError.invalidRequest("An input artifact path is invalid or uses an unexpected extension.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ArgyllEngineError.missingArtifact(url)
        }
    }

    private func ensureOutputDoesNotExist(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw ArgyllEngineError.invalidRequest("An output artifact path is invalid.")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            throw ArgyllEngineError.invalidRequest(
                "Refusing to overwrite the existing artifact at \(url.path); use a new session or output name."
            )
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else {
            throw ArgyllEngineError.invalidRequest("The output parent must be an existing, non-symbolic-link directory.")
        }
    }

    private func artifact(kind: String, url: URL) throws -> SessionArtifact {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArgyllEngineError.missingArtifact(url)
        }
        return SessionArtifact(kind: kind, url: url, sha256: try LumaSHA256.hexDigest(of: url))
    }

    private func patchCount(in url: URL) throws -> Int {
        let document = try ArgyllCGATSParser.parse(Data(contentsOf: url))
        return document.rows.count
    }

    private struct RecordedLogs {
        var stdout: URL
        var stderr: URL
        var combined: URL
        var command: URL
    }

    private struct CommandRecord: Codable {
        var executable: String
        var arguments: [String]
        var workingDirectory: String
        var environmentOverrides: [String: String]
        var startedAt: Date
        var endedAt: Date
        var exitCode: Int32
    }

    private func record(_ result: ProcessResult, label: String, in sessionDirectory: URL) throws -> RecordedLogs {
        let logs = sessionDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let suffix = FileManager.default.fileExists(atPath: logs.appendingPathComponent("\(label).command.json").path)
            ? "-\(UUID().uuidString.lowercased())"
            : ""
        let stdoutURL = logs.appendingPathComponent("\(label)\(suffix).stdout.txt")
        let stderrURL = logs.appendingPathComponent("\(label)\(suffix).stderr.txt")
        let combinedURL = logs.appendingPathComponent("\(label)\(suffix).output.txt")
        let commandURL = logs.appendingPathComponent("\(label)\(suffix).command.json")
        try result.stdout.write(to: stdoutURL, options: .atomic)
        try result.stderr.write(to: stderrURL, options: .atomic)
        try Data(combinedOutput(result).utf8).write(to: combinedURL, options: .atomic)
        let record = CommandRecord(
            executable: result.executableURL.path,
            arguments: result.arguments,
            workingDirectory: sessionDirectory.path,
            environmentOverrides: [
                "ARGYLL_NOT_INTERACTIVE": "1",
                "LC_ALL": "C",
                "LANG": "C",
            ],
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            exitCode: result.exitCode
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: commandURL, options: .atomic)
        return RecordedLogs(stdout: stdoutURL, stderr: stderrURL, combined: combinedURL, command: commandURL)
    }

    private func validateICCProfile(_ url: URL) throws -> [String] {
        try validateInputFile(url, extensions: ["icc", "icm"])
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? 0
        guard size >= 128, size <= 256 * 1_024 * 1_024 else {
            throw ArgyllEngineError.malformedArtifact(url, reason: "ICC files must be between 128 bytes and 256 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 128), header.count == 128 else {
            throw ArgyllEngineError.malformedArtifact(url, reason: "The 128-byte ICC header is truncated.")
        }
        let signature = String(decoding: header[36..<40], as: UTF8.self)
        guard signature == "acsp" else {
            throw ArgyllEngineError.malformedArtifact(url, reason: "The ICC 'acsp' signature is missing.")
        }
        let declaredSize = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard declaredSize >= 128, declaredSize <= UInt32(size) else {
            throw ArgyllEngineError.malformedArtifact(url, reason: "The ICC header declares an impossible profile size.")
        }
        var messages: [String] = ["ICC header and declared size are valid."]
        let profileClass = String(decoding: header[12..<16], as: UTF8.self)
        if profileClass != "mntr" {
            messages.append("Profile class is '\(profileClass)' rather than the expected display class 'mntr'.")
        }
        if let data = try? Data(contentsOf: url), data.range(of: Data("vcgt".utf8)) == nil {
            messages.append("Warning: the profile has no calibration curve (vcgt tag), so activating it will not apply the calibration.")
        }
        return messages
    }

    private func emitConsoleEvents(
        _ events: [ArgyllConsoleStreamEvent],
        tool: ArgyllTool,
        channel: String,
        continuation: AsyncThrowingStream<CalibrationEvent, Error>.Continuation
    ) {
        for event in events {
            switch event {
            case .progress(let completed, let total):
                continuation.yield(.progress(completed: completed, total: total))
            case .warning(let warning):
                continuation.yield(.warning(warning))
            case .message(let message):
                continuation.yield(.message(message))
            case .technical(let diagnostic):
                continuation.yield(.technicalLog(LogRecord(
                    level: "Argyll \(tool.rawValue) \(channel)",
                    message: diagnostic
                )))
            }
        }
    }

    private func validateConsoleOutput(
        for tool: ArgyllTool,
        result: ProcessResult
    ) throws {
        _ = try ArgyllConsoleParser.parse(
            tool: tool,
            rawOutput: combinedOutput(result),
            version: cachedVersion
        )
    }

    private func processFailure(_ tool: ArgyllTool, _ result: ProcessResult) -> ArgyllEngineError {
        .processFailed(
            tool: tool,
            exitCode: result.exitCode,
            output: bounded(combinedOutput(result), limit: 4_096)
        )
    }

    private func combinedOutput(_ result: ProcessResult) -> String {
        [result.stdoutString, result.stderrString].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func bounded(_ value: String, limit: Int) -> String {
        value.count <= limit ? value : String(value.suffix(limit))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private func isOperationCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let processError = error as? ProcessExecutionError {
        if case .cancelled = processError { return true }
    }
    return false
}
