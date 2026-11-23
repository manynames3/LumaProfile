import Foundation
import Testing
@testable import LumaCore

@Suite
struct ArgyllCalibrationEngineTests {
    @Test
    func quickMeasurementWaitsForKnownPromptThenTakesOneReading() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let executable = try makeSpotreadExecutable(
            in: directory,
            script: """
            #!/bin/sh
            printf '%s\n' 'Measure spot values, Version 3.5.0'
            printf '%s\n' 'Place instrument on spot to be measured,'
            printf '%s' 'Hit ESC or Q to exit, any other key to take a reading: '
            IFS= read -r trigger
            [ "${ARGYLL_NOT_INTERACTIVE:-}" = "1" ] || exit 90
            [ "$trigger" = " " ] || exit 91
            printf '\n%s\n' 'Result is XYZ: 19.0100 20.0000 21.7800, D50 Lab: 51.837 0.003 -0.006'
            printf '%s\n' 'Result is Yxy: 20.0000 0.312700 0.329000'
            printf '%s\n' 'CCT = 6504 K'
            """
        )
        let engine = makeEngine(executable: executable, directory: directory)

        let measurement = try await engine.measure(
            SpotMeasurementRequest(instrument: TestSupport.instrument(id: "1"))
        )

        #expect(measurement.luminanceCDM2 == 20)
        #expect(measurement.correlatedColorTemperature == 6_504)
        #expect(measurement.rawSource.contains("Measure spot values, Version 3.5.0"))
    }

    @Test
    func quickMeasurementStopsPromptlyOnWrongSensorPosition() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let executable = try makeSpotreadExecutable(
            in: directory,
            script: """
            #!/bin/sh
            printf '%s\n' 'Measure spot values, Version 3.5.0'
            printf '%s\n' 'Place instrument on spot to be measured,'
            printf '%s' 'Hit ESC or Q to exit, any other key to take a reading: '
            IFS= read -r trigger
            printf '\n%s\n' 'Spot read failed due to the sensor being in the wrong position'
            printf '%s\n' '(Ambient filter should be removed)'
            printf '%s' 'Correct position then hit Esc or Q to give up, any other key to retry:'
            IFS= read -r retry
            """
        )
        let engine = makeEngine(executable: executable, directory: directory)
        let started = ContinuousClock.now

        do {
            _ = try await engine.measure(
                SpotMeasurementRequest(instrument: TestSupport.instrument(id: "1"))
            )
            Issue.record("Expected the wrong sensor position to stop Quick Meter")
        } catch ArgyllEngineError.invalidRequest(let message) {
            #expect(message.contains("ambient diffuser"))
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test
    func calibrationStreamsChunkedConsoleEventsBeforeExitWithoutRepeatingThem() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let binaryDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let sessionDirectory = root.appending(path: "session", directoryHint: .isDirectory)
        let executable = try makeExecutable(
            named: "dispcal",
            in: binaryDirectory,
            script: "#!/bin/sh\nexit 0\n"
        )
        let installation = ArgyllInstallation(
            directory: binaryDirectory,
            executables: [.dispcal: executable]
        )
        let interactiveSession = ControlledInteractiveProcessSession()
        let engine = ArgyllCalibrationEngine(
            locator: SyntheticArgyllLocator(
                discovery: ArgyllInstallationDiscovery(
                    installation: installation,
                    candidates: [],
                    diagnostic: "Synthetic coherent ArgyllCMS installation."
                )
            ),
            processExecutor: SyntheticDisplayListExecutor(),
            interactiveSessionFactory: { interactiveSession }
        )
        let stream = engine.calibrate(CalibrationRequest(
            sessionDirectory: sessionDirectory,
            display: TestSupport.display(),
            instrument: TestSupport.instrument(id: "1"),
            target: .photography
        ))
        var iterator = stream.makeAsyncIterator()

        while let event = try await iterator.next() {
            if case .stageChanged(.calibrating) = event { break }
        }

        let firstChunk = Data("Patch 1 of ".utf8)
        let secondChunk = Data("12\rFirmware Date: synthetic diagnostic\n".utf8)
        await interactiveSession.emit(.stdout(firstChunk))
        await interactiveSession.emit(.stdout(secondChunk))

        let liveProgress = try #require(try await iterator.next())
        guard case .progress(let completed, let total) = liveProgress else {
            Issue.record("Expected progress while the process was still running")
            return
        }
        #expect(completed == 1)
        #expect(total == 12)

        let liveDiagnostic = try #require(try await iterator.next())
        guard case .technicalLog(let record) = liveDiagnostic else {
            Issue.record("Expected a live technical diagnostic")
            return
        }
        #expect(record.level == "Argyll dispcal stdout")
        #expect(record.message == "Firmware Date: synthetic diagnostic")
        #expect(await interactiveSession.didExit == false)

        let finalChunk = Data("Calibration complete; synthetic calibration.cal created.".utf8)
        let warningChunk = Data("Warning: synthetic target tolerance.\n".utf8)
        await interactiveSession.emit(.stdout(finalChunk))
        await interactiveSession.emit(.stderr(warningChunk))
        try Data("SYNTHETIC CALIBRATION ARTIFACT".utf8).write(
            to: sessionDirectory.appending(path: "calibration.cal")
        )
        await interactiveSession.exit(with: 0)

        var progressCount = 1
        var diagnosticCount = 1
        var completionCount = 0
        var warningCount = 0
        while let event = try await iterator.next() {
            switch event {
            case .progress(let value, let maximum) where value == 1 && maximum == 12:
                progressCount += 1
            case .technicalLog(let record) where record.message == "Firmware Date: synthetic diagnostic":
                diagnosticCount += 1
            case .message(let message) where message == "Calibration complete; synthetic calibration.cal created.":
                completionCount += 1
            case .warning(let warning) where warning == "Warning: synthetic target tolerance.":
                warningCount += 1
            default:
                break
            }
        }

        #expect(progressCount == 1)
        #expect(diagnosticCount == 1)
        #expect(completionCount == 1)
        #expect(warningCount == 1)

        let stdoutURL = sessionDirectory.appending(path: "logs/calibration-dispcal.stdout.txt")
        let stderrURL = sessionDirectory.appending(path: "logs/calibration-dispcal.stderr.txt")
        #expect(try Data(contentsOf: stdoutURL) == firstChunk + secondChunk + finalChunk)
        #expect(try Data(contentsOf: stderrURL) == warningChunk)
    }

    @Test
    func restoreActiveProfileCalibrationRunsSelectedDisplayDispwinAndRecordsRawOutput() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let binaryDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let sessionDirectory = root.appending(path: "session", directoryHint: .isDirectory)
        let executable = try makeExecutable(
            named: "dispwin",
            in: binaryDirectory,
            script: """
            #!/bin/sh
            if [ "$1" = "-?" ]; then
                printf '%s\n' 'Test display patch window, Set Video LUTs, Install profiles, Version 3.5.0'
                printf '%s\n' ' -d n Choose the display from the following list'
                printf '%s\n' "    1 = 'Synthetic Display at 0, 0, width 3840, height 2160'"
                exit 0
            fi
            printf '%s\n' "$@" > "$PWD/restore-arguments.txt"
            printf '%s\n' 'Synthetic dispwin restore output'
            printf '%s\n' 'Synthetic dispwin restore diagnostic' >&2
            exit 0
            """
        )
        let engine = makeEngine(tool: .dispwin, executable: executable, directory: binaryDirectory)

        try await engine.restoreActiveProfileCalibration(
            for: TestSupport.display(),
            sessionDirectory: sessionDirectory
        )

        let arguments = try String(
            contentsOf: sessionDirectory.appending(path: "restore-arguments.txt"),
            encoding: .utf8
        ).split(whereSeparator: \.isNewline).map(String.init)
        #expect(arguments == ["-v", "-d", "1", "-L"])
        let logs = sessionDirectory.appending(path: "logs", directoryHint: .isDirectory)
        #expect(try String(
            contentsOf: logs.appending(path: "restore-videolut-dispwin.stdout.txt"),
            encoding: .utf8
        ).contains("Synthetic dispwin restore output"))
        #expect(try String(
            contentsOf: logs.appending(path: "restore-videolut-dispwin.stderr.txt"),
            encoding: .utf8
        ).contains("Synthetic dispwin restore diagnostic"))
        let commandURL = logs.appending(path: "restore-videolut-dispwin.command.json")
        let command = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: commandURL)) as? [String: Any]
        )
        let environment = try #require(command["environmentOverrides"] as? [String: String])
        #expect(environment["ARGYLL_NOT_INTERACTIVE"] == "1")
    }

    @Test
    func restoreActiveProfileCalibrationRecordsAndPropagatesDispwinFailure() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let binaryDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let sessionDirectory = root.appending(path: "session", directoryHint: .isDirectory)
        let executable = try makeExecutable(
            named: "dispwin",
            in: binaryDirectory,
            script: """
            #!/bin/sh
            if [ "$1" = "-?" ]; then
                printf '%s\n' 'Test display patch window, Set Video LUTs, Install profiles, Version 3.5.0'
                printf '%s\n' ' -d n Choose the display from the following list'
                printf '%s\n' "    1 = 'Synthetic Display at 0, 0, width 3840, height 2160'"
                exit 0
            fi
            printf '%s\n' 'Synthetic restore failure' >&2
            exit 17
            """
        )
        let engine = makeEngine(tool: .dispwin, executable: executable, directory: binaryDirectory)

        do {
            try await engine.restoreActiveProfileCalibration(
                for: TestSupport.display(),
                sessionDirectory: sessionDirectory
            )
            Issue.record("Expected dispwin restoration failure")
        } catch ArgyllEngineError.processFailed(let tool, let exitCode, let output) {
            #expect(tool == .dispwin)
            #expect(exitCode == 17)
            #expect(output.contains("Synthetic restore failure"))
        }
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.appending(
            path: "logs/restore-videolut-dispwin.command.json"
        ).path))
    }

    @Test
    func restoreActiveProfileCalibrationPrefersSystemReloadOverDispwinLoad() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let binaryDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let sessionDirectory = root.appending(path: "session", directoryHint: .isDirectory)
        // Mirrors the shape seen on real hardware: listing works, `-L` fails.
        let executable = try makeExecutable(
            named: "dispwin",
            in: binaryDirectory,
            script: """
            #!/bin/sh
            if [ "$1" = "-?" ]; then
                printf '%s\n' 'Test display patch window, Set Video LUTs, Install profiles, Version 3.5.0'
                printf '%s\n' ' -d n Choose the display from the following list'
                printf '%s\n' "    1 = 'Synthetic Display at 0, 0, width 3840, height 2160'"
                exit 1
            fi
            printf '%s\n' 'Warning: ICC V4 not supported!' 'Dispwin: Error - Failed to set VideoLUTs' >&2
            exit 1
            """
        )
        let reloads = ReloadCounter()
        let engine = ArgyllCalibrationEngine(
            locator: SyntheticArgyllLocator(
                discovery: ArgyllInstallationDiscovery(
                    installation: ArgyllInstallation(
                        directory: binaryDirectory,
                        executables: [.dispwin: executable]
                    ),
                    candidates: [],
                    diagnostic: "Synthetic coherent ArgyllCMS installation."
                )
            ),
            systemCalibrationReloader: { reloads.increment() }
        )

        try await engine.restoreActiveProfileCalibration(
            for: TestSupport.display(),
            sessionDirectory: sessionDirectory
        )

        #expect(reloads.count == 1)
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.appending(
            path: "logs/restore-videolut-colorsync.txt"
        ).path))
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.appending(
            path: "logs/restore-videolut-dispwin.command.json"
        ).path))
    }

    @Test
    func restoreActiveProfileCalibrationRejectsStaleDisplayMappingBeforeVideoLUTCommand() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let binaryDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        let sessionDirectory = root.appending(path: "session", directoryHint: .isDirectory)
        let executable = try makeExecutable(
            named: "dispwin",
            in: binaryDirectory,
            script: """
            #!/bin/sh
            if [ "$1" = "-?" ]; then
                printf '%s\n' 'Test display patch window, Set Video LUTs, Install profiles, Version 3.5.0'
                printf '%s\n' ' -d n Choose the display from the following list'
                printf '%s\n' "    1 = 'Different Display at 0, 0, width 1920, height 1080'"
                exit 0
            fi
            printf '%s\n' "$@" > "$PWD/unexpected-videolut-command.txt"
            exit 0
            """
        )
        let engine = makeEngine(tool: .dispwin, executable: executable, directory: binaryDirectory)

        do {
            try await engine.restoreActiveProfileCalibration(
                for: TestSupport.display(),
                sessionDirectory: sessionDirectory
            )
            Issue.record("Expected stale display mapping rejection")
        } catch ArgyllEngineError.invalidRequest(let message) {
            #expect(message.contains("display mapping changed"))
            #expect(message.contains("No display command was sent"))
        }

        #expect(!FileManager.default.fileExists(
            atPath: sessionDirectory.appending(path: "unexpected-videolut-command.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: sessionDirectory.appending(path: "logs/validate-display-dispwin.command.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: sessionDirectory.appending(path: "logs/restore-videolut-dispwin.command.json").path
        ))
    }

    private func makeEngine(executable: URL, directory: URL) -> ArgyllCalibrationEngine {
        makeEngine(tool: .spotread, executable: executable, directory: directory)
    }

    private func makeEngine(
        tool: ArgyllTool,
        executable: URL,
        directory: URL
    ) -> ArgyllCalibrationEngine {
        let installation = ArgyllInstallation(
            directory: directory,
            executables: [tool: executable]
        )
        return ArgyllCalibrationEngine(
            locator: SyntheticArgyllLocator(
                discovery: ArgyllInstallationDiscovery(
                    installation: installation,
                    candidates: [],
                    diagnostic: "Synthetic coherent ArgyllCMS installation."
                )
            )
        )
    }

    private func makeSpotreadExecutable(in directory: URL, script: String) throws -> URL {
        try makeExecutable(named: "spotread", in: directory, script: script)
    }

    private func makeExecutable(named name: String, in directory: URL, script: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: name)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}

private struct SyntheticArgyllLocator: ArgyllInstallationLocating {
    var discovery: ArgyllInstallationDiscovery

    func locate() -> ArgyllInstallationDiscovery { discovery }
}

private struct SyntheticDisplayListExecutor: ProcessExecuting {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let stdout = """
        [SYNTHETIC TEST OUTPUT — NOT HARDWARE OUTPUT]
        Calibrate a Display, Version 3.5.0
         -d n Choose the display from the following list
            1 = 'Synthetic Display at 0, 0, width 3840, height 2160'
        """
        return ProcessResult(
            executableURL: request.executableURL,
            arguments: request.arguments,
            startedAt: .distantPast,
            endedAt: .distantPast,
            exitCode: 0,
            stdout: Data(stdout.utf8),
            stderr: Data()
        )
    }
}

private actor ControlledInteractiveProcessSession: InteractiveProcessSession {
    private let stream: AsyncThrowingStream<InteractiveProcessEvent, Error>
    private let continuation: AsyncThrowingStream<InteractiveProcessEvent, Error>.Continuation
    private(set) var didExit = false

    init() {
        var captured: AsyncThrowingStream<InteractiveProcessEvent, Error>.Continuation?
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured!
    }

    var events: AsyncThrowingStream<InteractiveProcessEvent, Error> { stream }

    func start(_ request: ProcessRequest) async throws {}

    func respond(toPrompt identifier: String, with response: Data) async throws {
        throw ArgyllEngineError.unsafePrompt("Synthetic session has no pending prompt.")
    }

    func cancel() async {
        continuation.finish(throwing: CancellationError())
    }

    func emit(_ event: InteractiveProcessEvent) {
        continuation.yield(event)
    }

    func exit(with status: Int32) {
        didExit = true
        continuation.yield(.exited(status))
        continuation.finish()
    }
}

private final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
