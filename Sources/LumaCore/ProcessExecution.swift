@preconcurrency import Foundation
import Darwin
import Dispatch

public enum ProcessExecutionError: Error, LocalizedError, Sendable {
    case invalidExecutable(URL)
    case invalidWorkingDirectory(URL)
    case launchFailed(String)
    case timedOut(Duration)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable(let url):
            return "The executable is missing or is not executable: \(url.path)"
        case .invalidWorkingDirectory(let url):
            return "The process working directory is missing or is not a directory: \(url.path)"
        case .launchFailed(let message):
            return "The process could not be launched: \(message)"
        case .timedOut(let duration):
            return "The process exceeded its \(duration) timeout."
        case .cancelled:
            return "The process was cancelled."
        }
    }
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus = lock.withLock { () -> Int32? in
                if let status {
                    return status
                }
                self.continuation = continuation
                return nil
            }
            if let completedStatus {
                continuation.resume(returning: completedStatus)
            }
        }
    }

    func processDidExit(with status: Int32) {
        let continuation = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            self.status = status
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: status)
    }
}

private final class ProcessLifecycle: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timeoutTriggered = false
    private var cancellationTriggered = false

    init(process: Process) {
        self.process = process
    }

    var didTimeOut: Bool { lock.withLock { timeoutTriggered } }
    var wasCancelled: Bool { lock.withLock { cancellationTriggered } }

    func markTimedOutAndTerminate() {
        lock.withLock {
            guard process.isRunning else { return }
            timeoutTriggered = true
            process.terminate()
        }
    }

    func markCancelledAndTerminate() {
        lock.withLock {
            guard process.isRunning else { return }
            cancellationTriggered = true
            process.terminate()
        }
    }

    func forceTerminateIfRunning() {
        let identifier = lock.withLock { process.isRunning ? process.processIdentifier : 0 }
        if identifier > 0 {
            _ = Darwin.kill(identifier, SIGKILL)
        }
    }
}

public final class OneShotProcessRunner: ProcessExecuting, Sendable {
    private static let blockingIOQueue = DispatchQueue(
        label: "com.lumaprofile.process-io",
        qos: .utility,
        attributes: .concurrent
    )

    public let terminationGracePeriod: Duration

    public init(terminationGracePeriod: Duration = .seconds(2)) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()
        try validate(request)

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

        let lifecycle = ProcessLifecycle(process: process)
        let exitWaiter = ProcessExitWaiter()
        process.terminationHandler = { terminatedProcess in
            exitWaiter.processDidExit(with: terminatedProcess.terminationStatus)
        }
        let startedAt = Date()

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            stdinPipe.fileHandleForWriting.closeFile()
            throw ProcessExecutionError.launchFailed(error.localizedDescription)
        }
        let stdoutTask = Task.detached(priority: .utility) {
            await Self.readToEndOfFile(stdoutPipe.fileHandleForReading)
        }
        let stderrTask = Task.detached(priority: .utility) {
            await Self.readToEndOfFile(stderrPipe.fileHandleForReading)
        }

        if let standardInput = request.standardInput, !standardInput.isEmpty {
            stdinPipe.fileHandleForWriting.write(standardInput)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timeoutTask: Task<Void, Never>? = request.timeout.map { timeout in
            Task.detached(priority: .utility) { [terminationGracePeriod] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancellation means the child exited before the deadline.
                    return
                }
                lifecycle.markTimedOutAndTerminate()
                try? await Task.sleep(for: terminationGracePeriod)
                lifecycle.forceTerminateIfRunning()
            }
        }

        let exitCode: Int32 = await withTaskCancellationHandler {
            await exitWaiter.wait()
        } onCancel: {
            lifecycle.markCancelledAndTerminate()
            Task.detached(priority: .utility) { [terminationGracePeriod] in
                try? await Task.sleep(for: terminationGracePeriod)
                lifecycle.forceTerminateIfRunning()
            }
        }

        timeoutTask?.cancel()
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        let endedAt = Date()

        if lifecycle.wasCancelled || Task.isCancelled {
            throw ProcessExecutionError.cancelled
        }
        if lifecycle.didTimeOut, let timeout = request.timeout {
            throw ProcessExecutionError.timedOut(timeout)
        }

        return ProcessResult(
            executableURL: request.executableURL,
            arguments: request.arguments,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func readToEndOfFile(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            blockingIOQueue.async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private func validate(_ request: ProcessRequest) throws {
        let fileManager = FileManager.default
        guard
            request.executableURL.isFileURL,
            request.executableURL.path.hasPrefix("/"),
            fileManager.isExecutableFile(atPath: request.executableURL.path)
        else {
            throw ProcessExecutionError.invalidExecutable(request.executableURL)
        }

        var isDirectory: ObjCBool = false
        guard
            request.workingDirectoryURL.isFileURL,
            request.workingDirectoryURL.path.hasPrefix("/"),
            fileManager.fileExists(atPath: request.workingDirectoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ProcessExecutionError.invalidWorkingDirectory(request.workingDirectoryURL)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
