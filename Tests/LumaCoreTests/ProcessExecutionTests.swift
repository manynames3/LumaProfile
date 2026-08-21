import Foundation
import Testing
@testable import LumaCore

@Suite
struct ProcessExecutionTests {
    @Test
    func testCapturesStdoutStderrAndNonzeroExitWithoutConflatingStreams() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'stdout-value'; printf 'stderr-value' >&2; exit 23"],
            workingDirectoryURL: directory
        )

        let result = try await OneShotProcessRunner().run(request)

        #expect(result.exitCode == 23)
        #expect(result.stdoutString == "stdout-value")
        #expect(result.stderrString == "stderr-value")
        #expect(result.executableURL == request.executableURL)
        #expect(result.arguments == request.arguments)
        #expect(result.startedAt <= result.endedAt)
    }

    @Test
    func testDrainsLargeStdoutAndStderrConcurrently() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let script = """
        i=0
        while [ "$i" -lt 6000 ]; do
          printf 'out-%04d-abcdefghijklmnopqrstuvwxyz0123456789\\n' "$i"
          printf 'err-%04d-abcdefghijklmnopqrstuvwxyz0123456789\\n' "$i" >&2
          i=$((i + 1))
        done
        """
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectoryURL: directory,
            timeout: .seconds(10)
        )

        let result = try await OneShotProcessRunner().run(request)

        #expect(result.exitCode == 0)
        #expect(result.stdoutString.hasPrefix("out-0000-"))
        #expect(result.stdoutString.contains("out-5999-"))
        #expect(result.stderrString.hasPrefix("err-0000-"))
        #expect(result.stderrString.contains("err-5999-"))
        #expect(result.stdout.count > 200_000)
        #expect(result.stderr.count > 200_000)
    }

    @Test
    func testWritesStandardInputAndMergesRequestedEnvironment() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let input = Data("synthetic stdin\nsecond line\n".utf8)
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s|' \"$LUMA_TEST_VALUE\"; cat"],
            workingDirectoryURL: directory,
            environment: ["LUMA_TEST_VALUE": "preserved"],
            standardInput: input
        )

        let result = try await OneShotProcessRunner().run(request)

        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "preserved|synthetic stdin\nsecond line\n")
        #expect(result.stderrString == "")
    }

    @Test
    func testRejectsInvalidExecutableAndWorkingDirectoryBeforeLaunch() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let missingExecutable = directory.appending(path: "missing-tool")

        do {
            _ = try await OneShotProcessRunner().run(
                ProcessRequest(
                    executableURL: missingExecutable,
                    arguments: [],
                    workingDirectoryURL: directory
                )
            )
            Issue.record("Expected invalid executable")
        } catch ProcessExecutionError.invalidExecutable(let url) {
            #expect(url == missingExecutable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let missingDirectory = directory.appending(path: "missing-directory", directoryHint: .isDirectory)
        do {
            _ = try await OneShotProcessRunner().run(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    workingDirectoryURL: missingDirectory
                )
            )
            Issue.record("Expected invalid working directory")
        } catch ProcessExecutionError.invalidWorkingDirectory(let url) {
            #expect(url == missingDirectory)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testTimeoutTerminatesChildAndReportsTimeout() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let runner = OneShotProcessRunner(terminationGracePeriod: .milliseconds(50))
        let timeout = Duration.milliseconds(100)
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: directory,
            timeout: timeout
        )

        let started = ContinuousClock.now
        do {
            _ = try await runner.run(request)
            Issue.record("Expected timeout")
        } catch ProcessExecutionError.timedOut(let reported) {
            #expect(reported == timeout)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test
    func testTaskCancellationTerminatesChildAndReportsCancellation() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let runner = OneShotProcessRunner(terminationGracePeriod: .milliseconds(50))
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: directory
        )
        let started = ContinuousClock.now
        let task = Task { try await runner.run(request) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch ProcessExecutionError.cancelled {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test
    func testAlreadyCancelledTaskDoesNotLaunchProcess() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let marker = directory.appending(path: "should-not-exist")
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path],
            workingDirectoryURL: directory
        )
        let task = Task { try await OneShotProcessRunner().run(request) }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected from the preflight cancellation check.
        } catch ProcessExecutionError.cancelled {
            // Also valid if cancellation races with launch.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
