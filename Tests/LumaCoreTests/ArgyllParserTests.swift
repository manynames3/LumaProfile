import Foundation
import Testing
@testable import LumaCore

@Suite
struct ArgyllParserTests {
    @Test
    func versionParserRecognizesSyntheticBannerAndCommonToolVariants() throws {
        let fixture = try TestSupport.fixture("version.synthetic")
        #expect(ArgyllVersionParser.parse(fixture) == ArgyllVersion(major: 3, minor: 5, patch: 0))
        #expect(ArgyllVersionParser.parse("dispcal version 2.3.1") == ArgyllVersion(major: 2, minor: 3, patch: 1))
        #expect(ArgyllVersionParser.parse("colprof 1.9") == ArgyllVersion(major: 1, minor: 9))
        #expect(ArgyllVersionParser.parse("no semantic version here") == nil)
    }

    @Test
    func versionParserRecognizesPinnedArgyll35ToolBanners() {
        let banners = [
            "Measure spot values, Version 3.5.0",
            "Calibrate a Display, Version 3.5.0",
            "Generate Target deviceb test chart color values, Version 3.5.0",
            "Read a Display, Version 3.5.0",
            "Create ICC profile, Version 3.5.0",
            "Check accuracy of ICC profile, Version 3.5.0",
        ]

        for banner in banners {
            #expect(ArgyllVersionParser.parse(banner) == ArgyllVersion(major: 3, minor: 5, patch: 0))
        }
    }

    @Test
    func engineProbeAcceptsPinnedSpotread35Banner() async {
        let directory = URL(fileURLWithPath: "/synthetic/Argyll_V3.5.0/bin", isDirectory: true)
        let installation = ArgyllInstallation(
            directory: directory,
            executables: Dictionary(uniqueKeysWithValues: ArgyllTool.allCases.map {
                ($0, directory.appending(path: $0.rawValue))
            })
        )
        let locator = FixedArgyllInstallationLocator(
            discovery: ArgyllInstallationDiscovery(
                installation: installation,
                candidates: [],
                diagnostic: "Found a coherent synthetic ArgyllCMS tool set."
            )
        )
        let executor = FixedProcessExecutor(
            stderr: "Measure spot values, Version 3.5.0\nAuthor: Graeme W. Gill, licensed under the AGPL Version 3\n"
        )
        let engine = ArgyllCalibrationEngine(locator: locator, processExecutor: executor)

        let probe = await engine.probe()

        #expect(probe.isAvailable)
        #expect(probe.version == "3.5.0")
        #expect(probe.directory == directory)
        #expect(probe.diagnostic.contains("Detected ArgyllCMS 3.5.0."))
    }

    @Test
    func parserCompatibilityRejectsUnknownMajorVersionWithDiagnosticContext() throws {
        let fixture = try TestSupport.fixture("unknown-version.synthetic")
        do {
            _ = try ArgyllConsoleParser.parse(tool: .dispcal, rawOutput: fixture)
            Issue.record("Expected unsupported future major version")
        } catch ArgyllEngineError.unsupportedOutput(let parser, let version, let excerpt) {
            #expect(parser == "dispcal-console-v1")
            #expect(version == ArgyllVersion(major: 9, minor: 0))
            #expect(excerpt.contains("SYNTHETIC TEST FIXTURE"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func instrumentParserFindsSortedUniqueEntriesAndI1D3Capabilities() throws {
        let fixture = try TestSupport.fixture("instrument-list.synthetic")
        let result = try ArgyllInstrumentListParser.parse(fixture)

        #expect(result.detectedVersion == ArgyllVersion(major: 3, minor: 5))
        #expect(result.parserVersion == 1)
        #expect(result.rawOutput == fixture)
        #expect(result.instruments.map(\.id) == ["1", "2"])
        let i1d3 = try #require(result.instruments.first)
        #expect(i1d3.model == "X-Rite i1Display Pro Synthetic")
        #expect(i1d3.serialNumber == "SYN-I1D3-100")
        #expect(i1d3.isI1D3Family)
        #expect(i1d3.capabilities.contains("CCSS"))
        #expect(i1d3.capabilities.contains("CCMX"))
        #expect(result.instruments[1].model == "JETI specbos Synthetic")
        #expect(!result.instruments[1].isI1D3Family)
    }

    @Test
    func instrumentParserRecognizesPinnedArgyll35I1DisplayUSBShape() throws {
        let fixture = try TestSupport.fixture("instrument-list-argyll35-i1display.synthetic")
        let result = try ArgyllInstrumentListParser.parse(fixture)

        #expect(result.detectedVersion == ArgyllVersion(major: 3, minor: 5, patch: 0))
        let supported = result.instruments.filter(\.isI1D3Family)
        #expect(supported.count == 1)
        #expect(supported.first?.id == "1")
        #expect(supported.first?.model == "hid33: (X-Rite i1 DisplayPro, ColorMunki Display)")
    }

    @Test
    func instrumentParserReturnsEmptyForExplicitNoDeviceOutput() throws {
        let fixture = try TestSupport.fixture("instrument-none.synthetic")
        let result = try ArgyllInstrumentListParser.parse(fixture)
        #expect(result.instruments.isEmpty)
        #expect(result.detectedVersion == ArgyllVersion(major: 3, minor: 5))
    }

    @Test
    func instrumentParserFailsClosedForUnknownNonemptyShape() throws {
        let fixture = try TestSupport.fixture("instrument-malformed.synthetic")
        do {
            _ = try ArgyllInstrumentListParser.parse(fixture)
            Issue.record("Expected unsupported instrument enumeration shape")
        } catch ArgyllEngineError.unsupportedOutput(let parser, _, let excerpt) {
            #expect(parser == "instrument-list-v1")
            #expect(excerpt.contains("Peripheral topology token"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func displayParserStopsAtSectionBoundaryAndDoesNotTreatMetersAsDisplays() throws {
        let fixture = try TestSupport.fixture("instrument-list.synthetic")
        let displays = try ArgyllDisplayListParser.parse(fixture)
        #expect(displays.count == 1)
        #expect(displays.first?.index == 1)
        #expect(displays.first?.description == "Synthetic Display at 0, 0, width 3840, height 2160")
    }

    @Test
    func spotreadParserPreservesXYZYxyCCTWarningsAndRawSource() throws {
        let fixture = try TestSupport.fixture("spotread-success.synthetic")
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try ArgyllSpotMeasurementParser.parse(fixture, capturedAt: capturedAt)
        let measurement = result.measurement

        #expect(result.detectedVersion == ArgyllVersion(major: 3, minor: 5))
        #expect(result.parserVersion == 1)
        #expect(measurement.xyz == XYZColor(x: 19.01, y: 20, z: 21.78))
        #expect(measurement.chromaticity == Chromaticity(x: 0.3127, y: 0.329))
        #expect(measurement.luminanceCDM2 == 20)
        #expect(measurement.correlatedColorTemperature == 6_504)
        #expect(measurement.capturedAt == capturedAt)
        #expect(measurement.warnings == ["Warning: synthetic low light advisory retained for testing."])
        #expect(measurement.rawSource == fixture)
        #expect(measurement.rgbBalance?.count == 3)
    }

    @Test
    func spotreadParserReconstructsXYZFromYxyOnly() throws {
        let fixture = try TestSupport.fixture("spotread-yxy-only.synthetic")
        let measurement = try ArgyllSpotMeasurementParser.parse(fixture).measurement

        #expect(measurement.chromaticity == Chromaticity(x: 0.3127, y: 0.329))
        #expect(measurement.luminanceCDM2 == 120.25)
        #expect(abs(measurement.xyz.x - (0.3127 * 120.25 / 0.329)) < 1e-10)
        #expect(abs(measurement.xyz.z - ((1 - 0.3127 - 0.329) * 120.25 / 0.329)) < 1e-10)
        #expect(measurement.correlatedColorTemperature == 6_498)
    }

    @Test
    func spotreadParserRejectsTruncatedAndMalformedMeasurements() throws {
        for name in ["spotread-truncated.synthetic", "spotread-malformed.synthetic"] {
            let fixture = try TestSupport.fixture(name)
            do {
                _ = try ArgyllSpotMeasurementParser.parse(fixture)
                Issue.record("Expected unsupported spotread output for \(name)")
            } catch ArgyllEngineError.unsupportedOutput(let parser, _, let excerpt) {
                #expect(parser == "spot-measurement-v1")
                #expect(excerpt.contains("SYNTHETIC TEST FIXTURE"))
            } catch {
                Issue.record("Unexpected error for \(name): \(error)")
            }
        }
    }

    @Test
    func dispcalParserExtractsPatchAndPercentageProgressWarningAndCompletion() throws {
        let fixture = try TestSupport.fixture("dispcal-console.synthetic")
        let result = try ArgyllConsoleParser.parse(tool: .dispcal, rawOutput: fixture)
        expectProgress(result.progress, equals: [(1, 12), (50, 100), (12, 12)])
        #expect(result.warnings == ["Warning: synthetic brightness is outside the target tolerance."])
        #expect(result.messages == ["Calibration complete; synthetic display.cal created."])
        #expect(result.rawOutput == fixture)
    }

    @Test
    func dispreadParserExtractsReadingPatchAndCompletionProgress() throws {
        let fixture = try TestSupport.fixture("dispread-console.synthetic")
        let result = try ArgyllConsoleParser.parse(tool: .dispread, rawOutput: fixture)
        expectProgress(result.progress, equals: [(1, 96), (48, 96), (100, 100)])
        #expect(result.messages.count == 2)
        #expect(result.messages.last?.contains("characterization finished") == true)
    }

    @Test
    func colprofParserExtractsPercentagesAndProfileCreationMessage() throws {
        let fixture = try TestSupport.fixture("colprof-console.synthetic")
        let result = try ArgyllConsoleParser.parse(tool: .colprof, rawOutput: fixture)
        expectProgress(result.progress, equals: [(10, 100), (65, 100), (100, 100)])
        #expect(result.messages == ["100% profile created: Synthetic Display.icc"])
    }

    @Test
    func dispwinParserRetainsProfileAssociationCompletion() throws {
        let fixture = try TestSupport.fixture("dispwin-console.synthetic")
        let result = try ArgyllConsoleParser.parse(tool: .dispwin, rawOutput: fixture)
        #expect(result.progress.isEmpty)
        #expect(result.messages == ["Display profile update complete."])
    }

    @Test
    func profcheckParserExtractsSampleProgressAndCaution() throws {
        let fixture = try TestSupport.fixture("profcheck-console.synthetic")
        let result = try ArgyllConsoleParser.parse(tool: .profcheck, rawOutput: fixture)
        expectProgress(result.progress, equals: [(1, 24), (24, 24)])
        #expect(result.warnings == ["Caution: synthetic maximum error exceeds the fixture threshold."])
        #expect(result.messages == ["Profile check complete."])
    }

    @Test
    func consoleParserDoesNotInventProgressFromTruncatedLine() throws {
        let fixture = try TestSupport.fixture("console-truncated.synthetic")
        let result = try ArgyllConsoleParser.parse(tool: .dispread, rawOutput: fixture)
        #expect(result.progress.isEmpty)
        #expect(result.messages.isEmpty)
        #expect(result.rawOutput == fixture)
    }

    @Test
    func streamingConsoleParserHandlesEveryByteBoundaryWithoutDuplicates() {
        let transcript = Data(
            "dispread version 3.5.0\rReading 1 of 3\r\nFirmware café diagnostic\nPatch 2/3\n100% complete"
                .utf8
        )
        let expected: [ArgyllConsoleStreamEvent] = [
            .technical("dispread version 3.5.0"),
            .progress(completed: 1, total: 3),
            .technical("Firmware café diagnostic"),
            .progress(completed: 2, total: 3),
            .progress(completed: 100, total: 100),
            .message("100% complete"),
        ]

        for split in 0...transcript.count {
            var parser = ArgyllConsoleStreamParser()
            var events = parser.consume(transcript.prefix(split))
            events += parser.consume(transcript.suffix(transcript.count - split))
            events += parser.finish()
            events += parser.finish()
            #expect(events == expected, "split=\(split)")
        }

        var bytewiseParser = ArgyllConsoleStreamParser()
        var bytewiseEvents: [ArgyllConsoleStreamEvent] = []
        for byte in transcript {
            bytewiseEvents += bytewiseParser.consume(Data([byte]))
        }
        bytewiseEvents += bytewiseParser.finish()
        #expect(bytewiseEvents == expected)
    }

    @Test
    func streamingConsoleParserWaitsForACompleteLineAndFlushesTailOnce() {
        var parser = ArgyllConsoleStreamParser()
        #expect(parser.consume(Data("Patch 7 of ".utf8)).isEmpty)
        #expect(parser.consume(Data("12".utf8)).isEmpty)
        #expect(parser.finish() == [.progress(completed: 7, total: 12)])
        #expect(parser.finish().isEmpty)
        #expect(parser.consume(Data("Patch 8 of 12\n".utf8)).isEmpty)
    }

    private func expectProgress(
        _ actual: [(completed: Int, total: Int?)],
        equals expected: [(Int, Int?)]
    ) {
        #expect(actual.count == expected.count)
        for (actualValue, expectedValue) in zip(actual, expected) {
            #expect(actualValue.completed == expectedValue.0)
            #expect(actualValue.total == expectedValue.1)
        }
    }
}

private struct FixedArgyllInstallationLocator: ArgyllInstallationLocating {
    let discovery: ArgyllInstallationDiscovery

    func locate() -> ArgyllInstallationDiscovery { discovery }
}

private struct FixedProcessExecutor: ProcessExecuting {
    let stderr: String

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        ProcessResult(
            executableURL: request.executableURL,
            arguments: request.arguments,
            startedAt: .distantPast,
            endedAt: .distantPast,
            exitCode: 1,
            stdout: Data(),
            stderr: Data(stderr.utf8)
        )
    }
}
