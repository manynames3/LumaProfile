import Foundation
import Testing
@testable import LumaCore

@Suite
struct InteractiveProcessTests {
    @Test
    func knownPromptIsRecognizedAcrossEveryChunkBoundaryExactlyOnce() throws {
        let fixture = try TestSupport.fixture("prompt-known.synthetic")
        let bytes = Data(fixture.utf8)

        for split in 0...bytes.count {
            var machine = ArgyllPromptStateMachine()
            let first = try machine.consume(bytes.prefix(split))
            let second = try machine.consume(bytes.suffix(bytes.count - split))
            let prompts = first + second
            #expect(prompts.count == 1, "split=\(split)")
            #expect(prompts.first?.identifier == .instrumentPlacement, "split=\(split)")
            #expect(
                prompts.first?.message
                    == "Place the i1Display flat against the measurement window with its ambient diffuser swung away, then click Continue."
            )

            let duplicate = try machine.consume(Data(" repeated diagnostic text".utf8))
            #expect(duplicate.isEmpty)
        }
    }

    @Test
    func responseIsAllowedOnlyForPendingKnownPromptAndDocumentedPipeAcknowledgement() throws {
        var machine = ArgyllPromptStateMachine()
        let acknowledgement = ArgyllPromptStateMachine.nonInteractiveAcknowledgement
        #expect(!machine.permits(acknowledgement, for: .instrumentPlacement))
        let prompt = try #require(
            machine.consume(Data("Place the meter on the display test window.".utf8)).first
        )
        #expect(prompt.identifier == .instrumentPlacement)
        #expect(machine.permits(acknowledgement, for: .instrumentPlacement))
        #expect(!machine.permits(Data([0x0A]), for: .instrumentPlacement))
        #expect(!machine.permits(Data([0x20]), for: .instrumentPlacement))
        #expect(!machine.permits(Data("yes\n".utf8), for: .instrumentPlacement))
        #expect(!machine.permits(acknowledgement, for: .calibrationPosition))

        machine.didRespond(to: .instrumentPlacement)
        #expect(!machine.permits(acknowledgement, for: .instrumentPlacement))
    }

    @Test
    func unknownPromptFailsClosedWithoutReturningAnActionIdentifier() throws {
        let fixture = try TestSupport.fixture("prompt-unknown.synthetic")
        var machine = ArgyllPromptStateMachine()
        do {
            _ = try machine.consume(Data(fixture.utf8))
            Issue.record("Expected unknown prompt rejection")
        } catch ArgyllEngineError.unsafePrompt(let excerpt) {
            #expect(excerpt.contains("Choose a number"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!machine.permits(ArgyllPromptStateMachine.nonInteractiveAcknowledgement, for: .takeReading))
    }

    @Test
    func promptFamiliesMapToStableIdentifiers() throws {
        let samples: [(String, ArgyllPromptIdentifier)] = [
            ("Place the sensor on its calibration tile.", .calibrationPosition),
            ("Set the instrument to the measurement position.", .measurementPosition),
            ("Place the meter against the display test window.", .instrumentPlacement),
            (
                "Spot read failed due to the sensor being in the wrong position\n"
                    + "Correct position then hit Esc or Q to give up, any other key to retry:",
                .sensorPositionCorrection
            ),
            ("Hit any key to continue read measurement", .takeReading),
        ]
        for (sample, expected) in samples {
            var machine = ArgyllPromptStateMachine()
            let prompt = try #require(machine.consume(Data(sample.utf8)).first)
            #expect(prompt.identifier == expected)
        }
    }

    @Test
    func pinnedArgyll35SensorPositionRetryIsRecognizedAcrossEveryChunkBoundary() throws {
        let promptText = """
        [SYNTHETIC TEST FIXTURE — NOT HARDWARE OUTPUT]
        Spot read failed due to the sensor being in the wrong position
        (Ambient filter should be removed)
        Correct position then hit Esc or Q to give up, any other key to retry:
        """
        let bytes = Data(promptText.utf8)

        for split in 0...bytes.count {
            var machine = ArgyllPromptStateMachine()
            let first = try machine.consume(bytes.prefix(split))
            let second = try machine.consume(bytes.suffix(bytes.count - split))
            let prompts = first + second
            #expect(prompts.count == 1, "split=\(split)")
            #expect(prompts.first?.identifier == .sensorPositionCorrection, "split=\(split)")
        }
    }

    @Test
    func noisyArgyll35DiagnosticsAreExcludedFromThePlacementPrompt() throws {
        let fixture = try TestSupport.fixture("prompt-noisy-argyll35.synthetic")
        let bytes = Data(fixture.utf8)

        for split in 0...bytes.count {
            var machine = ArgyllPromptStateMachine()
            let prompts = try machine.consume(bytes.prefix(split))
                + machine.consume(bytes.suffix(bytes.count - split))
            let prompt = try #require(prompts.first, "split=\(split)")
            #expect(prompts.count == 1, "split=\(split)")
            #expect(prompt.identifier == .instrumentPlacement, "split=\(split)")
            #expect(
                prompt.message == "Place the i1Display flat against the measurement window with its ambient diffuser swung away, then click Continue.",
                "split=\(split)"
            )
            #expect(!prompt.message.contains("Firmware Date"), "split=\(split)")
            #expect(!prompt.message.contains("Frame buffer depth"), "split=\(split)")
            #expect(!prompt.message.contains("tcgetattr"), "split=\(split)")
        }
    }

    @Test
    func unrecognizedRetryPromptFailsClosed() throws {
        var machine = ArgyllPromptStateMachine()
        do {
            _ = try machine.consume(Data("Unexpected device state. Hit any other key to retry:".utf8))
            Issue.record("Expected unknown retry prompt rejection")
        } catch ArgyllEngineError.unsafePrompt(let excerpt) {
            #expect(excerpt.contains("Unexpected device state"))
        }
    }

    @Test
    func interactiveSessionRejectsPreseededStandardInputBeforeLaunching() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let marker = directory.appending(path: "must-not-launch")
        let session = FoundationInteractiveProcessSession()
        let request = ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path],
            workingDirectoryURL: directory,
            standardInput: Data([0x0A])
        )

        do {
            try await session.start(request)
            Issue.record("Expected pre-seeded interactive input rejection")
        } catch ArgyllEngineError.unsafePrompt(let message) {
            #expect(message.contains("only after"))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func interactiveSessionRejectsPrePromptMismatchedAndArbitraryResponsesThenAcceptsAcknowledgment() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(directory) }
        let session = FoundationInteractiveProcessSession(terminationGracePeriod: .milliseconds(50))

        do {
            try await session.respond(
                toPrompt: ArgyllPromptIdentifier.instrumentPlacement.rawValue,
                with: ArgyllPromptStateMachine.nonInteractiveAcknowledgement
            )
            Issue.record("A response must not be accepted before a matching prompt")
        } catch ArgyllEngineError.unsafePrompt {
            // Expected.
        }

        let events = await session.events
        try await session.start(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'Place the instrument against the display test window, then continue.\\n'; IFS= read -r answer; [ \"$answer\" = ' ' ] || exit 91; printf 'SYNTHETIC-ACK\\n'",
                ],
                workingDirectoryURL: directory
            )
        )

        var iterator = events.makeAsyncIterator()
        var promptID: String?
        while let event = try await iterator.next() {
            if case .prompt(let identifier, _) = event {
                promptID = identifier
                break
            }
        }
        let pendingID = try #require(promptID)
        #expect(pendingID == ArgyllPromptIdentifier.instrumentPlacement.rawValue)

        do {
            try await session.respond(
                toPrompt: ArgyllPromptIdentifier.calibrationPosition.rawValue,
                with: ArgyllPromptStateMachine.nonInteractiveAcknowledgement
            )
            Issue.record("A mismatched prompt identifier must be rejected")
        } catch ArgyllEngineError.unsafePrompt {
            // Expected.
        }
        do {
            try await session.respond(toPrompt: pendingID, with: Data("yes\n".utf8))
            Issue.record("An arbitrary interactive response must be rejected")
        } catch ArgyllEngineError.unsafePrompt {
            // Expected.
        }

        try await session.respond(
            toPrompt: pendingID,
            with: ArgyllPromptStateMachine.nonInteractiveAcknowledgement
        )
        var output = ""
        var exitCode: Int32?
        while let event = try await iterator.next() {
            switch event {
            case .stdout(let data): output += String(decoding: data, as: UTF8.self)
            case .exited(let code): exitCode = code
            default: break
            }
        }
        #expect(output.contains("SYNTHETIC-ACK"))
        #expect(exitCode == 0)
    }
}
