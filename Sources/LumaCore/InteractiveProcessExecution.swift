@preconcurrency import Foundation
import Darwin

public enum ArgyllPromptIdentifier: String, CaseIterable, Sendable {
    case instrumentPlacement = "instrument-placement"
    case calibrationPosition = "instrument-calibration-position"
    case measurementPosition = "instrument-measurement-position"
    case sensorPositionCorrection = "sensor-position-correction"
    case takeReading = "take-reading"
}

public struct ArgyllDetectedPrompt: Hashable, Sendable {
    public var identifier: ArgyllPromptIdentifier
    public var message: String

    public init(identifier: ArgyllPromptIdentifier, message: String) {
        self.identifier = identifier
        self.message = message
    }
}

public struct ArgyllPromptStateMachine: Sendable {
    public static let nonInteractiveAcknowledgement = Data([0x20, 0x0A])

    private var buffer = ""
    private var lastPrompt: ArgyllPromptIdentifier?

    public init() {}

    public mutating func consume(_ data: Data) throws -> [ArgyllDetectedPrompt] {
        let chunk = String(decoding: data, as: UTF8.self)
        buffer.append(chunk)
        if buffer.count > 16_384 {
            buffer = String(buffer.suffix(16_384))
        }

        let tail = String(buffer.suffix(2_048))
        let normalized = tail.lowercased()
        let detected: ArgyllPromptIdentifier?

        if normalized.contains("sensor being in the wrong position") {
            detected = .sensorPositionCorrection
        } else if normalized.contains("calibration position")
            || normalized.contains("calibration tile")
            || matches(#"place (?:the )?(?:instrument|sensor).{0,100}(?:calibration|white tile)"#, in: normalized)
        {
            detected = .calibrationPosition
        } else if normalized.contains("measurement position")
            || matches(#"set (?:the )?(?:instrument|sensor).{0,80}(?:measurement|display) position"#, in: normalized)
        {
            detected = .measurementPosition
        } else if matches(#"place (?:the )?(?:instrument|sensor|meter).{0,120}(?:on|against|over).{0,80}(?:display|screen|test window)"#, in: normalized) {
            detected = .instrumentPlacement
        } else if matches(#"(?:press|hit).{0,60}(?:key|return|space).{0,80}(?:read|measure|continue)"#, in: normalized) {
            detected = .takeReading
        } else {
            detected = nil
        }

        if let detected {
            guard detected != lastPrompt else { return [] }
            lastPrompt = detected
            return [ArgyllDetectedPrompt(
                identifier: detected,
                message: userFacingMessage(for: detected)
            )]
        }

        if looksLikeUnknownPrompt(normalized) {
            throw ArgyllEngineError.unsafePrompt(promptExcerpt(from: tail))
        }
        return []
    }

    public mutating func didRespond(to identifier: ArgyllPromptIdentifier) {
        if lastPrompt == identifier {
            lastPrompt = nil
            buffer = ""
        }
    }

    public func permits(_ response: Data, for identifier: ArgyllPromptIdentifier) -> Bool {
        guard lastPrompt == identifier else { return false }
        return response == Self.nonInteractiveAcknowledgement
    }

    private func matches(_ pattern: String, in value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }

    private func looksLikeUnknownPrompt(_ value: String) -> Bool {
        let asksForInput = matches(#"(?:press|hit|enter|type|choose|select).{0,120}(?:key|return|number|choice|continue)\s*[:?]?\s*$"#, in: value)
        let question = matches(#"(?:continue|retry|abort|quit|proceed)\s*\??\s*$"#, in: value)
        let retry = matches(#"(?:any other key|press|hit).{0,120}retry\s*[:?]?\s*$"#, in: value)
        return asksForInput || question || retry
    }

    private func userFacingMessage(for identifier: ArgyllPromptIdentifier) -> String {
        switch identifier {
        case .instrumentPlacement:
            "Place the i1Display flat against the measurement window with its ambient diffuser swung away, then click Continue."
        case .calibrationPosition:
            "Move the meter to the calibration position requested by ArgyllCMS, then click Continue."
        case .measurementPosition:
            "Move the meter to its display measurement position, then click Continue."
        case .sensorPositionCorrection:
            "Swing the i1Display ambient diffuser away, place the sensor flat against the measurement window, then click Continue."
        case .takeReading:
            "Confirm the i1Display is positioned correctly, then click Continue to take the reading."
        }
    }

    private func promptExcerpt(from value: String) -> String {
        let lines = value
            .split(whereSeparator: \Character.isNewline)
            .suffix(4)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: " ").suffix(512))
    }
}

public actor FoundationInteractiveProcessSession: InteractiveProcessSession {
    private enum State {
        case idle
        case running
        case exited
    }

    private let stream: AsyncThrowingStream<InteractiveProcessEvent, Error>
    private let continuation: AsyncThrowingStream<InteractiveProcessEvent, Error>.Continuation
    private let terminationGracePeriod: Duration
    private var state: State = .idle
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutReaderTask: Task<Void, Never>?
    private var stderrReaderTask: Task<Void, Never>?
    private var promptMachine = ArgyllPromptStateMachine()
    private var pendingPrompt: ArgyllPromptIdentifier?
    private var timeoutTask: Task<Void, Never>?

    public init(terminationGracePeriod: Duration = .seconds(2)) {
        var captured: AsyncThrowingStream<InteractiveProcessEvent, Error>.Continuation?
        self.stream = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
        self.terminationGracePeriod = terminationGracePeriod
    }

    public var events: AsyncThrowingStream<InteractiveProcessEvent, Error> { stream }

    public func start(_ request: ProcessRequest) async throws {
        guard case .idle = state else {
            throw ProcessExecutionError.launchFailed("An interactive process session can only be started once.")
        }
        guard request.standardInput?.isEmpty != false else {
            throw ArgyllEngineError.unsafePrompt(
                "Interactive standard input must be sent only after an allowlisted prompt is detected."
            )
        }
        try validate(request)
        try Task.checkCancellation()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = request.executableURL.standardizedFileURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectoryURL.standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        environment.merge(request.environment) { _, requested in requested }
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { await self?.processExited(status) }
        }

        do {
            try process.run()
            state = .running
            stdoutReaderTask = Task.detached(priority: .utility) { [weak self] in
                while true {
                    let data = stdoutPipe.fileHandleForReading.availableData
                    guard !data.isEmpty else { return }
                    await self?.ingest(data, channel: .stdout)
                }
            }
            stderrReaderTask = Task.detached(priority: .utility) { [weak self] in
                while true {
                    let data = stderrPipe.fileHandleForReading.availableData
                    guard !data.isEmpty else { return }
                    await self?.ingest(data, channel: .stderr)
                }
            }
            if let timeout = request.timeout {
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        await self?.timeoutExpired(timeout)
                    } catch {
                        // Normal process exit cancels the deadline task.
                    }
                }
            }
        } catch {
            cleanupHandles()
            state = .exited
            continuation.finish(throwing: ProcessExecutionError.launchFailed(error.localizedDescription))
            throw ProcessExecutionError.launchFailed(error.localizedDescription)
        }
    }

    public func respond(toPrompt identifier: String, with response: Data) async throws {
        guard
            state == .running,
            let knownIdentifier = ArgyllPromptIdentifier(rawValue: identifier),
            pendingPrompt == knownIdentifier,
            promptMachine.permits(response, for: knownIdentifier),
            let stdinHandle
        else {
            throw ArgyllEngineError.unsafePrompt("Rejected response for prompt identifier '\(identifier)'.")
        }

        try ChildPipe.write(response, to: stdinHandle)
        promptMachine.didRespond(to: knownIdentifier)
        pendingPrompt = nil
    }

    public func cancel() async {
        guard state == .running, let process else {
            cleanupHandles()
            return
        }
        stdinHandle?.closeFile()
        stdinHandle = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        process.terminate()
        let identifier = process.processIdentifier
        let grace = terminationGracePeriod
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: grace)
            if process.isRunning, identifier > 0 {
                _ = Darwin.kill(identifier, SIGKILL)
            }
        }
    }

    private enum Channel { case stdout, stderr }

    private func ingest(_ data: Data, channel: Channel) {
        continuation.yield(channel == .stdout ? .stdout(data) : .stderr(data))
        do {
            for prompt in try promptMachine.consume(data) {
                guard pendingPrompt == nil else { continue }
                pendingPrompt = prompt.identifier
                continuation.yield(.prompt(identifier: prompt.identifier.rawValue, message: prompt.message))
            }
        } catch {
            continuation.finish(throwing: error)
            Task { await cancel() }
        }
    }

    private func processExited(_ status: Int32) async {
        guard state != .exited else { return }
        state = .exited
        timeoutTask?.cancel()
        timeoutTask = nil
        await stdoutReaderTask?.value
        await stderrReaderTask?.value
        stdoutReaderTask = nil
        stderrReaderTask = nil
        cleanupHandles()
        continuation.yield(.exited(status))
        continuation.finish()
    }

    private func timeoutExpired(_ timeout: Duration) {
        guard state == .running, let process else { return }
        continuation.finish(throwing: ProcessExecutionError.timedOut(timeout))
        stdinHandle?.closeFile()
        stdinHandle = nil
        process.terminate()
        let identifier = process.processIdentifier
        let grace = terminationGracePeriod
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: grace)
            if process.isRunning, identifier > 0 {
                _ = Darwin.kill(identifier, SIGKILL)
            }
        }
    }

    private func cleanupHandles() {
        timeoutTask?.cancel()
        timeoutTask = nil
        stdinHandle?.closeFile()
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func validate(_ request: ProcessRequest) throws {
        let fileManager = FileManager.default
        guard
            request.executableURL.isFileURL,
            request.executableURL.path.hasPrefix("/"),
            fileManager.isExecutableFile(atPath: request.executableURL.path)
        else { throw ProcessExecutionError.invalidExecutable(request.executableURL) }

        var isDirectory: ObjCBool = false
        guard
            request.workingDirectoryURL.isFileURL,
            request.workingDirectoryURL.path.hasPrefix("/"),
            fileManager.fileExists(atPath: request.workingDirectoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw ProcessExecutionError.invalidWorkingDirectory(request.workingDirectoryURL) }
    }
}
